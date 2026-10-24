import AVFoundation
import Foundation
import Observation
import OSLog
import SwiftData

enum TalkPhase: Equatable {
    case idle
    case preparing
    case listening
    case thinking
    case speaking
    case needsMicrophone
    case needsModel
    case needsVoice
    case failed(String)
}

/// One tappable Source row under a Talk reply.
/// Note → Raw minute. Timetable slot → that weekday. Assignment → that task’s week.
/// Exam → the week of its date. Inventory → that row.
struct TalkSourceItem: Identifiable, Equatable, Hashable {
    enum Target: Equatable, Hashable {
        case note(blockID: UUID, second: Int)
        case timetable(termID: PersistentIdentifier, weekday: Int, startMinutes: Int)
        case assignment(courseID: PersistentIdentifier, assignmentID: PersistentIdentifier, weekStart: Date)
        case exam(courseID: PersistentIdentifier, weekStart: Date?)
        case inventory(courseID: PersistentIdentifier, itemID: PersistentIdentifier)
        /// A recording that is not ready. Opens that lecture, not a Raw minute.
        case recording(lectureID: PersistentIdentifier)
        /// The lecturer stored on the course. Opens that course’s lecturer sheet.
        case lecturer(courseID: PersistentIdentifier)
    }

    let id: UUID
    let title: String
    let target: Target

    init(title: String, target: Target) {
        self.id = UUID()
        self.title = title
        self.target = target
    }
}

struct TalkTurn: Identifiable, Equatable {
    enum Role: Equatable {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    let text: String
    /// Note or timetable sources for the Source control. Empty for greetings, clock, or missing notes.
    let sources: [TalkSourceItem]

