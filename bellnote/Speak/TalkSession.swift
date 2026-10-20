import AVFoundation
import Foundation
import Observation
import OSLog
import SwiftData

enum TalkPhase: Equatable {
    case idle
    case listening
    case thinking
    case speaking
    case needsMicrophone
    case needsModel
    case needsVoice
    case failed(String)
}

struct TalkTurn: Identifiable, Equatable {
    enum Role: Equatable {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    let text: String

    init(role: Role, text: String) {
        self.id = UUID()
        self.role = role
        self.text = text
    }
}

/// Session-only voice assistant for the Test tab: listen → full-app retrieve → answer → Supertonic speak.
/// History lives in memory and clears when the process dies.
@MainActor
@Observable
final class TalkSession {
    private static let log = Logger(subsystem: "app.bellnote", category: "talk")
    private static let historyLimit = 8

    private(set) var phase: TalkPhase = .idle
    private(set) var turns: [TalkTurn] = []
    private(set) var partialTranscript = ""
    private(set) var statusLine = ""

    private let listen = TalkListenEngine()
    private let reader = SpeechReader()
    private var loopTask: Task<Void, Never>?
    private var warmTask: Task<Void, Never>?
    private var running = false
    private var terms: [Term] = []
    private var locale = Locale.current
    private weak var session: AppSession?
    /// Rebuilt when Talk opens or the term list changes — not on every question.
    private var cachedNotes: [StudyBlock] = []
    private var cachedCatalog: [WindowTag] = []

    init() {
        reader.ownsAudioSession = true
    }

    func start(terms: [Term], session: AppSession) {
        self.terms = terms
        self.session = session
        // App UI locale is bare "tr"/"en"; Speech AssetInventory needs a regional tag like tr_TR.
        let speechLanguage = AppLanguage(rawValue: session.languageCode) ?? .english
        self.locale = Locale(identifier: speechLanguage.speechLocaleIdentifier)
        refreshCache()
        guard !running else {
            Self.log.info("Talk start ignored alreadyRunning phase=\(String(describing: self.phase), privacy: .public)")
            return
        }
        running = true
        reader.ownsAudioSession = false
        Self.log.info(
            "Talk start terms=\(terms.count) locale=\(self.locale.identifier, privacy: .public) notes=\(self.cachedNotes.count) catalog=\(self.cachedCatalog.count)"
        )
        Task { await LocalModelRuntime.shared.setHoldResident(true) }
        warmTask?.cancel()
        warmTask = Task {
            let warmStarted = Date()
            // Load text + voice while the first listen starts, so the first answer is not cold.
            async let model: Void = LocalModelRuntime.shared.warmTextModel()
            async let voice: Void = SupertonicSpeech.warm()
            _ = await (model, voice)
            Self.log.info("Talk warm done ms=\(Int(Date().timeIntervalSince(warmStarted) * 1000))")
        }
        loopTask?.cancel()
        loopTask = Task { await runLoop() }
    }

    func stop() {
        Self.log.info("Talk stop phase=\(String(describing: self.phase), privacy: .public) turns=\(self.turns.count)")
        running = false
        loopTask?.cancel()
        loopTask = nil
        warmTask?.cancel()
        warmTask = nil
        listen.disarmBargeIn()
        listen.stopListening(cancelTurn: true)
        reader.stop(force: true)
        reader.ownsAudioSession = true
        Task { await LocalModelRuntime.shared.setHoldResident(false) }
        partialTranscript = ""
        if phase == .listening || phase == .thinking || phase == .speaking {
            phase = .idle
        }
        statusLine = ""
    }

    private func refreshCache() {
        guard let session else {
            cachedNotes = TalkContext.noteBlocks(from: terms)
            cachedCatalog = []
            return
        }
        cachedNotes = TalkContext.noteBlocks(from: terms)
        cachedCatalog = TalkContext.catalogTags(terms: terms, session: session)
        Self.log.info("Talk cache notes=\(self.cachedNotes.count) catalog=\(self.cachedCatalog.count)")
    }

