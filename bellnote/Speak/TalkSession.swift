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
            if missing {
                return TalkReply(text: String(localized: "The lectures do not contain that."))
            }
            let sources = sourcesForAnswer(question: question, pick: pick)
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
    private func sourcesForAnswer(question: String, pick: StudySelection.Pick) -> [TalkSourceItem] {
        if isScheduleQuestion(question) {
            return timetableSources(for: question)
        }
        if isAssignmentCatalogQuestion(question) {
            return assignmentSources(for: question)
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
        func stems(in hay: String) -> Set<String> {
            Set(
                hay.split { !$0.isLetter }
                    .map { String($0.prefix(4)) }
                    .filter { $0.count >= 4 }
            )
        }
        func hayHits(_ hay: String, key: String) -> Bool {
            if hay.contains(key) { return true }
            let stem = String(key.prefix(4))
            guard stem.count >= 4 else { return false }
            return stems(in: hay).contains(stem)
        }
        func score(_ block: StudyBlock) -> Int {
            guard !keys.isEmpty else { return 0 }
            let hay = Self.asciiFold(block.text)
            return keys.reduce(0) { partial, key in
                partial + (hayHits(hay, key: key) ? max(key.count, 1) : 0)
            }
        }
        let primary = pick.source
        let topicBest = pick.blocks.max { score($0) < score($1) }
        let chosen: StudyBlock?
        if let topicBest, score(topicBest) > 0 {
            let primaryScore = primary.map(score) ?? 0
            // Whole-library BM25 often ranks a “nedir / anlat” neighbour first; prefer topic hit.
            chosen = score(topicBest) > primaryScore ? topicBest : (primary ?? topicBest)
        } else {
            chosen = primary ?? pick.blocks.first
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
            "bana", "bizi", "beni", "sana", "size", "seni",
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

    private func timetableSources(for question: String) -> [TalkSourceItem] {
        let calendar = Calendar.current
        let symbols = calendar.shortWeekdaySymbols
        var items: [TalkSourceItem] = []
        let pool = terms.filter(\.isOpen)
        let termsToScan = pool.isEmpty ? terms : pool
        for term in termsToScan {
            for slot in term.slots.sorted(by: { ($0.weekday, $0.startMinutes) < ($1.weekday, $1.startMinutes) }) {
                guard let course = slot.course else { continue }
                let asked = Self.asciiFold(question)
                let courseName = Self.asciiFold(course.name)
                if courseName.count >= 3, !asked.contains(courseName), namesOpenCourse(asked) {
                    continue
                }
                let day = symbols.indices.contains(slot.weekday - 1) ? symbols[slot.weekday - 1] : "?"
                let clock = ReminderScheduler.clock(slot.startMinutes)
                items.append(
                    TalkSourceItem(
                        title: "\(day) \(clock) · \(course.name)",
                        target: .timetable(
                            termID: term.persistentModelID,
                            weekday: slot.weekday,
                            startMinutes: slot.startMinutes
                        )
                    )
                )
            }
        }
        return items
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

    /// The week the course page uses for a recording: the calendar week that contains that day.
    private func weekStart(of date: Date) -> Date {
        Calendar.current.dateInterval(of: .weekOfYear, for: date)?.start
            ?? Calendar.current.startOfDay(for: date)
    }

    /// One row per assignment. The week is the recording’s week, same as the course page.
    private func assignmentSources(for question: String) -> [TalkSourceItem] {
        var items: [TalkSourceItem] = []
        let stamp = Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale)
        for course in catalogueCourses(in: question) {
            let tasks = course.assignments.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
            for assignment in tasks {
                let anchor = assignment.sourceLecture?.startedAt ?? .now
                let week = weekStart(of: anchor)
                let task = assignment.text.trimmingCharacters(in: .whitespacesAndNewlines)
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
        let aboutClass =
            folded.contains("ders") || folded.contains("class") || folded.contains("course")
            || folded.contains("lecture") || namesOpenCourse(folded)
        if asksDuration && aboutClass && !asksForLectureNotes(folded) {
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
        if folded.contains("anlat") || folded.contains("soyled") || folded.contains("dedi")
            || folded.contains("explain") || folded.contains("what did") || folded.contains("said about")
        {
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
        if matchesRepeat(tokens) { return .repeatAsk }
        if matchesCancel(tokens) { return .cancel }
        if matchesApology(tokens) { return .apology }
        if matchesThanks(tokens) { return .thanks }
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
            "tamam", "ok", "okay", "pekala", "peki", "cok", "sana", "da", "de",
            "iyi", "bak", "dikkat", "et", "ol", "kal", "kalin", "kendine",
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