    init(role: Role, text: String, sources: [TalkSourceItem] = []) {
        self.id = UUID()
        self.role = role
        self.text = text
        self.sources = sources
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
    private var speakCancel = SupertonicCancel()
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
        // Same idea as processing: keep the screen awake so Talk is not cut by auto-lock.
        ScreenIdleGate.setTalkActive(true)
        Self.log.info(
            "Talk start terms=\(terms.count) locale=\(self.locale.identifier, privacy: .public) notes=\(self.cachedNotes.count) catalog=\(self.cachedCatalog.count)"
        )
        Task { await LocalModelRuntime.shared.setHoldResident(true) }
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
        speakCancel.stopped = true
        listen.disarmBargeIn()
        listen.stopPlayback()
        listen.stopListening(cancelTurn: true)
        reader.stop(force: true)
        reader.ownsAudioSession = true
        ScreenIdleGate.setTalkActive(false)
        Task { await LocalModelRuntime.shared.setHoldResident(false) }
        partialTranscript = ""
        if phase == .preparing || phase == .listening || phase == .thinking || phase == .speaking {
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

        // Cold start: show preparing until weights (+ voice) are ready. Skip when already hot.
        let alreadyReady = await LocalModelRuntime.shared.isComposeModelReady()
        if !alreadyReady {
            phase = .preparing
            statusLine = String(localized: "Preparing…")
            Self.log.info("Talk phase=preparing")
            let warmStarted = Date()
            do {
                async let voice: Void = SupertonicSpeech.warm()
                try await LocalModelRuntime.shared.warmTextModel()
                await voice
                Self.log.info("Talk warm done ms=\(Int(Date().timeIntervalSince(warmStarted) * 1000))")
            } catch is CancellationError {
                Self.log.info("Talk warm cancelled")
                return
            } catch {
                Self.log.error("Talk warm failed \(error.localizedDescription, privacy: .public)")
                phase = .needsModel
                statusLine = String(localized: "A model is not available.")
                running = false
                return
            }
            guard running, !Task.isCancelled else { return }
        } else {
            Self.log.info("Talk warm skipped model already ready")
            warmTask?.cancel()
            warmTask = Task { await SupertonicSpeech.warm() }
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
                            "Talk answered ms=\(Int(Date().timeIntervalSince(thinkStarted) * 1000)) characters=\(reply.text.count) sources=\(reply.sources.count) text=\(reply.text, privacy: .public)"
                        )
                        guard running, !Task.isCancelled else { break thinkLoop }
                        turns.append(
                            TalkTurn(role: .assistant, text: reply.text, sources: reply.sources)
                        )
                        trimHistory()

                        phase = .speaking
                        statusLine = String(localized: "Speaking…")
                        Self.log.info("Talk phase=speaking")
                        let speakStarted = Date()
                        switch await speak(reply.text) {
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

    private struct TalkReply: Equatable {
        var text: String
        var sources: [TalkSourceItem] = []
    }

    private enum ThinkRace {
        case answered(TalkReply)
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
            return outcome
                ?? .answered(TalkReply(text: String(localized: "Something went wrong. Try again.")))
        }
    }

    private func thinkAnswerBranch(question: String) async -> ThinkRace? {
        let reply = await answer(question: question)
        guard !Task.isCancelled, !reply.text.isEmpty else { return nil }
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
            // Keep status on Thinking… — phase stays thinking until the race ends.
            // Partial still fills the You card so barge-in speech is visible.
            if !partial.isEmpty {
                partialTranscript = partial
            }
            try? await Task.sleep(for: .milliseconds(120))
        }
    }

    private func finishThinkRace() {
        listen.stopListening(cancelTurn: true)
    }

    private func answer(question: String) async -> TalkReply {
        let answerStarted = Date()
        if Task.isCancelled { return TalkReply(text: "") }
        if let blocked = unethicalReply(for: question) {
            return blocked
        }
        if let social = socialReply(for: question) {
            return social
        }
        if isClockQuestion(question) {
            var style = Date.FormatStyle(date: .complete, time: .shortened).locale(locale)
            style.timeZone = TimeZone.autoupdatingCurrent
            let stamp = Date.now.formatted(style)
            Self.log.info("Talk clock short-circuit local=\(stamp, privacy: .public)")
            return TalkReply(text: stamp)
        }
        if let timetable = timetableReply(for: question) {
            Self.log.info("Talk timetable short-circuit text=\(timetable.text, privacy: .public)")
            return timetable
        }
        if let recordings = unprocessedRecordingReply(for: question) {
            Self.log.info("Talk recording short-circuit text=\(recordings.text, privacy: .public)")
            return recordings
        }
        if let lecturer = lecturerReply(for: question) {
            Self.log.info("Talk lecturer short-circuit text=\(lecturer.text, privacy: .public)")
            return lecturer
        }
        if let speaker = speakerReply(for: question) {
            Self.log.info("Talk speaker short-circuit text=\(speaker.text, privacy: .public)")
            return speaker
        }
        if let covered = coveredThenReply(for: question) {
            Self.log.info("Talk covered short-circuit text=\(covered.text, privacy: .public)")
            return covered
        }
        if cachedNotes.isEmpty && cachedCatalog.isEmpty {
            refreshCache()
        }
        // Fewer blocks + lower token cap = faster on-device replies for live talk.
        // A filler-only turn (“evet”) has no topic. BM25 would open whichever note says that word.
        let retrieveStarted = Date()
        let topicKeys = Self.contentTokens(for: question)
        let catalogAsk =
            isScheduleQuestion(question) || isAssignmentCatalogQuestion(question)
            || isExamCatalogQuestion(question) || isInventoryCatalogQuestion(question)
        let pick: StudySelection.Pick
        if catalogAsk || topicKeys.isEmpty {
            pick = StudySelection.Pick(blocks: [], source: nil)
            Self.log.info(
                "Talk retrieve skipped \(catalogAsk ? "catalogue" : "filler-only", privacy: .public) question=\(question, privacy: .public)"
            )
        } else {
            pick = StudySelection.relevant(
                cachedNotes,
                to: question,
                locale: locale,
                budget: 5_000,
                topCount: 5
            )
        }
        let retrieveMs = Int(Date().timeIntervalSince(retrieveStarted) * 1000)
        let poolCharacters = cachedNotes.reduce(0) { $0 + $1.text.count }
        let catalogCharacters = cachedCatalog.reduce(0) { $0 + $1.text.count }
        let pickedCharacters = pick.blocks.reduce(0) { $0 + $1.text.count }
        Self.log.info(
            "Talk retrieve ms=\(retrieveMs) poolNotes=\(self.cachedNotes.count) poolCharacters=\(poolCharacters) catalogLines=\(self.cachedCatalog.count) catalogCharacters=\(catalogCharacters) picked=\(pick.blocks.count) pickedCharacters=\(pickedCharacters) question=\(question, privacy: .public)"
        )
        // Aptal, manyak, slang, or any other words that are not in a note. No word list, no model, no Source.
        if !catalogAsk, !topicKeys.isEmpty,
           pick.blocks.allSatisfy({ Self.topicScore(of: $0, keys: topicKeys) == 0 }) {
            Self.log.info("Talk answer skipped no topic hit question=\(question, privacy: .public)")
            return TalkReply(text: String(localized: "The lectures do not contain that."))
        }
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
            return TalkReply(text: String(localized: "The lectures do not contain that."))
        }

        // Earlier turns were making the model repeat the last course or the last canned sentence.
        // The current question and the catalogue are the whole prompt.
        let history: [(role: String, text: String)] = []
        Self.log.info("Talk history off")
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
                replyLanguage: locale,
                maximumResponseTokens: 72,
                temperature: 0
            )
            let modelMs = Int(Date().timeIntervalSince(modelStarted) * 1000)
            let totalMs = Int(Date().timeIntervalSince(answerStarted) * 1000)
            let foldedReply = Self.asciiFold(reply)
            let missing = reply.contains("NOT_IN_NOTES") || reply.isEmpty
                || foldedReply.contains("not contain")
                || foldedReply.contains("do not contain")
                || foldedReply.contains("notes do not")
            Self.log.info(
                "Talk answer done modelMs=\(modelMs) totalMs=\(totalMs) retrieveMs=\(retrieveMs) notInNotes=\(missing) characters=\(reply.count) text=\(reply, privacy: .public)"
            )
            if missing {
                return TalkReply(text: String(localized: "The lectures do not contain that."))
            }
            let sources = sourcesForAnswer(question: question, reply: reply, pick: pick)
            let sourceKind =
                isScheduleQuestion(question) ? "schedule"
                : isAssignmentCatalogQuestion(question) ? "assignment"
                : isExamCatalogQuestion(question) ? "exam"
                : isInventoryCatalogQuestion(question) ? "inventory"
                : "note"
            Self.log.info(
                "Talk sources count=\(sources.count) kind=\(sourceKind, privacy: .public) question=\(question, privacy: .public)"
            )
            for (index, item) in sources.enumerated() {
                Self.log.info(
                    "Talk sourceMenu[\(index)] title=\(item.title, privacy: .public) target=\(String(describing: item.target), privacy: .public)"
                )
            }
            return TalkReply(text: reply, sources: sources)
        } catch is CancellationError {
            Self.log.info("Talk answer cancelled ms=\(Int(Date().timeIntervalSince(answerStarted) * 1000))")
            return TalkReply(text: "")
        } catch {
            Self.log.error(
                "Talk answer failed ms=\(Int(Date().timeIntervalSince(answerStarted) * 1000)) \(error.localizedDescription, privacy: .public)"
            )
            return TalkReply(text: String(localized: "A model is not available."))
        }
    }

    /// Catalogue inventory (slots / assignments / exams / books) → course rows. Lecture content → BM25 notes.
    private func sourcesForAnswer(question: String, reply: String, pick: StudySelection.Pick) -> [TalkSourceItem] {
        if isScheduleQuestion(question) {
            return timetableSources(for: question)
        }
        if isAssignmentCatalogQuestion(question) {
            return assignmentSources(for: question, reply: reply)
        }
        if isExamCatalogQuestion(question) {
            return examSources(for: question)
        }
        if isInventoryCatalogQuestion(question) {
            return inventorySources(for: question)
        }
        return noteSources(question: question, pick: pick)
    }

    /// Same idea as Ask’s Source: one Raw minute. Ask scopes to a course/lecture so BM25
    /// `pick.source` is enough; Talk searches the whole library, so when the topic stem hits
    /// another picked block harder than that primary, use that block instead (still one row).
    private func noteSources(question: String, pick: StudySelection.Pick) -> [TalkSourceItem] {
        let keys = Self.contentTokens(for: question)
        Self.log.info(
            "Talk source keys count=\(keys.count) keys=\(keys.joined(separator: ","), privacy: .public) question=\(question, privacy: .public)"
        )
        func score(_ block: StudyBlock) -> Int {
            Self.topicScore(of: block, keys: keys)
        }
        let primary = pick.source
        let topicBest = pick.blocks.max { score($0) < score($1) }
        let chosen: StudyBlock?
        if let topicBest, score(topicBest) > 0 {
            let primaryScore = primary.map(score) ?? 0
            // Whole-library BM25 often ranks a “nedir / anlat” neighbour first; prefer topic hit.
            chosen = score(topicBest) > primaryScore ? topicBest : (primary ?? topicBest)
        } else {
            // No topic word from the question is in these notes. Do not cite an unrelated minute.
            return []
        }
        guard let chosen else { return [] }
        Self.log.info(
            "Talk source chosen score=\(score(chosen)) primaryScore=\(primary.map(score) ?? -1) second=\(chosen.second) title=\(Self.noteSourceTitle(chosen), privacy: .public)"
        )
        return [
            TalkSourceItem(
                title: Self.noteSourceTitle(chosen),
                target: .note(blockID: chosen.id, second: chosen.second)
            )
        ]
    }

    /// Topic words from the question; drops filler so “anlatıldı / bana / nedir” do not steer Source.
    private static func contentTokens(for text: String) -> [String] {
        let stop: Set<String> = [
            "ne", "neler", "nedir", "nasil", "hangi", "var", "mi", "misin", "bir", "bu", "su", "o",
            "hakkinda", "hakkindaki", "icin", "ile", "ve", "de", "da", "ki", "kadar",
            "ders", "dersler", "derslerde", "dersin", "dersimi", "kayit", "kayitlar",
            "not", "notlar", "notlarda", "notes", "lecture", "lectures", "class", "classes",
            "what", "about", "tell", "was", "were", "did", "the", "in", "on", "for", "whats",
            "pardon", "tamam", "ok", "okay", "lutfen", "please",
            "evet", "hayir", "yok", "yes", "yeah", "nope",
            "selam", "merhaba", "hello", "hiya", "hey",
            "bana", "bizi", "beni", "sana", "size", "seni", "senin",
            "benim", "onun", "bizim", "sizin", "bunu", "sunu",
            "detay", "detayli", "kisa", "kisaca", "biraz",
        ]
        return asciiFold(text)
            .split { !$0.isLetter }
            .map(String.init)
            .filter { token in
                token.count >= 4
                    && !stop.contains(token)
                    && !token.hasPrefix("anlat")
                    && !token.hasPrefix("anlad")
                    && !token.hasPrefix("anlasil")
                    && !token.hasPrefix("soyle")
                    && !token.hasPrefix("ders")
            }
    }

    /// How strongly a note matches the question’s topic words. Zero means those words are not in the note.
    private static func topicScore(of block: StudyBlock, keys: [String]) -> Int {
        guard !keys.isEmpty else { return 0 }
        let hay = asciiFold(block.text)
        let stems = Set(
            hay.split { !$0.isLetter }
                .map { String($0.prefix(5)) }
                .filter { $0.count >= 5 }
        )
        return keys.reduce(0) { partial, key in
            if hay.contains(key) { return partial + max(key.count, 1) }
            // Four letters is enough for “sıcak” to look like an unrelated word. Five keeps real endings such as “türev” / “türevini”.
            let stem = String(key.prefix(5))
            guard stem.count >= 5, stems.contains(stem) else { return partial }
            return partial + max(key.count, 1)
        }
    }

    /// Day yes/no and weekly duration are read from the slots. The model was inventing a class on an empty day and refusing to add the clocks.
    private func timetableReply(for question: String) -> TalkReply? {
        guard isScheduleQuestion(question) else { return nil }
        let folded = Self.asciiFold(question)
        let duration =
            folded.contains("kac saat") || folded.contains("kac dakika")
            || folded.contains("how many hour") || folded.contains("how many minute")
            || folded.contains("how long")
        let aboutRecording =
            folded.contains("kayit") || folded.contains("kayd") || folded.contains("recording")
        let dayAsk =
            askedWeekday(in: question) != nil
            && (folded.contains("ders") || folded.contains("class") || folded.contains("lecture")
                || folded.contains("course"))
            && !aboutRecording
            && !folded.contains("odev") && !folded.contains("assignment") && !folded.contains("homework")
        guard duration || dayAsk else { return nil }
        let slots = matchingSlots(in: question)
        let sources = timetableSources(for: question)
        if duration {
            let minutes = slots.reduce(0) { sum, fact in
                sum + max(fact.slot.endMinutes - fact.slot.startMinutes, 0)
            }
            let hours = minutes / 60
            let mins = minutes % 60
            let text = String(localized: "Your classes add up to \(hours) hours and \(mins) minutes.")
            return TalkReply(text: text, sources: sources)
        }
        let calendar = Calendar.current
        let symbols = calendar.standaloneWeekdaySymbols
        let weekday = slots.first?.slot.weekday ?? askedWeekday(in: question) ?? calendar.component(.weekday, from: .now)
        let day = symbols.indices.contains(weekday - 1) ? symbols[weekday - 1] : ""
        if slots.isEmpty {
            return TalkReply(text: String(localized: "You have no class on \(day)."), sources: [])
        }
        let list = sources.map(\.title).joined(separator: ", ")
        return TalkReply(text: String(localized: "On \(day) you have \(list)."), sources: sources)
    }

    private struct SlotFact {
        let term: Term
        let slot: WeeklySlot
        let courseName: String
    }

    private func matchingSlots(in question: String) -> [SlotFact] {
        let onlyWeekday = askedWeekday(in: question)
        let asked = Self.asciiFold(question)
        let named = namesOpenCourse(asked)
        var facts: [SlotFact] = []
        let pool = terms.filter(\.isOpen)
        let termsToScan = pool.isEmpty ? terms : pool
        for term in termsToScan {
            for slot in term.slots.sorted(by: { ($0.weekday, $0.startMinutes) < ($1.weekday, $1.startMinutes) }) {
                guard let course = slot.course else { continue }
                if let onlyWeekday, slot.weekday != onlyWeekday { continue }
                let courseName = Self.asciiFold(course.name)
                if named, courseName.count >= 3, !asked.contains(courseName) { continue }
                facts.append(SlotFact(term: term, slot: slot, courseName: course.name))
            }
        }
        return facts
    }

    /// “Bekleyen kayıt”, “kaydettiğim”, “bugün kaydettiklerim” open the lecture, not a Raw minute.
    private func unprocessedRecordingReply(for question: String) -> TalkReply? {
        guard let slice = recordingSlice(in: question) else { return nil }
        let lectures = unprocessedLectures(in: question, slice: slice)
        let sources = lectures.map { lecture in
            let course = lecture.course?.name ?? ""
            let day = lecture.startedAt.formatted(date: .abbreviated, time: .omitted)
            let status = lecture.statusTitle
            let title = course.isEmpty ? "\(day) · \(status)" : "\(course) · \(day) · \(status)"
            return TalkSourceItem(
                title: title,
                target: .recording(lectureID: lecture.persistentModelID)
            )
        }
        if lectures.isEmpty {
            let empty: String
            if slice == .ready {
                empty = String(localized: "You have no processed recordings.")
            } else if recordingDay(in: question) == nil && slice != .any {
                empty = String(localized: "You have no unprocessed recordings.")
            } else {
                empty = String(localized: "You have no recordings then.")
            }
            return TalkReply(text: empty, sources: [])
        }
        let summary = unprocessedSummary(lectures)
        let text: String
        switch slice {
        case .any:
            text = String(localized: "Recordings: \(summary).")
        case .ready:
            text = String(localized: "Processed recordings: \(summary).")
        case .unprocessed, .recordedOnly, .pausedOnly:
            text = String(localized: "Unprocessed recordings: \(summary).")
        }
        return TalkReply(text: text, sources: sources)
    }

    private enum RecordingSlice {
        /// Not ready yet: Kaydedildi, Duraklatıldı, and anything still processing.
        case unprocessed
        /// Saved and not processed. “Kaydedilmiş ama işlenmemiş.”
        case recordedOnly
        case pausedOnly
        /// Ready. “İşlenmiş kaç kayıt.”
        case ready
        /// “Kaydettiğim”, “bugün kaydettiklerim”: every state, then the day filter.
        case any
    }

    /// Saved-and-waiting, paused, or every recording the student captured.
    /// A named day keeps that day’s `startedAt`. “Kayıtta ne anlatıldı” stays on the notes.
    private func unprocessedLectures(in question: String, slice: RecordingSlice) -> [Lecture] {
        let asked = Self.asciiFold(question)
        let named = namesOpenCourse(asked)
        let day = recordingDay(in: question)
        var lectures: [Lecture] = []
        let pool = terms.filter(\.isOpen)
        let termsToScan = pool.isEmpty ? terms : pool
        for term in termsToScan {
            for course in term.courses {
                let courseName = Self.asciiFold(course.name)
                if named, courseName.count >= 3, !asked.contains(courseName) { continue }
                for lecture in course.lectures {
                    if let day, !day(lecture) { continue }
                    switch slice {
                    case .recordedOnly:
                        if lecture.isRecordedOnly { lectures.append(lecture) }
                    case .pausedOnly:
                        if lecture.state == LectureState.paused.rawValue && !lecture.isRecordedOnly {
                            lectures.append(lecture)
                        }
                    case .unprocessed:
                        if lecture.state != LectureState.ready.rawValue { lectures.append(lecture) }
                    case .ready:
                        if lecture.state == LectureState.ready.rawValue { lectures.append(lecture) }
                    case .any:
                        lectures.append(lecture)
                    }
                }
            }
        }
        return lectures.sorted { lhs, rhs in
            let left = lhs.course?.name ?? ""
            let right = rhs.course?.name ?? ""
            if left != right { return left.localizedCaseInsensitiveCompare(right) == .orderedAscending }
            return lhs.startedAt > rhs.startedAt
        }
    }

    /// Today, yesterday, tomorrow, this week, or a named weekday. Nil means every day.
    private func recordingDay(in question: String) -> ((Lecture) -> Bool)? {
        let tokens = Self.asciiFold(question).split { !$0.isLetter }.map(String.init)
        let calendar = Calendar.current
        if tokens.contains("bugun") || tokens.contains("today") {
            return { calendar.isDateInToday($0.startedAt) }
        }
        if tokens.contains("dun") || tokens.contains(where: { $0.hasPrefix("dunden") }) || tokens.contains("yesterday") {
            return { calendar.isDateInYesterday($0.startedAt) }
        }
        if tokens.contains("yarin") || tokens.contains("tomorrow") {
            return { calendar.isDateInTomorrow($0.startedAt) }
        }
        if tokens.contains("hafta") || tokens.contains("week") {
            return { calendar.isDate($0.startedAt, equalTo: .now, toGranularity: .weekOfYear) }
        }
        let symbols = calendar.standaloneWeekdaySymbols
        for (index, name) in symbols.enumerated() {
            let foldedName = Self.asciiFold(name)
            guard foldedName.count >= 3, tokens.contains(where: { $0.hasPrefix(foldedName) }) else { continue }
            let weekday = index + 1
            return { calendar.component(.weekday, from: $0.startedAt) == weekday }
        }
        return nil
    }

    private func unprocessedSummary(_ lectures: [Lecture]) -> String {
        var counts: [(course: String, status: String, count: Int)] = []
        for lecture in lectures {
            let course = lecture.course?.name ?? ""
            let status = lecture.statusTitle
            if let index = counts.firstIndex(where: { $0.course == course && $0.status == status }) {
                counts[index].count += 1
            } else {
                counts.append((course, status, 1))
            }
        }
        let body = counts.map { "\($0.count) \($0.course) \($0.status)" }.joined(separator: ", ")
        return "\(lectures.count), \(body)"
    }

    /// Recordings the student captured or that are still waiting.
    /// “Kaydettiğim”, “kaydedilen”, “ses kaydı aldığım”, “kayıt ettiğim”, “beklemede”, “bugün / dün”.
    /// “Kayıtta ne anlatıldı” stays on the notes.
    private func recordingSlice(in text: String) -> RecordingSlice? {
        let folded = Self.asciiFold(text)
        let tokens = folded.split { !$0.isLetter }.map(String.init)
        let aboutRecording = tokens.contains {
            $0.hasPrefix("kayit") || $0.hasPrefix("kayd") || $0.hasPrefix("kaydet")
                || $0 == "record" || $0 == "recorded" || $0.hasPrefix("recording")
        }
        guard aboutRecording else { return nil }
        let capture = tokens.contains { $0.hasPrefix("kaydet") || $0.hasPrefix("kaydedil") || $0.hasPrefix("kayda") }
            || (tokens.contains { $0.hasPrefix("kayit") || $0.hasPrefix("kayd") }
                && tokens.contains { $0.hasPrefix("ett") || $0.hasPrefix("ald") })
            || tokens.contains { $0 == "recorded" || $0 == "saved" || $0 == "record" }
            || (tokens.contains { $0.hasPrefix("recording") || $0 == "record" }
                && tokens.contains { ["made", "took", "captured", "voice", "audio"].contains($0) })
        let pending = tokens.contains { token in
            token.hasPrefix("islenmem") || token.hasPrefix("islenmedi")
                || token.hasPrefix("bekle")
                || token.hasPrefix("duraklat")
                || token == "unprocessed" || token == "pending" || token == "paused" || token == "waiting"
                || token == "hold" || token == "queued"
        } || (tokens.contains { ["not", "haven", "didn"].contains($0) }
            && tokens.contains { $0.hasPrefix("process") || $0 == "ready" })
        let processed = tokens.contains { token in
            if token.hasPrefix("islenmem") || token.hasPrefix("islenmedi") { return false }
            return token.hasPrefix("islenmis") || token.hasPrefix("islenen") || token.hasPrefix("islendi")
                || token.hasPrefix("isledig") || token.hasPrefix("isledim") || token.hasPrefix("hazir")
                || token == "processed" || token == "ready" || token == "finished"
        }
        let dated = tokens.contains { ["bugun", "dun", "yarin", "today", "yesterday", "tomorrow", "hafta", "week"].contains($0) }
            || tokens.contains { $0.hasPrefix("dunden") }
        let content = asksForLectureNotes(folded)
        if content && !pending && !capture && !dated && !processed { return nil }
        guard pending || capture || dated || processed else { return nil }
        let saved = tokens.contains { $0.hasPrefix("kaydedil") || $0 == "recorded" || $0 == "saved" }
        let paused = tokens.contains { $0.hasPrefix("duraklat") || $0 == "paused" }
        if processed && !pending { return .ready }
        if pending && saved && !paused { return .recordedOnly }
        if pending && paused && !saved { return .pausedOnly }
        if pending { return .unprocessed }
        return .any
    }

    /// One row on the lecturer sheet, or every filled row when the question asks for the details.
    /// Raw notes are not the source. An empty field stays empty.
    private enum LecturerField {
        case name
        case title
        case givenName
        case familyName
        case phone
        case email
        case extra
        case all
    }

    /// The value stored on the course’s lecturer. Source opens that lecturer sheet.
    private func lecturerReply(for question: String) -> TalkReply? {
        guard let field = lecturerField(in: question) else { return nil }
        let courses = catalogueCourses(in: question)
        guard !courses.isEmpty else { return nil }
        var lines: [String] = []
        var sources: [TalkSourceItem] = []
        for course in courses {
            lines.append(lecturerSentence(field, course: course))
            sources.append(
                TalkSourceItem(title: course.name, target: .lecturer(courseID: course.persistentModelID))
            )
        }
        return TalkReply(text: lines.joined(separator: " "), sources: sources)
    }

    private func lecturerSentence(_ field: LecturerField, course: Course) -> String {
        if field == .all {
            let filled = lecturerDetailLines(on: course)
            if filled.isEmpty {
                return String(format: String(localized: "No lecturer details are stored for %@."), course.name)
            }
            return String(format: String(localized: "Lecturer details for %@ are %@."), course.name, filled)
        }
        let stored = lecturerValue(field, on: course)
        if stored.isEmpty {
            return String(format: String(localized: lecturerMissingKey(field)), course.name)
        }
        return String(format: String(localized: lecturerAnswerKey(field)), course.name, stored)
    }

    /// Sheet order: title, given name, family name, phone, email, other contact. Empty rows are left out.
    private func lecturerDetailLines(on course: Course) -> String {
        let rows: [(label: String, field: LecturerField)] = [
            (String(localized: "Title"), .title),
            (String(localized: "Given name"), .givenName),
            (String(localized: "Family name"), .familyName),
            (String(localized: "Phone"), .phone),
            (String(localized: "Email"), .email),
            (String(localized: "Other contact"), .extra),
        ]
        return rows.compactMap { row in
            let value = lecturerValue(row.field, on: course)
            guard !value.isEmpty else { return nil }
            return "\(row.label) \(value)"
        }.joined(separator: ", ")
    }

    private func lecturerValue(_ field: LecturerField, on course: Course) -> String {
        let contact = course.lecturer
        let raw: String
        switch field {
        case .name:
            raw = contact?.displayName ?? ""
        case .title:
            raw = contact?.title ?? ""
        case .givenName:
            raw = contact?.givenName ?? ""
        case .familyName:
            raw = contact?.familyName ?? ""
        case .phone:
            raw = contact?.phone ?? ""
        case .email:
            raw = contact?.email ?? ""
        case .extra:
            raw = contact?.extra ?? ""
        case .all:
            raw = ""
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Catalog keys. The spoken course and the stored value fill the blanks.
    private func lecturerAnswerKey(_ field: LecturerField) -> String.LocalizationValue {
        switch field {
        case .name: "The lecturer for %@ is %@."
        case .title: "The title for %@ is %@."
        case .givenName: "The given name for %@ is %@."
        case .familyName: "The family name for %@ is %@."
        case .phone: "The phone for %@ is %@."
        case .email: "The email for %@ is %@."
        case .extra: "The other contact for %@ is %@."
        case .all: "Lecturer details for %@ are %@."
        }
    }

    private func lecturerMissingKey(_ field: LecturerField) -> String.LocalizationValue {
        switch field {
        case .name: "No lecturer name is stored for %@."
        case .title: "No title is stored for %@."
        case .givenName: "No given name is stored for %@."
        case .familyName: "No family name is stored for %@."
        case .phone: "No phone is stored for %@."
        case .email: "No email is stored for %@."
        case .extra: "No other contact is stored for %@."
        case .all: "No lecturer details are stored for %@."
        }
    }

    /// Any row on the lecturer sheet. “Hoca ne anlattı” stays on the notes.
    private func lecturerField(in text: String) -> LecturerField? {
        let tokens = Self.asciiFold(text).split { !$0.isLetter }.map(String.init)
        let aboutLecturer = tokens.contains { token in
            token.hasPrefix("hoca") || token.hasPrefix("ogretmen") || token.hasPrefix("ogretim")
                || token.hasPrefix("lecturer") || token.hasPrefix("teacher")
                || token == "prof" || token.hasPrefix("professor") || token.hasPrefix("instructor")
        }
        guard aboutLecturer else { return nil }
        if tokens.contains(where: {
            $0.hasPrefix("telefon") || $0 == "phone" || $0 == "gsm" || $0 == "cep"
                || $0.hasPrefix("numara") || $0 == "number"
        }) {
            return .phone
        }
        if tokens.contains(where: {
            $0 == "email" || $0.hasPrefix("eposta") || $0.hasPrefix("mail") || $0 == "posta"
        }) {
            return .email
        }
        let otherContact = tokens.contains("diger") && tokens.contains { $0.hasPrefix("iletisim") }
            || tokens.contains("other") && tokens.contains("contact")
        if otherContact {
            return .extra
        }
        if tokens.contains(where: { $0.hasPrefix("soyad") || $0 == "surname" || $0.hasPrefix("lastname") })
            || (tokens.contains("family") && tokens.contains("name"))
            || (tokens.contains("last") && tokens.contains("name"))
        {
            return .familyName
        }
        if tokens.contains(where: { $0.hasPrefix("unvan") }) || tokens.contains("title") {
            return .title
        }
        if tokens.contains("given") || (tokens.contains("first") && tokens.contains("name")) {
            return .givenName
        }
        // “Ad” is the whole stored name: title, given name, and family name together.
        let asksName = tokens.contains { token in
            token.hasPrefix("isim") || token.hasPrefix("ismi")
                || token == "ad" || token == "adi" || token.hasPrefix("adin")
                || token == "kim" || token.hasPrefix("kimdir") || token.hasPrefix("kimin")
                || token == "who" || token == "name" || token.hasPrefix("named")
        }
        if asksName { return .name }
        let asksAll = tokens.contains { token in
            token == "bilgi" || token.hasPrefix("bilgisi") || token.hasPrefix("bilgiler")
                || token == "info" || token == "details" || token == "detail"
        }
        return asksAll ? .all : nil
    }

    /// A name the student typed on Raw. The on-screen Speaker / Konuşmacı label is not one.
    private struct NamedSpeaker {
        var name: String
        var tokens: [String]
    }

    /// Any typed name, not one example. “How many recordings does this name have” lists them.
    /// “What did this name say this week” and “what did they say two weeks ago” read that
    /// name’s raw lines in the span. An empty span says there is no recording. The model is not called.
    private func speakerReply(for question: String) -> TalkReply? {
        let tokens = Self.asciiFold(question).split { !$0.isLetter }.map(String.init)
        guard let speaker = namedSpeaker(in: tokens) else { return nil }
        guard let kind = speakerAsk(in: tokens) else { return nil }
        let span = coveredSpan(in: question)
        let turns = speakerTurns(named: speaker, span: span)
        switch kind {
        case .recordings:
            return speakerRecordingReply(name: speaker.name, turns: turns, span: span)
        case .words:
            return speakerWordsReply(name: speaker.name, turns: turns, span: span)
        }
    }

    private enum SpeakerAsk {
        case recordings
        case words
    }

    /// A recording count, or a question about what that person said. A bare name is not enough.
    private func speakerAsk(in tokens: [String]) -> SpeakerAsk? {
        let speech = tokens.contains { token in
            token.hasPrefix("anlat") || token.hasPrefix("dedi") || token.hasPrefix("demis")
                || token.hasPrefix("soyle") || token.hasPrefix("konus")
                || token == "said" || token == "say" || token.hasPrefix("spoke") || token.hasPrefix("spoken")
                || token.hasPrefix("tell") || token == "cover" || token.hasPrefix("covered")
        }
        if speech { return .words }
        let count = tokens.contains("kac") || tokens.contains("many")
        let recordings = tokens.contains { token in
            token.hasPrefix("kayit") || token.hasPrefix("kayd") || token.hasPrefix("record")
        }
        if count || recordings { return .recordings }
        return nil
    }

    /// Longest stored name whose tokens sit in the question. The last token may carry a Turkish suffix.
    private func namedSpeaker(in question: [String]) -> NamedSpeaker? {
        let hits = namedSpeakers().filter { Self.mentionsSpeaker($0.tokens, in: question) }
        return hits.max { lhs, rhs in
            if lhs.tokens.count != rhs.tokens.count { return lhs.tokens.count < rhs.tokens.count }
            let left = lhs.tokens.joined().count
            let right = rhs.tokens.joined().count
            return left < right
        }
    }

    private func namedSpeakers() -> [NamedSpeaker] {
        var byKey: [String: NamedSpeaker] = [:]
        for term in terms {
            for course in term.courses {
                for lecture in course.lectures {
                    for line in lecture.speakerNames {
                        guard let name = Self.storedSpeakerName(line), !Self.isDefaultSpeakerLabel(name) else { continue }
                        let tokens = Self.asciiFold(name)
                            .split { !$0.isLetter }
                            .map(String.init)
                            .filter { $0.count >= 3 }
                        guard !tokens.isEmpty else { continue }
                        let key = tokens.joined(separator: " ")
                        if byKey[key] == nil {
                            byKey[key] = NamedSpeaker(name: name, tokens: tokens)
                        }
                    }
                }
            }
        }
        return Array(byKey.values)
    }

    /// `speakerNames` stores `cluster` + tab + the typed name.
    private static func storedSpeakerName(_ line: String) -> String? {
        guard let tab = line.firstIndex(of: "\t") else { return nil }
        let name = line[line.index(after: tab)...].trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : String(name)
    }

    /// The raw row’s own label: “Speaker 4”, “Konuşmacı 1”. A typed name is something else.
    private static func isDefaultSpeakerLabel(_ name: String) -> Bool {
        let tokens = asciiFold(name).split { !$0.isLetter }.map(String.init)
        guard tokens.count == 1 else { return false }
        return tokens[0] == "speaker" || tokens[0] == "konusmaci"
    }

    private static func mentionsSpeaker(_ nameTokens: [String], in question: [String]) -> Bool {
        guard !nameTokens.isEmpty, question.count >= nameTokens.count else { return false }
        let last = nameTokens.count - 1
        for start in 0...(question.count - nameTokens.count) {
            var matched = true
            for offset in 0..<nameTokens.count {
                let token = question[start + offset]
                let name = nameTokens[offset]
                let same = offset == last ? speakerToken(token, is: name) : token == name
                if !same {
                    matched = false
                    break
                }
            }
            if matched { return true }
        }
        return false
    }

    /// Exact token, or the name plus a folded Turkish case ending.
    private static func speakerToken(_ token: String, is name: String) -> Bool {
        if token == name { return true }
        guard token.hasPrefix(name), name.count >= 3 else { return false }
        let rest = String(token.dropFirst(name.count))
        let suffixes: Set<String> = [
            "in", "un", "nin", "nun",
            "i", "u", "e", "a",
            "yi", "yu", "ye", "ya",
            "de", "da", "te", "ta", "den", "dan", "ten", "tan",
            "le", "la",
        ]
        return suffixes.contains(rest)
    }

    /// Raw lines whose stored speaker name is this one. A span keeps lectures that started in it.
    private func speakerTurns(named speaker: NamedSpeaker, span: DateInterval?) -> [(lecture: Lecture, block: Block)] {
        let key = speaker.tokens.joined(separator: " ")
        var turns: [(lecture: Lecture, block: Block)] = []
        for term in terms {
            for course in term.courses {
                for lecture in course.lectures {
                    if let span, !span.contains(lecture.startedAt) { continue }
                    let ordered = lecture.blocks.sorted { $0.second < $1.second }
                    for block in ordered {
                        guard let stored = lecture.speakerName(for: block.speaker),
                              !Self.isDefaultSpeakerLabel(stored) else { continue }
                        let tokens = Self.asciiFold(stored)
                            .split { !$0.isLetter }
                            .map(String.init)
                            .filter { $0.count >= 3 }
                        guard tokens.joined(separator: " ") == key else { continue }
                        let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { continue }
                        turns.append((lecture, block))
                    }
                }
            }
        }
        return turns.sorted { lhs, rhs in
            if lhs.lecture.startedAt != rhs.lecture.startedAt {
                return lhs.lecture.startedAt < rhs.lecture.startedAt
            }
            return lhs.block.second < rhs.block.second
        }
    }

    private func speakerRecordingReply(
        name: String,
        turns: [(lecture: Lecture, block: Block)],
        span: DateInterval?
    ) -> TalkReply {
        let lectures = uniqueLectures(in: turns)
        if lectures.isEmpty {
            let key: String.LocalizationValue = span == nil
                ? "%@ has no recordings."
                : "%@ has no recording from then."
            return TalkReply(text: String(format: String(localized: key), name))
        }
        let stamp = Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale)
        let body = lectures.map { lecture in
            lectureLabel(lecture, stamp: stamp)
        }.joined(separator: ", ")
        let sources = lectures.map { lecture in
            TalkSourceItem(
                title: lectureLabel(lecture, stamp: stamp),
                target: .recording(lectureID: lecture.persistentModelID)
            )
        }
        let text = String(
            format: String(localized: "%1$@ is in %2$lld recordings: %3$@."),
            name,
            lectures.count,
            body
        )
        return TalkReply(text: text, sources: sources)
    }

    private func speakerWordsReply(
        name: String,
        turns: [(lecture: Lecture, block: Block)],
        span: DateInterval?
    ) -> TalkReply {
        if turns.isEmpty {
            let key: String.LocalizationValue = span == nil
                ? "%@ has no recordings."
                : "%@ has no recording from then."
            return TalkReply(text: String(format: String(localized: key), name))
        }
        let stamp = Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale)
        var pieces: [String] = []
        var sources: [TalkSourceItem] = []
        var seen: [PersistentIdentifier] = []
        for turn in turns {
            let id = turn.lecture.persistentModelID
            let text = turn.block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !seen.contains(id) {
                seen.append(id)
                pieces.append("\(lectureLabel(turn.lecture, stamp: stamp)): \(text)")
                sources.append(
                    TalkSourceItem(
                        title: lectureLabel(turn.lecture, stamp: stamp),
                        target: .note(blockID: turn.block.token, second: turn.block.second)
                    )
                )
            } else if let index = pieces.indices.last {
                pieces[index] += " \(text)"
            }
        }
        let spoken = pieces.joined(separator: " ")
        let clipped = Self.clippedSpeakerText(spoken)
        let key: String.LocalizationValue = clipped.trimmed
            ? "%1$@ said: %2$@ The rest is in the recording."
            : "%1$@ said: %2$@"
        return TalkReply(
            text: String(format: String(localized: key), name, clipped.text),
            sources: sources
        )
    }

    /// Spoken replies stay short enough to say. The Source still opens the first raw line.
    private static func clippedSpeakerText(_ text: String) -> (text: String, trimmed: Bool) {
        let limit = 1200
        guard text.count > limit else { return (text, false) }
        let end = text.index(text.startIndex, offsetBy: limit)
        var clipped = String(text[..<end])
        if let space = clipped.lastIndex(of: " "), clipped.distance(from: clipped.startIndex, to: space) > limit / 2 {
            clipped = String(clipped[..<space])
        }
        return (clipped.trimmingCharacters(in: .whitespacesAndNewlines), true)
    }

    private func uniqueLectures(in turns: [(lecture: Lecture, block: Block)]) -> [Lecture] {
        var lectures: [Lecture] = []
        var seen: [PersistentIdentifier] = []
        for turn in turns {
            let id = turn.lecture.persistentModelID
            guard !seen.contains(id) else { continue }
            seen.append(id)
            lectures.append(turn.lecture)
        }
        return lectures
    }

    private func lectureLabel(_ lecture: Lecture, stamp: Date.FormatStyle) -> String {
        let course = lecture.course?.name ?? ""
        let day = lecture.startedAt.formatted(stamp)
        let title = lecture.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if course.isEmpty { return title.isEmpty ? day : "\(day) \(title)" }
        if title.isEmpty { return "\(course) \(day)" }
        return "\(course) \(day) \(title)"
    }

    /// What was covered in a past span, from lectures dated in that span.
    /// Another day’s notes are not used when the span is empty.
    private func coveredThenReply(for question: String) -> TalkReply? {
        guard asksWhatWasCovered(question), let span = coveredSpan(in: question) else { return nil }
        let courses = catalogueCourses(in: question)
        let lectures = courses
            .flatMap(\.lectures)
            .filter { span.contains($0.startedAt) }
            .sorted { $0.startedAt < $1.startedAt }
        guard !lectures.isEmpty else {
            return TalkReply(text: String(localized: "You have no lecture from then."))
        }
        let stamp = Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale)
        let body = lectures.map { lecture in
            let course = lecture.course?.name ?? ""
            let day = lecture.startedAt.formatted(stamp)
            let title = lecture.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? "\(course) \(day)" : "\(course) \(day) \(title)"
        }.joined(separator: ", ")
        let sources = lectures.map { lecture in
            let course = lecture.course?.name ?? ""
            let day = lecture.startedAt.formatted(stamp)
            return TalkSourceItem(
                title: "\(course) · \(day)",
                target: .recording(lectureID: lecture.persistentModelID)
            )
        }
        return TalkReply(
            text: String(format: String(localized: "Lectures from then: %@."), body),
            sources: sources
        )
    }

    /// Covered, taught, or explained. “İşlenmiş kayıt” is a recording status and is not this.
    private func asksWhatWasCovered(_ text: String) -> Bool {
        let tokens = Self.asciiFold(text).split { !$0.isLetter }.map(String.init)
        return tokens.contains { token in
            (token.hasPrefix("isle") && !token.hasPrefix("islen"))
                || token.hasPrefix("konu")
                || token.hasPrefix("anlat")
                || token.hasPrefix("gord")
                || token == "cover" || token.hasPrefix("covered")
                || token == "taught" || token.hasPrefix("teach")
        }
    }

    /// The calendar span the question names: a counted week or day before today, last week, this week, yesterday, today.
    private func coveredSpan(in question: String) -> DateInterval? {
        let calendar = Calendar.current
        if let ago = DueDateMath.agoSpan(in: question) {
            switch ago {
            case .weeks(let count):
                return weekInterval(weeksBack: count, calendar: calendar)
            case .days(let count):
                return dayInterval(daysBack: count, calendar: calendar)
            }
        }
        let tokens = Self.asciiFold(question).split { !$0.isLetter }.map(String.init)
        let week = tokens.contains("hafta") || tokens.contains { $0.hasPrefix("week") }
        if week && (tokens.contains("gecen") || tokens.contains("last")) {
            return weekInterval(weeksBack: 1, calendar: calendar)
        }
        if week && (tokens.contains("bu") || tokens.contains("this")) {
            return weekInterval(weeksBack: 0, calendar: calendar)
        }
        if tokens.contains("dun") || tokens.contains(where: { $0.hasPrefix("dunden") }) || tokens.contains("yesterday") {
            return dayInterval(daysBack: 1, calendar: calendar)
        }
        if tokens.contains("bugun") || tokens.contains("today") {
            return dayInterval(daysBack: 0, calendar: calendar)
        }
        return nil
    }

    private func weekInterval(weeksBack: Int, calendar: Calendar) -> DateInterval? {
        guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: .now),
              let start = calendar.date(byAdding: .weekOfYear, value: -weeksBack, to: thisWeek.start)
        else { return nil }
        return calendar.dateInterval(of: .weekOfYear, for: start)
    }

    private func dayInterval(daysBack: Int, calendar: Calendar) -> DateInterval? {
        let start = calendar.date(byAdding: .day, value: -daysBack, to: calendar.startOfDay(for: .now))
            ?? calendar.startOfDay(for: .now)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        return DateInterval(start: start, end: end)
    }

    private func timetableSources(for question: String) -> [TalkSourceItem] {
        let symbols = Calendar.current.standaloneWeekdaySymbols
        return matchingSlots(in: question).map { fact in
            let day = symbols.indices.contains(fact.slot.weekday - 1) ? symbols[fact.slot.weekday - 1] : "?"
            let clock = ReminderScheduler.clock(fact.slot.startMinutes)
            return TalkSourceItem(
                title: "\(day) \(clock) · \(fact.courseName)",
                target: .timetable(
                    termID: fact.term.persistentModelID,
                    weekday: fact.slot.weekday,
                    startMinutes: fact.slot.startMinutes
                )
            )
        }
    }

    /// Courses named in the question, or every course of the open term when none is named.
    private func catalogueCourses(in question: String) -> [Course] {
        let folded = Self.asciiFold(question)
        let named = namesOpenCourse(folded)
        let pool = terms.filter(\.isOpen)
        let termsToScan = pool.isEmpty ? terms : pool
        var courses: [Course] = []
        for term in termsToScan {
            let ordered = term.courses.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            for course in ordered {
                let name = Self.asciiFold(course.name)
                if named, name.count >= 3, !folded.contains(name) { continue }
                courses.append(course)
            }
        }
        return courses
    }

    /// Today, tomorrow, or a named weekday in the question. Nil means every slot.
    private func askedWeekday(in question: String) -> Int? {
        let folded = Self.asciiFold(question)
        let calendar = Calendar.current
        if folded.contains("yarin") || folded.contains("tomorrow") {
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: .now) ?? .now
            return calendar.component(.weekday, from: tomorrow)
        }
        if folded.contains("bugun") || folded.contains("today") {
            return calendar.component(.weekday, from: .now)
        }
        if folded.contains("dun") || folded.contains("yesterday") {
            let yesterday = calendar.date(byAdding: .day, value: -1, to: .now) ?? .now
            return calendar.component(.weekday, from: yesterday)
        }
        let symbols = calendar.standaloneWeekdaySymbols
        for (index, name) in symbols.enumerated() {
            let foldedName = Self.asciiFold(name)
            if foldedName.count >= 3, folded.contains(foldedName) { return index + 1 }
        }
        return nil
    }

    /// The week the course page uses for a recording: the calendar week that contains that day.
    private func weekStart(of date: Date) -> Date {
        Calendar.current.dateInterval(of: .weekOfYear, for: date)?.start
            ?? Calendar.current.startOfDay(for: date)
    }

    /// One row per assignment the answer used.
    /// An open question skips done and cancelled tasks. A finished question keeps only done tasks.
    /// A cancelled question keeps only cancelled tasks.
    /// No status word keeps the whole set. The reply does not drop other courses.
    private func assignmentSources(for question: String, reply: String) -> [TalkSourceItem] {
        let open = asksForOpenTasks(question)
        let finished = asksForFinishedTasks(question)
        let cancelled = asksForCancelledTasks(question)
        let openOnly = open && !finished && !cancelled
        let finishedOnly = finished && !open && !cancelled
        let cancelledOnly = cancelled && !open && !finished
        var rows: [(item: TalkSourceItem, needle: String)] = []
        let stamp = Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale)
        for course in catalogueCourses(in: question) {
            let tasks = course.assignments.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
            for assignment in tasks {
                if openOnly && (assignment.done || assignment.cancelled) { continue }
                if finishedOnly && (!assignment.done || assignment.cancelled) { continue }
                if cancelledOnly && !assignment.cancelled { continue }
                let anchor = assignment.sourceLecture?.startedAt ?? .now
                let week = weekStart(of: anchor)
                let task = assignment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let when = week.formatted(stamp)
                let title = task.isEmpty ? "\(course.name) · \(when)" : "\(course.name) · \(when) · \(task.prefix(42))"
                let item = TalkSourceItem(
                    title: title,
                    target: .assignment(
                        courseID: course.persistentModelID,
                        assignmentID: assignment.persistentModelID,
                        weekStart: week
                    )
                )
                rows.append((item, task))
            }
        }
        if rows.isEmpty {
            let quoted = quotedAssignmentSources(in: question, reply: reply)
            if !quoted.isEmpty {
                Self.log.info("Talk assignment sources reply-fallback count=\(quoted.count)")
                return quoted
            }
        }
        return rows.map(\.item)
    }

    /// The status filter found nothing, but the reply quotes a stored task. Keep that row.
    private func quotedAssignmentSources(in question: String, reply: String) -> [TalkSourceItem] {
        let folded = Self.asciiFold(reply)
        var items: [TalkSourceItem] = []
        let stamp = Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale)
        for course in catalogueCourses(in: question) {
            for assignment in course.assignments {
                let task = assignment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let needle = Self.asciiFold(task)
                let probe = needle.split { !$0.isLetter }.prefix(4).joined(separator: " ")
                guard probe.count >= 8, folded.contains(probe) else { continue }
                let anchor = assignment.sourceLecture?.startedAt ?? .now
                let week = weekStart(of: anchor)
                let when = week.formatted(stamp)
                let title = task.isEmpty ? "\(course.name) · \(when)" : "\(course.name) · \(when) · \(task.prefix(42))"
                items.append(
                    TalkSourceItem(
                        title: title,
                        target: .assignment(
                            courseID: course.persistentModelID,
                            assignmentID: assignment.persistentModelID,
                            weekStart: week
                        )
                    )
                )
            }
        }
        return items
    }

    /// Whole-set wording: done, open, and cancelled together.
    /// “Tüm bekleyen” is not this; the status root still wins.
    /// “Var mı” does not count as open when one of these roots is present.
    private func asksForEveryTasks(_ text: String) -> Bool {
        let tokens = Self.asciiFold(text).split { !$0.isLetter }.map(String.init)
        if tokens.contains("so") && tokens.contains("far") { return true }
        if tokens.contains("thus") && tokens.contains("far") { return true }
        if tokens.contains("in") && tokens.contains("total") { return true }
        if tokens.contains("to") && tokens.contains("date") { return true }
        if tokens.contains("until") && tokens.contains(where: { ["now", "today"].contains($0) }) { return true }
        if tokens.contains("as") && tokens.contains("of") && tokens.contains(where: { ["now", "today"].contains($0) }) {
            return true
        }
        let upToNow = tokens.contains("up") && tokens.contains("to")
            && tokens.contains { ["now", "today", "date"].contains($0) }
        if upToNow { return true }
        let fromStart = (tokens.contains("from") || tokens.contains("since"))
            && tokens.contains { ["start", "beginning"].contains($0) }
        if fromStart { return true }
        if tokens.contains("all") && tokens.contains("along") { return true }
        if tokens.contains("handed") && tokens.contains("out") { return true }
        if tokens.contains(where: { ["come", "came"].contains($0) }) && tokens.contains("up") { return true }
        let span = tokens.contains("kadar") || tokens.contains("dek") || tokens.contains("beri")
        let fromHere = tokens.contains { token in
            token == "gune" || token == "ana"
                || token.hasPrefix("bugun") || token.hasPrefix("simdi") || token.hasPrefix("bastan")
        }
        if span && fromHere { return true }
        return tokens.contains { token in
            token == "tum" || token.hasPrefix("tumu") || token.hasPrefix("tumun")
                || token == "butun" || token.hasPrefix("butunu")
                || token == "hepsi" || token.hasPrefix("hepsin")
                || token == "toplam" || token.hasPrefix("genel")
                || token == "cikan" || token.hasPrefix("cikti") || token.hasPrefix("cikmis")
                || token.hasPrefix("cikard") || token == "vardi"
                || (token.hasPrefix("veril") && !token.contains("me") && !token.contains("ma"))
                || token.hasPrefix("verdig") || token == "verdi"
                || token == "all" || token == "every" || token == "entire" || token == "whole"
                || token == "everything" || token == "altogether" || token == "overall"
                || token == "total" || token == "general"
                || token == "given" || token == "assigned"
        }
    }

    /// Cancelled-task wording, by root, in Turkish and English.
    /// “İptal” already covers “iptal edilen” and “hocanın iptal ettiği”.
    /// “İptal edilmeyen” and “kaldırılmayan” stay off this list.
    private func asksForCancelledTasks(_ text: String) -> Bool {
        let tokens = Self.asciiFold(text).split { !$0.isLetter }.map(String.init)
        let negated = tokens.contains("not") || tokens.contains("degil")
            || tokens.contains { $0.hasPrefix("etmey") || $0.hasPrefix("edilmey") || $0.hasPrefix("olmayan") }
        if tokens.contains("called") && tokens.contains("off") && !negated { return true }
        return tokens.contains { token in
            if negated && (token.hasPrefix("iptal") || token == "cancelled" || token == "canceled"
                || token == "dropped" || token == "removed" || token.hasPrefix("remove"))
            {
                return false
            }
            // Passive and teacher forms: iptal edilen, kaldırılan, kalktı, silindi, geçersiz.
            // “kaldırılmayan” / “silinmedi” contain the negative syllable and do not match.
            let lifted = token.hasPrefix("kaldiril") && !token.contains("ma")
            let erased = token.hasPrefix("silin") && !token.contains("me") && !token.contains("ma")
            return token.hasPrefix("iptal") || token.hasPrefix("vazgec")
                || lifted || token.hasPrefix("kaldird")
                || token == "kalkan" || token.hasPrefix("kalkt") || token.hasPrefix("kalkmis")
                || erased || token.hasPrefix("sild")
                || token.hasPrefix("gecersiz") || token.hasPrefix("yapilmayacak")
                || token == "cancelled" || token == "canceled" || token == "dropped"
                || token == "withdrawn" || token.hasPrefix("scrapped")
                || token == "removed" || token.hasPrefix("waived")
        }
    }

    /// Finished-task wording, by root, in Turkish and English.
    /// “Tamamlamadığım” does not match “tamamlad”; “not done” stays on the open list.
    private func asksForFinishedTasks(_ text: String) -> Bool {
        let tokens = Self.asciiFold(text).split { !$0.isLetter }.map(String.init)
        if tokens.contains("not") && tokens.contains(where: { ["done", "finished", "complete", "completed"].contains($0) }) {
            return false
        }
        if tokens.contains("teslim") && tokens.contains(where: { $0.hasPrefix("ett") }) { return true }
        return tokens.contains { token in
            token.hasPrefix("tamamlad")
                || token.hasPrefix("bitird") || token == "biten"
                || token.hasPrefix("hallett")
                || token.hasPrefix("yaptig") || token == "yaptim" || token.hasPrefix("yaptik")
                || token.hasPrefix("cozd")
                || token == "finished" || token == "completed" || token == "done" || token == "submitted"
                || token.hasPrefix("handed")
        }
    }

    /// Unfinished-task wording, by root, in Turkish and English.
    /// “Ödev” / “assignment” still has to be in the question; these roots only mark it as not done.
    private func asksForOpenTasks(_ text: String) -> Bool {
        let tokens = Self.asciiFold(text).split { !$0.isLetter }.map(String.init)
        // “Tüm ödevler var mı” is the whole set. “Ödev var mı” stays open.
        if !asksForEveryTasks(text) && tokens.contains("var") && tokens.contains("mi") { return true }
        if !asksForEveryTasks(text) && tokens.contains("any") { return true }
        if tokens.contains("not") && tokens.contains(where: { ["done", "finished", "complete"].contains($0) }) {
            return true
        }
        if tokens.contains("teslim") && tokens.contains(where: { $0.hasPrefix("etmed") }) { return true }
        return tokens.contains { token in
            // Turkish: waiting, not done, not finished, forgotten, overdue, postponed, not started.
            token.hasPrefix("bekle")
                || token == "acik" || token == "hala" || token == "henuz"
                || token.hasPrefix("yapmad") || token.hasPrefix("yapmam")
                || token.hasPrefix("yapilmam") || token.hasPrefix("yapilacak")
                || token.hasPrefix("tamamlamad") || token.hasPrefix("tamamlanmam") || token.hasPrefix("tamamlanmayan")
                || token.hasPrefix("bitirmed") || token.hasPrefix("bitmem") || token.hasPrefix("bitmey")
                || token.hasPrefix("unut") || token.hasPrefix("ihmal") || token.hasPrefix("atlad") || token.hasPrefix("kacir")
                || token == "eksik" || token == "kalan" || token.hasPrefix("kaldi") || token.hasPrefix("kalmis")
                || token.hasPrefix("gecik") || token.hasPrefix("ertel") || token.hasPrefix("aksat") || token.hasPrefix("aksad")
                || token.hasPrefix("baslamad") || token.hasPrefix("ellemed") || token == "yarim"
                || token.hasPrefix("birik") || token == "duran" || token.hasPrefix("duruyor")
                // English: didn't, haven't, forgot, overdue, missed, outstanding.
                || token == "pending" || token == "open" || token == "unfinished" || token == "incomplete"
                || token == "undone" || token == "overdue" || token == "outstanding" || token == "remaining"
                || token.hasPrefix("forgot") || token.hasPrefix("didn") || token.hasPrefix("haven")
                || token == "missed" || token == "behind" || token == "owed" || token.hasPrefix("owing")
                || token == "leftover" || token == "backlog"
        }
    }

    /// One row per exam. The week is the exam date’s week. An undated exam stays on the current week.
    private func examSources(for question: String) -> [TalkSourceItem] {
        var items: [TalkSourceItem] = []
        let stamp = Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale)
        for course in catalogueCourses(in: question) {
            for sitting in course.sittings {
                let title = sitting.title.isEmpty ? sitting.kind : sitting.title
                let when = sitting.date?.formatted(stamp) ?? ""
                let label = when.isEmpty ? "\(course.name) · \(title)" : "\(course.name) · \(when) · \(title)"
                items.append(
                    TalkSourceItem(
                        title: label,
                        target: .exam(
                            courseID: course.persistentModelID,
                            weekStart: sitting.date.map { weekStart(of: $0) }
                        )
                    )
                )
            }
        }
        return items
    }

    /// One row per inventory item. The course page opens with that section expanded.
    private func inventorySources(for question: String) -> [TalkSourceItem] {
        var items: [TalkSourceItem] = []
        for course in catalogueCourses(in: question) {
            for item in course.inventory {
                items.append(
                    TalkSourceItem(
                        title: "\(course.name) · \(item.title)",
                        target: .inventory(courseID: course.persistentModelID, itemID: item.persistentModelID)
                    )
                )
            }
        }
        return items
    }

    private static func noteSourceTitle(_ block: StudyBlock) -> String {
        let text = block.text
        guard text.hasPrefix("["), let close = text.firstIndex(of: "]") else {
            return String(text.prefix(48))
        }
        let parts = String(text[text.index(after: text.startIndex)..<close])
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var course = ""
        var lecture = ""
        let clock = parts.last ?? ""
        for part in parts {
            if part.hasPrefix("course ") {
                course = String(part.dropFirst(7))
            } else if part.hasPrefix("lecture ") {
                lecture = String(part.dropFirst(8))
            }
        }
        if !course.isEmpty, !lecture.isEmpty {
            return "\(course) · \(lecture) · \(clock)"
        }
        if !course.isEmpty {
            return "\(course) · \(clock)"
        }
        return String(parts.joined(separator: " · ").prefix(64))
    }

    /// How many classes / when is my slot — answered from the catalogue, not a lecture Raw block.
    private func isScheduleQuestion(_ text: String) -> Bool {
        let folded = Self.asciiFold(text)
        if folded.contains("timetable") || folded.contains("ders program") || folded.contains("programim") {
            return true
        }
        if folded.contains("kac ders") || folded.contains("dersim var") || folded.contains("derslerim") {
            return true
        }
        // “Dün hangi derslerim vardı”, “dersim yok muydu dün” — the timetable day, not a recording.
        if askedWeekday(in: text) != nil
            && (folded.contains("ders") || folded.contains("class") || folded.contains("lecture"))
            && !folded.contains("kayit") && !folded.contains("kayd") && !folded.contains("recording")
            && !folded.contains("odev") && !folded.contains("assignment") && !folded.contains("homework")
        {
            return true
        }
        // “Bu hafta kaç tane dersim kaldı” has words between kaç and ders.
        let aboutClass =
            folded.contains("ders") || folded.contains("class") || folded.contains("lecture")
        let aboutTask =
            folded.contains("odev") || folded.contains("assignment") || folded.contains("homework")
        if aboutClass && !aboutTask && (folded.contains("kac") || folded.contains("how many")) {
            return true
        }
        if folded.contains("how many class") || folded.contains("how many course")
            || folded.contains("how many lecture") || folded.contains("how many slot")
        {
            return true
        }
        if folded.contains("when is my") && (folded.contains("class") || folded.contains("lecture") || folded.contains("course")) {
            return true
        }
        if folded.contains("ne zaman") && (folded.contains("ders") || folded.contains("slot")) {
            return true
        }
        // “Felsefe dersim saat kaçta” is the slot, not the phone clock.
        if folded.contains("saat kacta")
            && (folded.contains("ders") || folded.contains("class") || folded.contains("lecture")
                || folded.contains("course") || namesOpenCourse(folded))
        {
            return true
        }
        if (folded.contains("what time") || folded.contains("when is") || folded.contains("when does"))
            && (folded.contains("class") || folded.contains("lecture") || folded.contains("course")
                || folded.contains("ders") || namesOpenCourse(folded))
        {
            return true
        }
        // “Felsefe dersinin toplam kaç saat / dakika” is the weekly slots, not a Raw minute.
        let asksDuration =
            folded.contains("kac saat") || folded.contains("kac dakika")
            || folded.contains("how many hour") || folded.contains("how many minute")
            || folded.contains("how long")
        let aboutAClass =
            folded.contains("ders") || folded.contains("class") || folded.contains("course")
            || folded.contains("lecture") || namesOpenCourse(folded)
        if asksDuration && aboutAClass && !asksForLectureNotes(folded) {
            return true
        }
        return false
    }

    /// True when the question names a course stored on an open term.
    private func namesOpenCourse(_ folded: String) -> Bool {
        let pool = terms.filter(\.isOpen)
        let termsToScan = pool.isEmpty ? terms : pool
        for term in termsToScan {
            for course in term.courses {
                let name = Self.asciiFold(course.name)
                if name.count >= 3, folded.contains(name) { return true }
            }
        }
        return false
    }

    /// How many / list / due / “do I have any” assignments — catalogue; Source opens the course.
    /// Lecture-content asks (“what was in the notes”) stay on BM25 Raw notes.
    private func isAssignmentCatalogQuestion(_ text: String) -> Bool {
        let folded = Self.asciiFold(text)
        let hasTask =
            folded.contains("odev") || folded.contains("assignment") || folded.contains("homework")
        guard hasTask else { return false }
        // “ödevlerde pardon notlarda…” — ASR keeps the slip; notes win over assignment Source.
        if asksForLectureNotes(folded) { return false }

        if folded.contains("kac") || folded.contains("how many") || folded.contains("toplam") {
            return true
        }
        if folded.contains("odevler") || folded.contains("assignments") || folded.contains("homeworks") {
            return true
        }
        // “ödev var mı”, “any homework”, “gereken / yetiştirmem gereken”
        if folded.contains("var mi") || folded.contains("any ")
            || folded.contains("gereken") || folded.contains("yetistir") || folded.contains("yetisme")
        {
            return true
        }
        if folded.contains("open") || folded.contains("due") || folded.contains("teslim")
            || folded.contains("bitmemis") || folded.contains("yapilacak")
        {
            return true
        }
        // “tüm ödevler”, “bugüne kadar kaç ödev”, “yapmadığım / tamamladığım ödev”
        if asksForEveryTasks(text)
            || asksForOpenTasks(text) || asksForFinishedTasks(text) || asksForCancelledTasks(text)
        {
            return true
        }
        // Week / today scoped inventory (“bu hafta … ödev …”)
        if (folded.contains("hafta") || folded.contains("week") || folded.contains("bugun")
            || folded.contains("today") || folded.contains("tomorrow") || folded.contains("yarin"))
            && hasTask
        {
            return true
        }
        if folded.contains("ne zaman") {
            return true
        }
        return false
    }

    /// Exam dates / sittings from the catalogue — Source opens the course, not BM25 notes.
    private func isExamCatalogQuestion(_ text: String) -> Bool {
        let folded = Self.asciiFold(text)
        let hasExam =
            folded.contains("sinav") || folded.contains("exam") || folded.contains("midterm")
            || folded.contains("final") || folded.contains("vize") || folded.contains("butunleme")
        guard hasExam else { return false }
        if asksForLectureNotes(folded) { return false }
        return true
    }

    /// Books / inventory rows — Source opens the course. “What did they say about the book” stays notes.
    private func isInventoryCatalogQuestion(_ text: String) -> Bool {
        let folded = Self.asciiFold(text)
        let hasInv =
            folded.contains("kitap") || folded.contains("book") || folded.contains("inventory")
            || folded.contains("envanter") || folded.contains("dosya") || folded.contains("file")
            || (folded.contains("chapter") && (folded.contains("book") || folded.contains("kitap")))
        guard hasInv else { return false }
        if asksForLectureNotes(folded) { return false }
        if folded.contains("hangi") || folded.contains("what") || folded.contains("list")
            || folded.contains("var mi") || folded.contains("how many") || folded.contains("kac")
            || folded.contains("named") || folded.contains("adin")
        {
            return true
        }
        return folded.contains("kitaplar") || folded.contains("books") || folded.contains("files")
    }

    /// Student wants lecture / Raw content, not the assignment or exam table.
    private func asksForLectureNotes(_ folded: String) -> Bool {
        if folded.contains("notlar") || folded.contains("notlarda") || folded.contains("notes") {
            return true
        }
        if folded.contains("anlat") || folded.contains("soyled")
            || folded.contains("explain") || folded.contains("what did") || folded.contains("said about")
        {
            return true
        }
        // “Dedi” is its own word. “Kaydedilmiş” contains those letters and is a recording status.
        let tokens = folded.split { !$0.isLetter }.map(String.init)
        if tokens.contains(where: { $0 == "dedi" || $0.hasPrefix("dediler") || $0.hasPrefix("dedim") || $0.hasPrefix("dedin") || $0 == "dedik" }) {
            return true
        }
        // “Liberalizm hakkında … ne vardı” without a pure inventory cue.
        if folded.contains("ne vardi") || folded.contains("ne yaz") || folded.contains("ne demis") {
            return true
        }
        return false
    }

    private enum SpeakOutcome {
        case finished
        case bargedIn(String)
    }

    /// Speaks the reply on the same audio engine as the mic, so Voice Processing can cancel echo.
    private func speak(_ text: String) async -> SpeakOutcome {
        listen.disarmBargeIn()
        listen.stopListening(cancelTurn: false)
        let bargeFlag = BargeFlag()
        let cancel = SupertonicCancel()
        speakCancel = cancel

        Self.log.info("Talk speak begin characters=\(text.count)")
        let code = locale.language.languageCode?.identifier ?? locale.identifier
        let language = code.hasPrefix("tr") ? "tr" : "en"
        let speaker = SupertonicVoice.clamped(UserDefaults.standard.integer(forKey: AppPreferences.supertonicVoiceKey))
        let clip: SupertonicClip
        do {
            clip = try await SupertonicSpeech.clip(text: text, language: language, speaker: speaker, cancel: cancel)
        } catch {
            Self.log.error("Talk speak clip failed \(error.localizedDescription, privacy: .public)")
            return .finished
        }
        guard running, !Task.isCancelled, !cancel.stopped, !clip.samples.isEmpty else { return .finished }

        do {
            try await listen.startBargeMonitor(locale: locale, echoOf: text)
        } catch {
            Self.log.error("Talk barge monitor failed \(error.localizedDescription, privacy: .public)")
            return .finished
        }
        listen.armBargeIn(after: .milliseconds(280)) { [weak self] in
            guard let self else { return }
            bargeFlag.value = true
            Self.log.info("Talk barge-in stop speech → listen")
            self.listen.stopPlayback()
        }
        // Clear any leftover You line so the Bellnote card stays on the full reply while TTS plays.
        partialTranscript = ""
        listen.play(clip)

        while !Task.isCancelled, listen.isPlaybackActive {
            let live = listen.partialText
            // Ignore TTS echo on the card; only keep a real barge-in line.
            if !live.isEmpty, !listen.looksLikeEcho(live) {
                partialTranscript = live
            }
            try? await Task.sleep(for: .milliseconds(80))
        }
        var wasBarged = bargeFlag.value
        let carried = listen.partialText
        // Playback can finish before the energy trip; keep a real student line instead of dropping it.
        if !wasBarged, !carried.isEmpty, !listen.looksLikeEcho(carried) {
            wasBarged = true
            listen.stopPlayback()
            Self.log.info("Talk barge from leftover transcript characters=\(carried.count)")
        }
        Self.log.info("Talk speak end barged=\(wasBarged) carried=\(carried.count)")

        guard wasBarged, running, !Task.isCancelled else {
            listen.disarmBargeIn()
            listen.stopListening(cancelTurn: false)
            return .finished
        }

        // Keep the barge mic/ASR alive so the interrupting question is not discarded mid-sentence.
        phase = .listening
        statusLine = String(localized: "Listening…")
        partialTranscript = carried
        try? await Task.sleep(for: .milliseconds(150))
        guard running, !Task.isCancelled else {
            listen.stopListening(cancelTurn: false)
            return .finished
        }

        do {
            let poll = Task { @MainActor in
                while !Task.isCancelled {
                    self.partialTranscript = self.listen.partialText
                    try? await Task.sleep(for: .milliseconds(120))
                }
            }
            defer { poll.cancel() }
            let next = try await listen.finishBargeListenTurn()
            return .bargedIn(next)
        } catch is CancellationError {
            listen.stopListening(cancelTurn: false)
            return .finished
        } catch {
            Self.log.error("Talk barge listen failed \(error.localizedDescription, privacy: .public)")
            listen.stopListening(cancelTurn: false)
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
    /// “Saat kaçta” is a slot (“at what time”), so it must not match “saat kaç”.
    private func isClockQuestion(_ text: String) -> Bool {
        let folded = Self.asciiFold(text)
        let tokens = folded
            .split { !$0.isLetter }
            .map(String.init)
            .filter { !$0.isEmpty }
        if tokens.contains(where: { $0 == "kacta" || $0 == "kactan" }) { return false }
        if tokens.contains(where: {
            $0.hasPrefix("ders") || $0.hasPrefix("sinav") || $0.hasPrefix("odev")
                || ["class", "lecture", "course", "classes", "exam", "homework", "assignment", "slot"].contains($0)
        }) {
            return false
        }
        if folded.contains("what time") || folded.contains("whats the time") || folded.contains("what's the time") {
            return !tokens.contains("my")
        }
        guard tokens.count <= 6 else { return false }
        let hasSaat = tokens.contains("saat") || tokens.contains("time") || tokens.contains("clock")
        let hasAsk = tokens.contains(where: {
            ["kac", "ne", "nedir", "simdi", "what", "whats", "now", "su"].contains($0)
        })
        return hasSaat && hasAsk
    }

    /// Social / control turns (Alexa-style help/cancel/stop + small talk). No model, no Source.
    private enum SocialKind: String {
        case greeting
        case howAreYou
        case thanks
        case farewell
        case help
        case repeatAsk
        case cancel
        case apology
        case praise
        case hearCheck
    }

    private func socialReply(for text: String) -> TalkReply? {
        guard let kind = socialKind(for: text) else { return nil }
        Self.log.info("Talk social short-circuit kind=\(kind.rawValue, privacy: .public) text=\(text, privacy: .public)")
        let reply: String
        switch kind {
        case .greeting:
            reply = String(localized: "Hi. Ask about your lectures or what's stored in the app.")
        case .howAreYou:
            reply = String(localized: "I'm well. Ask about your lectures when you want.")
        case .thanks:
            reply = String(localized: "You're welcome.")
        case .farewell:
            reply = String(localized: "Take care.")
        case .help:
            reply = String(localized: "I answer from your lectures, timetable, and what's stored in the app. Ask a question.")
        case .repeatAsk:
            reply = String(localized: "Say that again, or ask another question.")
        case .cancel:
            reply = String(localized: "Okay.")
        case .apology:
            reply = String(localized: "No problem.")
        case .praise:
            reply = String(localized: "Glad it helped.")
        case .hearCheck:
            reply = String(localized: "Yes, I'm listening.")
        }
        return TalkReply(text: reply)
    }

    private func socialKind(for text: String) -> SocialKind? {
        guard text.count <= 80 else { return nil }
        // Drop apostrophes so ASR “I'm” / “didn't” stay one token after fold.
        let folded = Self.asciiFold(text).replacingOccurrences(of: "'", with: "")
        let tokens = folded
            .split { !$0.isLetter }
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty, tokens.count <= 10 else { return nil }

        if matchesHelp(tokens) { return .help }
        if matchesHearCheck(tokens) { return .hearCheck }
        if matchesFarewell(tokens) { return .farewell }
        if matchesHowAreYou(tokens) { return .howAreYou }
        if matchesGreeting(tokens) { return .greeting }
        if matchesPraise(tokens) { return .praise }
        return nil
    }

    private func matchesGreeting(_ tokens: [String]) -> Bool {
        let hello = [
            "selam", "merhaba", "hey", "hi", "hello", "slm", "naber", "gunaydin",
            "selamunaleykum", "selamun",
        ]
        // ASR: “good morning / good afternoon / good evening” as separate tokens.
        let goodDayEN =
            tokens.contains("good")
            && tokens.contains(where: { ["morning", "afternoon", "evening"].contains($0) })
        guard
            tokens.contains(where: { hello.contains($0) || $0.hasPrefix("selam") }) || goodDayEN
        else { return false }
        let filler: Set<String> = [
            "selam", "merhaba", "hey", "hi", "hello", "slm", "naber", "gunaydin",
            "selamunaleykum", "selamun", "aleykum", "nasilsin", "nasilsiniz", "nasil",
            "gidiyor", "iyi", "aksamlar", "geceler", "haber", "ne", "var", "misin",
            "misiniz", "there", "morning", "evening", "afternoon", "everyone", "arkadas",
            "bellnote", "asistan", "good",
        ]
        return tokens.allSatisfy {
            filler.contains($0) || $0.hasPrefix("nasil") || $0.hasPrefix("selam")
        }
    }

    private func matchesHowAreYou(_ tokens: [String]) -> Bool {
        let ask =
            tokens.contains(where: { $0.hasPrefix("nasil") })
            || (tokens.contains("how") && tokens.contains(where: { ["are", "is", "you", "ya", "u"].contains($0) }))
            || tokens.contains(where: { ["whatsup", "wazzup", "sup"].contains($0) })
            || (tokens.contains("what") && tokens.contains("up"))
            || (tokens.contains("ne") && tokens.contains("haber"))
            // OpenSubtitles top: “İyi misin?” — not a greeting root.
            || (tokens.contains("iyi")
                && tokens.contains(where: { ["misin", "misiniz", "mi"].contains($0) }))
        guard ask else { return false }
        let filler: Set<String> = [
            "nasil", "nasilsin", "nasilsiniz", "gidiyor", "misin", "misiniz", "mi", "iyi",
            "how", "are", "is", "you", "ya", "u", "doing", "feeling", "today",
            "what", "up", "whatsup", "wazzup", "sup", "everything", "ne", "haber", "sen",
            // “Selam ne haber nasılsın” — greeting words must not block how-are-you.
            "selam", "merhaba", "hey", "hi", "hello", "slm", "naber",
        ]
        return tokens.allSatisfy { filler.contains($0) || $0.hasPrefix("nasil") }
    }

    private func matchesThanks(_ tokens: [String]) -> Bool {
        let thanksRoots = ["tesekkur", "sagol", "thanks", "thank", "thx"]
        // ASR often splits “sağ ol / sağ olasın / sağ olsun” into sag + ol…
        let sagOl =
            tokens.contains("sag")
            && tokens.contains(where: {
                ["ol", "olsun", "olasin", "olasiniz", "olun", "olunuz"].contains($0)
                    || $0.hasPrefix("ola") || $0.hasPrefix("olu")
            })
        let hasThanks =
            tokens.contains(where: { token in thanksRoots.contains(where: { token.hasPrefix($0) }) })
            || sagOl
        guard hasThanks else { return false }
        let filler: Set<String> = [
            "tamam", "ok", "okay", "pekala", "peki", "super", "harika", "sagol", "sag",
            "ol", "olsun", "olasin", "olasiniz", "olun", "olunuz",
            "eyvallah", "tesekkur", "tesekkurler", "tesekkurlerim", "ederim",
            "thanks", "thank", "thx", "you", "very", "much", "a", "lot", "cok",
            "yardim", "icin", "for", "that", "bu", "sana", "da", "de",
            // “anladım tamam sağ ol” — acknowledgment in front of thanks.
            "anladim", "anladik", "anlasildi", "anlasildim",
            "understood", "got", "it", "alright", "gotcha",
        ]
        return tokens.allSatisfy { token in
            filler.contains(token)
                || thanksRoots.contains(where: { token.hasPrefix($0) })
                || token.hasPrefix("ola") || token.hasPrefix("olu")
        }
    }

    private func matchesFarewell(_ tokens: [String]) -> Bool {
        let byeRoots = [
            "hosca", "gule", "goodbye", "bye", "bb", "eyvallah", "gorusuruz", "gorusmek", "cikis",
            "allahismarladik", "allahaismarladik",
        ]
        let hasBye = tokens.contains { token in
            byeRoots.contains(where: { token.hasPrefix($0) }) || token == "bay" || token == "exit"
        }
        // ASR splits: hoşça kal, güle güle (already root), take care, see you, görüşmek üzere.
        let hasHoscaKal =
            tokens.contains(where: { $0.hasPrefix("hosca") })
            && tokens.contains(where: { $0.hasPrefix("kal") })
        let hasTakeCare = tokens.contains("take") && tokens.contains("care")
        let hasSeeYou = tokens.contains("see") && tokens.contains("you")
        let hasCare =
            tokens.contains("kendine")
            && tokens.contains(where: { ["bak", "dikkat", "iyi"].contains($0) })
        let hasGoodDay =
            tokens.contains("iyi")
            && tokens.contains(where: {
                ["aksamlar", "geceler", "gunler", "sabahlar", "haftalar", "tatiller"].contains($0)
                    || $0.hasPrefix("aksam") || $0.hasPrefix("gece") || $0.hasPrefix("gun")
                    || $0.hasPrefix("tatil")
            })
        let hasGoodNight =
            tokens.contains("good")
            && tokens.contains(where: { ["night", "evening", "bye"].contains($0) })
        guard
            hasBye || hasHoscaKal || hasTakeCare || hasSeeYou || hasCare || hasGoodDay || hasGoodNight
        else { return false }
        let filler: Set<String> = [
            "tamam", "ok", "okay", "pekala", "peki", "cok", "sana", "da", "de", "sag",
            "iyi", "bak", "dikkat", "et", "ol", "kal", "kalin", "kendine",
            "anladim", "anladik", "tesekkur", "tesekkurler", "ederim",
            "thanks", "thank", "thx", "you",
            "hosca", "hoscakal", "hoscakalin", "gule", "gulegule",
            "aksamlar", "geceler", "gunler", "sabahlar", "haftalar", "tatiller",
            "eyvallah", "bye", "goodbye", "bb", "bay", "see", "you", "later", "soon",
            "take", "care", "night", "evening", "morning", "uzere", "gorusuruz",
            "gorusmek", "good", "exit", "cikis", "hadi", "allahismarladik", "allahaismarladik",
            "allah", "ismarladik",
        ]
        return tokens.allSatisfy { token in
            filler.contains(token)
                || byeRoots.contains(where: { token.hasPrefix($0) })
                || token.hasPrefix("aksam") || token.hasPrefix("gece") || token.hasPrefix("gun")
                || token.hasPrefix("sabah") || token.hasPrefix("tatil") || token.hasPrefix("gorus")
                || token.hasPrefix("hosca") || token.hasPrefix("kal") || token.hasPrefix("ismar")
        }
    }

    private func matchesHelp(_ tokens: [String]) -> Bool {
        let helpWord = tokens.contains { $0 == "help" || $0.hasPrefix("yardim") }
        let who =
            tokens.contains("kimsin") || tokens.contains("kimsiniz")
            || (tokens.contains("who") && tokens.contains("you"))
            || (tokens.contains("what") && tokens.contains("you")
                && tokens.contains(where: { ["are", "name", "called"].contains($0) }))
        let neYap =
            tokens.contains("ne")
            && tokens.contains(where: { $0.hasPrefix("yapabilir") })
        let neIse =
            tokens.contains("ne")
            && tokens.contains("ise")
            && tokens.contains(where: { $0.hasPrefix("yariyor") || $0.hasPrefix("yara") })
        let whatCan =
            tokens.contains("what")
            && tokens.contains("can")
            && tokens.contains(where: { ["you", "i", "do"].contains($0) })
        let howHelp = tokens.contains("how") && tokens.contains("help")
        guard helpWord || who || neYap || neIse || whatCan || howHelp else { return false }
        let filler: Set<String> = [
            "help", "me", "please", "yardim", "yardimci", "et", "eder", "misin", "misiniz",
            "ne", "yapabilirsin", "yapabilirim", "yapabilir", "kimsin", "kimsiniz",
            "who", "what", "are", "you", "your", "name", "called", "can", "do", "how",
            "with", "bana", "icin", "hakkinda", "about", "capable", "ask", "sorabilir",
            "neler", "hangi", "i", "asistan", "bellnote", "ise", "yariyorsun", "yariyor",
        ]
        return tokens.allSatisfy { token in
            filler.contains(token)
                || token.hasPrefix("yardim")
                || token.hasPrefix("yapabilir")
                || token.hasPrefix("sorabilir")
                || token.hasPrefix("yariyor")
        }
    }

    private func matchesRepeat(_ tokens: [String]) -> Bool {
        let hit =
            tokens.contains(where: {
                ["tekrar", "again", "repeat", "anlamadim", "duyamadim", "duyamadik"].contains($0)
                    || $0.hasPrefix("tekrar") || $0.hasPrefix("anlamad") || $0.hasPrefix("duyamad")
            })
            || (tokens.contains("say") && tokens.contains("again"))
            || (tokens.contains("didnt") && tokens.contains(where: { ["catch", "hear", "get"].contains($0) }))
            || (tokens.contains("couldnt") && tokens.contains(where: { ["catch", "hear", "get"].contains($0) }))
            || (tokens.contains("bir") && tokens.contains("daha")
                && tokens.contains(where: { $0.hasPrefix("soyle") || $0.hasPrefix("tekrar") }))
            || (tokens.contains("ne") && tokens.contains("dedin"))
        guard hit else { return false }
        let filler: Set<String> = [
            "tekrar", "eder", "misin", "misiniz", "lutfen", "please", "again", "repeat",
            "say", "that", "anlamadim", "anlamadik", "duyamadim", "duyamadik", "bir", "daha",
            "soyle", "soyler", "catch", "hear", "get", "what", "you", "said", "i",
            "didnt", "couldnt", "ne", "dedin", "dediniz",
        ]
        return tokens.allSatisfy { token in
            filler.contains(token)
                || token.hasPrefix("tekrar") || token.hasPrefix("anlamad") || token.hasPrefix("duyamad")
                || token.hasPrefix("soyle") || token.hasPrefix("dedin")
        }
    }

    private func matchesCancel(_ tokens: [String]) -> Bool {
        // Alexa/Google-style cancel / stop / never mind / I'm done / wait.
        let hit =
            tokens.contains(where: {
                [
                    "iptal", "vazgec", "vazgectim", "bosver", "cancel", "stop", "enough",
                    "yeter", "bitti", "bitirdim", "finished", "bekle",
                ].contains($0)
                    || $0.hasPrefix("vazgec") || $0.hasPrefix("iptal") || $0.hasPrefix("bitir")
            })
            || (tokens.contains("never") && tokens.contains("mind"))
            || (tokens.contains("forget") && tokens.contains("it"))
            || (tokens.contains("that") && tokens.contains("all"))
            || (tokens.contains("basta") && tokens.contains("birak"))
            // ASR: “boş ver” as bos + ver (OpenSubtitles “Boşver” / spoken split).
            || (tokens.contains("bos") && tokens.contains("ver"))
            || (tokens.contains("im") && tokens.contains(where: { ["done", "finished"].contains($0) }))
            || (tokens.contains("shut") && tokens.contains("up"))
            || (tokens.contains("hold") && tokens.contains("on"))
            || (tokens.contains("wait") && tokens.count <= 3)
            || (tokens.contains("bir") && tokens.contains(where: { ["saniye", "dakika"].contains($0) }))
        guard hit else { return false }
        let filler: Set<String> = [
            "iptal", "vazgec", "vazgectim", "bosver", "bos", "ver", "et", "cancel", "stop", "never",
            "mind", "forget", "it", "that", "all", "enough", "tamam", "ok", "okay", "basta", "birak",
            "simdi", "for", "now", "lutfen", "please", "yapma", "yeter", "bitti", "bitirdim",
            "finished", "done", "im", "i", "am", "shut", "up", "hold", "on", "wait", "bir",
            "saniye", "dakika", "bekle", "bekler", "misin", "off",
        ]
        return tokens.allSatisfy { token in
            filler.contains(token)
                || token.hasPrefix("vazgec") || token.hasPrefix("iptal") || token.hasPrefix("bitir")
                || token.hasPrefix("bekle")
        }
    }

    private func matchesApology(_ tokens: [String]) -> Bool {
        let hit =
            tokens.contains(where: {
                [
                    "ozur", "kusura", "affedersin", "affedersiniz", "sorry", "apologize", "apologise",
                    "pardon", "uzgunum", "uzgunuz",
                ].contains($0)
                    || $0.hasPrefix("ozur") || $0.hasPrefix("kusur") || $0.hasPrefix("affeder")
                    || $0.hasPrefix("uzgun")
            })
            || (tokens.contains("my") && tokens.contains("bad"))
            // “özür dilerim” / “kusura bakma” stay thanks-safe via filler below.
            || (tokens.contains("ozur") && tokens.contains(where: { $0.hasPrefix("diler") }))
            || (tokens.contains("kusura")
                && tokens.contains(where: { $0.hasPrefix("bakma") || $0.hasPrefix("bakmay") }))
        guard hit else { return false }
        let filler: Set<String> = [
            "ozur", "dilerim", "dileriz", "kusura", "bakma", "bakmayin", "affedersin", "affedersiniz",
            "sorry", "i", "am", "im", "my", "bad", "apologize", "apologise", "about", "that",
            "icin", "cok", "pardon", "uzgunum", "uzgunuz", "cok",
        ]
        return tokens.allSatisfy { token in
            filler.contains(token)
                || token.hasPrefix("ozur") || token.hasPrefix("kusur") || token.hasPrefix("affeder")
                || token.hasPrefix("diler") || token.hasPrefix("bakma") || token.hasPrefix("uzgun")
        }
    }

    private func matchesPraise(_ tokens: [String]) -> Bool {
        let hit =
            tokens.contains(where: {
                [
                    "super", "harika", "guzel", "mukemmel", "awesome", "great", "cool", "perfect",
                    "nice", "aferin", "bravo", "tebrikler",
                ].contains($0)
            })
            || (tokens.contains("that")
                && tokens.contains(where: { ["helped", "helpful", "useful"].contains($0) }))
            || (tokens.contains("cok") && tokens.contains(where: { ["iyi", "guzel", "yararli"].contains($0) }))
            || (tokens.contains("well") && tokens.contains("done"))
        guard hit, tokens.count <= 6 else { return false }
        let filler: Set<String> = [
            "super", "harika", "guzel", "mukemmel", "awesome", "great", "cool", "perfect", "nice",
            "that", "helped", "helpful", "useful", "cok", "iyi", "yararli", "was", "really", "very",
            "tamam", "ok", "okay", "this", "bu", "aferin", "bravo", "tebrikler", "well", "done",
        ]
        return tokens.allSatisfy { filler.contains($0) }
    }

    private func matchesHearCheck(_ tokens: [String]) -> Bool {
        let listeningTR = tokens.contains {
            $0.hasPrefix("duyuyor") || $0.hasPrefix("dinliyor")
        }
        let hit =
            (listeningTR
                && tokens.contains(where: {
                    ["musun", "musunuz", "mu", "beni"].contains($0) || $0.hasPrefix("mu")
                }))
            || (tokens.contains("can") && tokens.contains("hear") && tokens.contains("me"))
            || (tokens.contains("are") && tokens.contains("you")
                && tokens.contains(where: { ["there", "listening"].contains($0) }))
            || tokens.contains("alo")
        guard hit else { return false }
        let filler: Set<String> = [
            "duyuyor", "musun", "musunuz", "mu", "beni", "can", "you", "hear", "me",
            "are", "there", "listening", "alo", "hello", "mi", "dinliyor",
        ]
        return tokens.allSatisfy { token in
            filler.contains(token) || token.hasPrefix("duyuyor") || token.hasPrefix("dinliyor")
        }
    }

    /// Sexual talk, swearing, and the same kind of turn. Not a lecture question: no model and no Source.
    /// A question about what was said in class still uses the note.
    private func unethicalReply(for text: String) -> TalkReply? {
        let tokens = Self.foldedTokens(text)
        guard !tokens.isEmpty else { return nil }
        if Self.matchesSwearing(tokens) {
            Self.log.info("Talk unethical short-circuit kind=swearing")
            return TalkReply(text: String(localized: "I can't swear."))
        }
        guard Self.isUnethicalTurn(tokens) else { return nil }
        Self.log.info("Talk unethical short-circuit kind=refused")
        return TalkReply(text: String(localized: "I don't answer that."))
    }

    private static func foldedTokens(_ text: String) -> [String] {
        asciiFold(text)
            .replacingOccurrences(of: "'", with: "")
            .split { !$0.isLetter }
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// Category roots, not every insult and not words such as aptal or manyak.
    /// “Küfür” itself is not the only swear: the profanity family is refused before the model.
    private static func isUnethicalRoot(_ token: String) -> Bool {
        token.hasPrefix("kufur") || token.hasPrefix("kufret") || token.hasPrefix("hakaret")
            || token.hasPrefix("swear") || token.hasPrefix("curs") || token.hasPrefix("insult")
            || token.hasPrefix("seks") || token == "sex" || token.hasPrefix("sexual")
            || token.hasPrefix("cinsel") || token.hasPrefix("cinsell")
            || token.hasPrefix("porno") || token.hasPrefix("porn")
            || token == "nude" || token == "naked" || token.hasPrefix("ciplak")
            || token.hasPrefix("amina") || token.hasPrefix("amcik") || token.hasPrefix("amcig")
            || token.hasPrefix("orospu") || token.hasPrefix("yarrak") || token == "yarak"
            || token.hasPrefix("tasak")
            // Not the bare root: “sıkıntı” and “şikayet” fold to the same letters.
            || token.hasPrefix("siker") || token.hasPrefix("sikik") || token.hasPrefix("siktir")
            || token.hasPrefix("sikey") || token.hasPrefix("sikim") || token.hasPrefix("siktig")
            || token.hasPrefix("fuck") || token.hasPrefix("shit") || token.hasPrefix("bitch")
            || token.hasPrefix("asshole") || token.hasPrefix("cunt")
            // “piç”, not “picture” or “pick”.
            || token == "pic" || token.hasPrefix("pici") || token.hasPrefix("picl")
    }

    private static func isLectureMarker(_ token: String) -> Bool {
        token.hasPrefix("ders") || token.hasPrefix("hoca") || token.hasPrefix("kayit")
            || token.hasPrefix("lectur") || token == "class" || token == "classes"
            || token.hasPrefix("odev") || token.hasPrefix("sinav")
            || token.hasPrefix("exam") || token.hasPrefix("assign")
    }

    private static func isUnethicalTurn(_ tokens: [String]) -> Bool {
        guard tokens.contains(where: isUnethicalRoot) else { return false }
        if tokens.contains(where: isLectureMarker) { return false }
        let asksWhatWasSaid =
            (tokens.contains("ne") && tokens.contains { $0.hasPrefix("dedi") || $0.hasPrefix("soyle") })
            || (tokens.contains("what") && tokens.contains("did"))
        return !asksWhatWasSaid
    }

    /// “Can you swear?” and “Can I swear at you?” are about Bellnote, not a lecture.
    private static func matchesSwearing(_ tokens: [String]) -> Bool {
        let swear = tokens.contains { token in
            token.hasPrefix("kufur") || token.hasPrefix("kufret")
                || token.hasPrefix("swear") || token.hasPrefix("curs")
                || token.hasPrefix("insult")
        }
        guard swear else { return false }
        let aboutNotes = tokens.contains { token in
            token.hasPrefix("ders") || token.hasPrefix("kayit") || token.hasPrefix("not")
                || token.hasPrefix("hoca")
                || ["lecture", "lectures", "class", "classes", "notes", "lecturer"].contains(token)
        }
        guard !aboutNotes else { return false }
        let addressed =
            tokens.contains { ["musun", "misin", "misiniz", "you", "sana", "bana", "seni"].contains($0) }
            || tokens.contains("can")
            || tokens.contains { $0.hasPrefix("edebil") || $0 == "eder" || $0.hasPrefix("eder") }
        guard addressed else { return false }
        return tokens.count <= 8
    }

    /// Lossy ASCII fold for social matching. ASR and typed Turkish both land on the same
    /// keys (`teşekkürler` / `tesekkurler` → `tesekkurler`). Foundation
    /// `diacriticInsensitive` alone keeps `ı` and mishandles `İ` under English lowercasing
    /// (`İ` → `i` + combining dot), so Turkish letters are mapped before any lowercase.
    private static func asciiFold(_ text: String) -> String {
        let map: [Character: Character] = [
            "ı": "i", "İ": "i", "I": "i",
            "ş": "s", "Ş": "s",
            "ğ": "g", "Ğ": "g",
            "ü": "u", "Ü": "u",
            "ö": "o", "Ö": "o",
            "ç": "c", "Ç": "c",
        ]
        var out = ""
        out.reserveCapacity(text.count)
        let posix = Locale(identifier: "en_US_POSIX")
        for ch in text {
            if let mapped = map[ch] {
                out.append(mapped)
                continue
            }
            for scalar in String(ch).lowercased(with: posix).unicodeScalars {
                if scalar.properties.isDiacritic { continue }
                out.append(Character(scalar))
            }
        }
        return out
    }
}