    private func runLoop() async {
        let permitted = await AVAudioApplication.requestRecordPermission()
        guard permitted else {
            Self.log.error("Talk mic permission denied")
            phase = .needsMicrophone
            statusLine = String(localized: "The microphone is off for Bellnote.")
            running = false
            return
        }
        let hasModel = await LocalModelRuntime.shared.hasTextModel()
        guard hasModel else {
            Self.log.error("Talk no text model installed")
            phase = .needsModel
            statusLine = String(localized: "A model is not available.")
            running = false
            return
        }
        guard SupertonicSpeech.isInstalled else {
            Self.log.error("Talk Supertonic missing")
            phase = .needsVoice
            statusLine = String(localized: "Download Supertonic in Settings to talk.")
            running = false
            return
        }

        Self.log.info("Talk loop ready")
        while running, !Task.isCancelled {
            do {
                phase = .listening
                statusLine = String(localized: "Listening…")
                partialTranscript = ""
                Self.log.info("Talk phase=listening")
                let listenStarted = Date()
                let question: String
                do {
                    async let turn = listen.listenTurn(locale: locale)
                    let poll = Task { @MainActor in
                        while !Task.isCancelled {
                            self.partialTranscript = self.listen.partialText
                            try? await Task.sleep(for: .milliseconds(120))
                        }
                    }
                    defer { poll.cancel() }
                    question = try await turn
                }
                partialTranscript = question
                Self.log.info(
                    "Talk heard ms=\(Int(Date().timeIntervalSince(listenStarted) * 1000)) characters=\(question.count) text=\(question, privacy: .public)"
                )
                guard running, !Task.isCancelled else { break }
                guard question.split(whereSeparator: \.isWhitespace).count >= 1 else {
                    Self.log.info("Talk empty turn skipped")
                    continue
                }

                var activeQuestion = question
                thinkLoop: while running, !Task.isCancelled {
                    if turns.last?.role == .user {
                        turns[turns.count - 1] = TalkTurn(role: .user, text: activeQuestion)
                    } else {
                        turns.append(TalkTurn(role: .user, text: activeQuestion))
                    }
                    trimHistory()
                    phase = .thinking
                    statusLine = String(localized: "Thinking…")
                    partialTranscript = ""
                    Self.log.info("Talk phase=thinking question=\(activeQuestion, privacy: .public)")
                    let thinkStarted = Date()

                    switch await thinkWhileListening(question: activeQuestion) {
                    case .answered(let reply):
                        Self.log.info(
                            "Talk answered ms=\(Int(Date().timeIntervalSince(thinkStarted) * 1000)) characters=\(reply.count) text=\(reply, privacy: .public)"
                        )
                        guard running, !Task.isCancelled else { break thinkLoop }
                        turns.append(TalkTurn(role: .assistant, text: reply))
                        trimHistory()

                        phase = .speaking
                        statusLine = String(localized: "Speaking…")
                        Self.log.info("Talk phase=speaking")
                        let speakStarted = Date()
                        switch await speak(reply) {
                        case .finished:
                            Self.log.info("Talk spoke ms=\(Int(Date().timeIntervalSince(speakStarted) * 1000))")
                            break thinkLoop
                        case .bargedIn(let next):
                            Self.log.info(
                                "Talk speak barged ms=\(Int(Date().timeIntervalSince(speakStarted) * 1000)) next=\(next, privacy: .public)"
                            )
                            guard next.split(whereSeparator: \.isWhitespace).count >= 1 else {
                                break thinkLoop
                            }
                            activeQuestion = next
                            continue thinkLoop
                        }

                    case .interrupted(let next):
                        Self.log.info(
                            "Talk think interrupted ms=\(Int(Date().timeIntervalSince(thinkStarted) * 1000)) next=\(next, privacy: .public)"
                        )
                        guard next.split(whereSeparator: \.isWhitespace).count >= 1 else {
                            continue thinkLoop
                        }
                        activeQuestion = next
                        continue thinkLoop
                    }
                }
            } catch is CancellationError {
                Self.log.info("Talk loop cancelled")
                break
            } catch TalkListenError.speechUnsupported {
                Self.log.error("Talk speech locale unsupported")
                phase = .failed("speechUnsupported")
                statusLine = String(localized: "Speech is not available for this language.")
                running = false
                break
            } catch {
                Self.log.error("Talk loop failed \(error.localizedDescription, privacy: .public)")
                phase = .failed(error.localizedDescription)
                statusLine = String(localized: "Something went wrong. Try again.")
                try? await Task.sleep(for: .seconds(1.5))
                if running { continue } else { break }
            }
        }
        if running == false, phase != .needsMicrophone, phase != .needsModel, phase != .needsVoice {
            phase = .idle
        }
        Self.log.info("Talk loop ended phase=\(String(describing: self.phase), privacy: .public)")
    }

    private enum ThinkRace {
        case answered(String)
        case interrupted(String)
    }

    /// Model runs while the mic stays open. A new spoken turn cancels that answer.
    private func thinkWhileListening(question: String) async -> ThinkRace {
        // Hop via named MainActor methods — `addTask { @MainActor in }` trips the region checker.
        await withTaskGroup(of: ThinkRace?.self) { group in
            group.addTask {
                await self.thinkAnswerBranch(question: question)
            }
            group.addTask {
                await self.thinkListenBranch()
            }

            var outcome: ThinkRace?
            for await value in group {
                guard let value else { continue }
                outcome = value
                group.cancelAll()
                break
            }
            self.finishThinkRace()
            return outcome ?? .answered(String(localized: "Something went wrong. Try again."))
        }
    }

    private func thinkAnswerBranch(question: String) async -> ThinkRace? {
        let reply = await answer(question: question)
        guard !Task.isCancelled, !reply.isEmpty else { return nil }
        return .answered(reply)
    }

    private func thinkListenBranch() async -> ThinkRace? {
        // Skip the tail of the question that just ended.
        try? await Task.sleep(for: .milliseconds(450))
        guard !Task.isCancelled else { return nil }
        do {
            let poll = Task {
                await self.pollThinkPartial()
            }
            defer { poll.cancel() }
            let next = try await listen.listenTurn(locale: locale)
            guard !Task.isCancelled else { return nil }
            return .interrupted(next)
        } catch is CancellationError {
            return nil
        } catch {
            Self.log.error("Talk think-listen failed \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func pollThinkPartial() async {
        while !Task.isCancelled {
            let partial = listen.partialText
            if !partial.isEmpty {
                partialTranscript = partial
                if phase == .thinking {
                    statusLine = String(localized: "Listening…")
                }
            }
            try? await Task.sleep(for: .milliseconds(120))
        }
    }

    private func finishThinkRace() {
        listen.stopListening(cancelTurn: true)
    }

    private func answer(question: String) async -> String {
        let answerStarted = Date()
        if Task.isCancelled { return "" }
        if isGreeting(question) {
            Self.log.info("Talk greeting short-circuit text=\(question, privacy: .public)")
            return String(localized: "Hi. Ask about your lectures or what's stored in the app.")
        }
        if isClockQuestion(question) {
            var style = Date.FormatStyle(date: .complete, time: .shortened).locale(locale)
            style.timeZone = TimeZone.autoupdatingCurrent
            let stamp = Date.now.formatted(style)
            Self.log.info("Talk clock short-circuit local=\(stamp, privacy: .public)")
            return stamp
        }
        if cachedNotes.isEmpty && cachedCatalog.isEmpty {
            refreshCache()
        }
        // Fewer blocks + lower token cap = faster on-device replies for live talk.
        let retrieveStarted = Date()
        let pick = StudySelection.relevant(
            cachedNotes,
            to: question,
            locale: locale,
            budget: 5_000,
            topCount: 5
        )
        let retrieveMs = Int(Date().timeIntervalSince(retrieveStarted) * 1000)
        let poolCharacters = cachedNotes.reduce(0) { $0 + $1.text.count }
        let catalogCharacters = cachedCatalog.reduce(0) { $0 + $1.text.count }
        let pickedCharacters = pick.blocks.reduce(0) { $0 + $1.text.count }
        Self.log.info(
            "Talk retrieve ms=\(retrieveMs) poolNotes=\(self.cachedNotes.count) poolCharacters=\(poolCharacters) catalogLines=\(self.cachedCatalog.count) catalogCharacters=\(catalogCharacters) picked=\(pick.blocks.count) pickedCharacters=\(pickedCharacters) question=\(question, privacy: .public)"
        )
        if let source = pick.source {
            Self.log.info(
                "Talk source second=\(source.second) kind=\(source.kind.rawValue, privacy: .public) characters=\(source.text.count) head=\(String(source.text.prefix(120)), privacy: .public)"
            )
        } else {
            Self.log.info("Talk source none")
        }
        for (index, block) in pick.blocks.enumerated() {
            Self.log.info(
                "Talk picked[\(index)] second=\(block.second) kind=\(block.kind.rawValue, privacy: .public) characters=\(block.text.count) head=\(String(block.text.prefix(100)), privacy: .public)"
            )
        }

        var tags = cachedCatalog
        tags.append(
            contentsOf: pick.blocks.map {
                WindowTag(
                    language: locale.identifier,
                    speakerRole: "narrator",
                    kind: $0.kind.rawValue,
                    topics: $0.topics,
                    text: $0.text,
                    importanceCue: $0.importance,
                    missing: $0.missing
                )
            }
        )
        guard !tags.isEmpty else {
            Self.log.info("Talk answer empty tags ms=\(Int(Date().timeIntervalSince(answerStarted) * 1000))")
            return String(localized: "The lectures do not contain that.")
        }

        // The current user question is already appended; prior turns only go into history.
        let history = turns.dropLast().suffix(Self.historyLimit).map { turn in
            (
                role: turn.role == .user ? "user" : "assistant",
                text: turn.text
            )
        }
        Self.log.info("Talk history turns=\(history.count) (prior only; current question separate)")
        for (index, turn) in history.enumerated() {
            Self.log.info(
                "Talk history[\(index)] role=\(turn.role, privacy: .public) characters=\(turn.text.count) text=\(turn.text, privacy: .public)"
            )
        }

        let promptCharacters = tags.reduce(0) { $0 + $1.text.count }
            + history.reduce(0) { $0 + $1.text.count }
            + question.count
        Self.log.info(
            "Talk model prompt tags=\(tags.count) promptCharacters≈\(promptCharacters) maxTokens=72 temperature=0"
        )
        do {
            let modelStarted = Date()
            let reply = try await LocalModelRuntime.shared.answer(
                question: question,
                tags: tags,
                history: history,
                maximumResponseTokens: 72,
                temperature: 0
            )
            let modelMs = Int(Date().timeIntervalSince(modelStarted) * 1000)
            let totalMs = Int(Date().timeIntervalSince(answerStarted) * 1000)
            let missing = reply.contains("NOT_IN_NOTES") || reply.isEmpty
            Self.log.info(
                "Talk answer done modelMs=\(modelMs) totalMs=\(totalMs) retrieveMs=\(retrieveMs) notInNotes=\(missing) characters=\(reply.count) text=\(reply, privacy: .public)"
            )
            return missing ? String(localized: "The lectures do not contain that.") : reply
        } catch is CancellationError {
            Self.log.info("Talk answer cancelled ms=\(Int(Date().timeIntervalSince(answerStarted) * 1000))")
            return ""
        } catch {
            Self.log.error(
                "Talk answer failed ms=\(Int(Date().timeIntervalSince(answerStarted) * 1000)) \(error.localizedDescription, privacy: .public)"
            )
            return String(localized: "A model is not available.")
        }
    }

    private enum SpeakOutcome {
        case finished
        case bargedIn(String)
    }

    /// Speaks the reply. If the student talks over it, stops TTS and listens for a new turn.
    private func speak(_ text: String) async -> SpeakOutcome {
        listen.disarmBargeIn()
        listen.stopListening(cancelTurn: false)
        let bargeFlag = BargeFlag()

        // Start TTS first. The barge mic must attach *after* the playback engine is running —
        // otherwise the second AVAudioEngine steals the session and the mic tap dies.
        Self.log.info("Talk speak begin characters=\(text.count)")
        reader.playbackGain = 0.48
        reader.readSupertonicOnly(text, locale: locale)

        var bargeStarted = false
        while !Task.isCancelled, reader.isSpeaking {
            if !bargeStarted, reader.isAudioPlaying {
                bargeStarted = true
                do {
                    try await listen.startBargeMonitor(locale: locale)
                    listen.armBargeIn(after: .milliseconds(280)) { [weak self] in
                        guard let self else { return }
                        bargeFlag.value = true
                        Self.log.info("Talk barge-in stop speech → listen")
                        self.reader.stop(force: true)
                    }
                } catch {
                    Self.log.error("Talk barge monitor failed \(error.localizedDescription, privacy: .public)")
                }
            }
            try? await Task.sleep(for: .milliseconds(80))
        }
        reader.playbackGain = 1
        listen.disarmBargeIn()
        listen.stopListening(cancelTurn: false)
        let wasBarged = bargeFlag.value
        Self.log.info("Talk speak end barged=\(wasBarged)")

        guard wasBarged, running, !Task.isCancelled else {
            return .finished
        }

        phase = .listening
        statusLine = String(localized: "Listening…")
        partialTranscript = ""
        // Let speaker audio settle so the barge mic does not echo the last syllables.
        try? await Task.sleep(for: .milliseconds(250))
        guard running, !Task.isCancelled else { return .finished }

        do {
            let poll = Task { @MainActor in
                while !Task.isCancelled {
                    self.partialTranscript = self.listen.partialText
                    try? await Task.sleep(for: .milliseconds(120))
                }
            }
            defer { poll.cancel() }
            let next = try await listen.listenTurn(locale: locale)
            return .bargedIn(next)
        } catch is CancellationError {
            return .finished
        } catch {
            Self.log.error("Talk barge listen failed \(error.localizedDescription, privacy: .public)")
            return .finished
        }
    }

    private func trimHistory() {
        if turns.count > Self.historyLimit * 2 {
            turns = Array(turns.suffix(Self.historyLimit * 2))
        }
    }

    /// Shared flag so the barge-in handler can mark interruption reliably.
    private final class BargeFlag: @unchecked Sendable {
        var value = false
    }

    /// “What time is it” — answer from the device clock, not the model.
    private func isClockQuestion(_ text: String) -> Bool {
        let folded = Self.asciiFold(text)
        if folded.contains("what time") || folded.contains("whats the time") || folded.contains("what's the time") {
            return true
        }
        if folded.contains("saat kac") || folded.contains("saat ne") || folded.contains("saat nedir") {
            return true
        }
        let tokens = folded
            .split { !$0.isLetter }
            .map(String.init)
            .filter { !$0.isEmpty }
        guard tokens.count <= 6 else { return false }
        let hasSaat = tokens.contains("saat") || tokens.contains("time") || tokens.contains("clock")
        let hasAsk = tokens.contains(where: {
            ["kac", "ne", "nedir", "simdi", "what", "whats", "now", "su"].contains($0)
        })
        return hasSaat && hasAsk
    }

    /// Pure hello / how-are-you — no lecture fact to invent, so skip the model.
    private func isGreeting(_ text: String) -> Bool {
        let tokens = Self.asciiFold(text)
            .split { !$0.isLetter }
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty, tokens.count <= 8 else { return false }
        let greet: Set<String> = [
            "selam", "merhaba", "hey", "hi", "hello", "slm", "naber",
            "nasilsin", "nasilsiniz", "nasil", "gidiyor", "gunaydin", "iyi",
            "aksamlar", "geceler", "haber", "ne", "var", "misin", "misiniz",
        ]
        // Require at least one clear greeting word; the rest must stay in the hello set.
        let hasHello = tokens.contains(where: {
            ["selam", "merhaba", "hey", "hi", "hello", "slm", "naber", "gunaydin"].contains($0)
                || $0.hasPrefix("nasil")
        })
        guard hasHello else { return false }
        return tokens.allSatisfy { greet.contains($0) }
    }

    /// Turkish ı/ş/ğ… do not fold via diacriticInsensitive — map to ASCII for matching.
    private static func asciiFold(_ text: String) -> String {
        let map: [Character: Character] = [
            "ı": "i", "İ": "i", "I": "i",
            "ş": "s", "Ş": "s",
            "ğ": "g", "Ğ": "g",
            "ü": "u", "Ü": "u",
            "ö": "o", "Ö": "o",
            "ç": "c", "Ç": "c",
        ]
        return String(text.lowercased().map { map[$0] ?? $0 })
    }
}
