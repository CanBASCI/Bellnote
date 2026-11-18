import Foundation
import Observation
import OSLog
import SwiftData

enum QuizPhase: Equatable {
    case pickCourse
    case setup
    case preparing
    case taking
    case results
    case review
    case needsModel
    case failed(String)
}

/// Session-only multiple-choice quiz for one course. Clears when the process dies.
@MainActor
@Observable
final class QuizSession {
    private static let log = Logger(subsystem: "app.bellnote", category: "quiz")
    /// One window of a file or note sent to the model. Smaller windows diversify questions.
    private static let chunkSize = 900
    /// Cap per PDF/image/notes block group after spreading across the whole text.
    private static let maxWindowsPerSource = 48
    /// Cap for the whole quiz pool (notes + files).
    private static let maxWindowsTotal = 96
    /// Soft ceiling — named labels, not paragraph distractors.
    private static let maxChoiceCharacters = 90
    private static let maxStemCharacters = 500
    private static let maxChoiceWords = 8
    /// The answer the model copies from the material. A name or a term, not a clause.
    private static let maxAnswerWords = 6
    /// Salvage prefers mid-length noun phrases, not the shortest token in the window.
    private static let idealChoiceCharacters = 28
    /// Discourse / glue words that look like “terms” after a period split (EN + TR).
    private static let weakChoiceFolds: Set<String> = [
        "örneğin", "ornegin", "yani", "çünkü", "cunku", "ancak", "fakat", "ayrıca", "ayrica",
        "veya", "yahut", "ile", "için", "icin", "gibi", "kadar", "daha", "çok", "cok",
        "bir", "bu", "şu", "su", "o", "ve", "da", "de", "ki", "mi", "mı", "mu", "mü",
        "the", "and", "or", "for", "with", "from", "that", "this", "also", "than", "then",
        "example", "examples", "because", "however", "therefore", "thus", "so", "but",
    ]

    private(set) var phase: QuizPhase = .pickCourse
    private(set) var course: Course?
    var difficulty: QuizDifficulty = .medium
    var questionCount: QuizQuestionCount = .ten
    /// Off by default. When on, ready lecture notes of the course join the pool.
    var includeLectureNotes = false
    /// Ready recordings the student picked. None are picked until the student taps them.
    var selectedLectureIDs: Set<PersistentIdentifier> = []
    /// Selected course file persistent ids.
    var selectedFileIDs: Set<PersistentIdentifier> = []

    private(set) var questions: [QuizQuestion] = []
    private(set) var answers: [QuizAnswerRecord] = []
    private(set) var index = 0
    /// Index into `wrongAnswers` while reviewing.
    private(set) var reviewIndex = 0
    private(set) var picked: QuizChoice?
    private(set) var questionStartedAt: Date?
    private(set) var statusLine = ""
    /// One or two sentences under the stage title, same idea as a processing stage info line.
    private(set) var statusDetail = ""
    /// Second line inside the ring while writing questions (e.g. “1 / 10”).
    private(set) var statusCaption = ""
    /// 0…1 for the same progress ring as lecture processing.
    private(set) var prepareFraction: Double = 0

    /// What `ProcessingCircle` shows while questions are prepared.
    var preparingStep: PipelineActivity.Step {
        PipelineActivity.Step(
            fraction: prepareFraction,
            title: statusLine.isEmpty ? String(localized: "Checking the model") : statusLine,
            info: statusDetail,
            centerCaption: statusCaption
        )
    }

    private var materialIndex: [String: Material] = [:]

    /// True while the app is in the background. iOS gives no GPU time there, so no model call is started.
    private var isInBackground = false
    /// When the app last went to the background. A call that failed after this moment failed because of it.
    private var lastBackgroundedAt: Date?

    /// Fed by the quiz page from the scene phase.
    func appPhaseChanged(isBackground: Bool) {
        guard isBackground != isInBackground else { return }
        isInBackground = isBackground
        if isBackground {
            lastBackgroundedAt = Date()
        }
        Self.log.info("Quiz app background=\(isBackground) phase=\(String(describing: self.phase), privacy: .public)")
    }

    /// Holds the write loop while the app is in the background and continues when it comes back.
    private func waitForForeground() async {
        guard isInBackground, phase == .preparing else { return }
        let started = Date()
        Self.log.info("Quiz pause: app is in the background")
        while isInBackground, phase == .preparing {
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
        }
        Self.log.info("Quiz resume after background ms=\(Int(Date().timeIntervalSince(started) * 1000))")
    }

    private struct Material {
        var id: String
        var kind: QuizSourceKind
        var title: String
        var text: String
        var blockToken: UUID?
        var second: Int?
        var lectureID: PersistentIdentifier?
        var fileID: PersistentIdentifier?
        var courseID: PersistentIdentifier?
        var stickyToken: UUID?
        /// 0-based PDF page for the start of this window when the source is a file.
        var pageIndex: Int?
    }

    private struct PagedChunk {
        var text: String
        var pageIndex: Int?
    }

    var current: QuizQuestion? {
        guard questions.indices.contains(index) else { return nil }
        return questions[index]
    }

    var wrongAnswers: [QuizAnswerRecord] {
        answers.filter { !$0.isCorrect }
    }

    var correctCount: Int { answers.filter(\.isCorrect).count }
    var wrongCount: Int { wrongAnswers.count }

    var totalSeconds: TimeInterval {
        answers.reduce(0) { $0 + $1.seconds }
    }

    var averageSeconds: TimeInterval {
        guard !answers.isEmpty else { return 0 }
        return totalSeconds / Double(answers.count)
    }

    func resetToCourses() {
        phase = .pickCourse
        course = nil
        selectedFileIDs = []
        includeLectureNotes = false
        selectedLectureIDs = []
        questions = []
        answers = []
        index = 0
        reviewIndex = 0
        picked = nil
        questionStartedAt = nil
        statusLine = ""
        statusDetail = ""
        statusCaption = ""
        prepareFraction = 0
        materialIndex = [:]
    }

    func selectCourse(_ course: Course) {
        self.course = course
        selectedFileIDs = []
        includeLectureNotes = false
        selectedLectureIDs = []
        difficulty = .medium
        questionCount = .ten
        phase = .setup
    }

    func backToSetup() {
        questions = []
        answers = []
        index = 0
        reviewIndex = 0
        picked = nil
        questionStartedAt = nil
        statusLine = ""
        statusDetail = ""
        statusCaption = ""
        prepareFraction = 0
        materialIndex = [:]
        phase = course == nil ? .pickCourse : .setup
    }

    func toggleFile(_ id: PersistentIdentifier) {
        if selectedFileIDs.contains(id) {
            selectedFileIDs.remove(id)
        } else {
            selectedFileIDs.insert(id)
        }
    }

    func toggleLecture(_ id: PersistentIdentifier) {
        if selectedLectureIDs.contains(id) {
            selectedLectureIDs.remove(id)
        } else {
            selectedLectureIDs.insert(id)
        }
    }

    func startPreparing(replyLanguage: Locale) {
        guard let course else { return }
        phase = .preparing
        if includeLectureNotes {
            setStage(
                String(localized: "Reading lecture notes"),
                String(localized: "Ready notes from this course are gathered for the quiz."),
                fraction: 0.2
            )
        } else {
            setStage(
                String(localized: "Checking the model"),
                String(localized: "The quiz uses the text model chosen in Settings."),
                fraction: 0.08
            )
        }
        Task {
            await prepare(course: course, replyLanguage: replyLanguage)
        }
    }

    /// Selects a letter and advances immediately — no separate Next tap.
    func pick(_ choice: QuizChoice) {
        guard phase == .taking, let question = current else { return }
        let started = questionStartedAt ?? Date()
        let seconds = max(Date().timeIntervalSince(started), 0.1)
        answers.append(
            QuizAnswerRecord(id: UUID(), question: question, picked: choice, seconds: seconds)
        )
        picked = nil
        if index + 1 >= questions.count {
            phase = .results
            questionStartedAt = nil
            statusLine = ""
            Self.log.info(
                "Quiz finished correct=\(self.correctCount) wrong=\(self.wrongCount) totalSec=\(Int(self.totalSeconds))"
            )
        } else {
            index += 1
            questionStartedAt = Date()
        }
    }

    func openReview() {
        guard !wrongAnswers.isEmpty else { return }
        reviewIndex = 0
        phase = .review
    }

    func closeReview() {
        reviewIndex = 0
        phase = .results
    }

    /// Next wrong, or back to results after the last one.
    func advanceReview() {
        guard phase == .review else { return }
        let wrongs = wrongAnswers
        guard !wrongs.isEmpty else {
            closeReview()
            return
        }
        if reviewIndex + 1 >= wrongs.count {
            closeReview()
        } else {
            reviewIndex += 1
        }
    }

    var currentReviewAnswer: QuizAnswerRecord? {
        let wrongs = wrongAnswers
        guard wrongs.indices.contains(reviewIndex) else { return nil }
        return wrongs[reviewIndex]
    }

    private func prepare(course: Course, replyLanguage: Locale) async {
        let prepareStarted = Date()
        do {
            Self.log.info("Quiz prepare begin target=\(self.questionCount.rawValue) difficulty=\(self.difficulty.rawValue, privacy: .public)")
            setStage(
                String(localized: "Checking the model"),
                String(localized: "The quiz uses the text model chosen in Settings."),
                fraction: 0.1
            )
            guard await LocalModelRuntime.shared.hasTextModel() else {
                phase = .needsModel
                statusLine = String(localized: "Download a text model in Settings.")
                statusDetail = ""
                statusCaption = ""
                prepareFraction = 0
                return
            }
            let materials = try await buildMaterials(course: course)
            guard !materials.isEmpty else {
                phase = .failed(String(localized: "There is not enough text for a quiz yet."))
                statusDetail = ""
                statusCaption = ""
                prepareFraction = 0
                return
            }
            materialIndex = Dictionary(uniqueKeysWithValues: materials.map { ($0.id, $0) })
            Self.log.info(
                "Quiz prepare materials=\(materials.count) ms=\(Int(Date().timeIntervalSince(prepareStarted) * 1000))"
            )

            // Cold start can take many seconds — keep 1 / 10 off screen until weights are resident.
            setStage(
                String(localized: "Checking the model"),
                String(localized: "The quiz uses the text model chosen in Settings."),
                fraction: 0.4
            )
            try await LocalModelRuntime.shared.warmTextModel()
            Self.log.info(
                "Quiz prepare warm done ms=\(Int(Date().timeIntervalSince(prepareStarted) * 1000))"
            )

            var drafts: [PendingItem] = []
            var seenStems: [String] = []
            let target = questionCount.rawValue
            var cursor = 0
            var misses = 0
            /// Windows that already produced an accepted question — never reused this prepare.
            var acceptedIds: Set<String> = []
            /// Windows that already failed a check — never retried this prepare (retrying them burned heat).
            var rejectedIds: Set<String> = []
            let missLimit = max(materials.count * 4, target * 3)

            func nextMaterial() -> Material? {
                for _ in 0..<materials.count {
                    let candidate = materials[cursor % materials.count]
                    cursor += 1
                    if acceptedIds.contains(candidate.id) { continue }
                    if rejectedIds.contains(candidate.id) { continue }
                    return candidate
                }
                return nil
            }

            while drafts.count < target && misses < missLimit {
                guard let material = nextMaterial() else {
                    Self.log.info(
                        "Quiz pool exhausted accepted=\(acceptedIds.count) drafts=\(drafts.count) target=\(target) ms=\(Int(Date().timeIntervalSince(prepareStarted) * 1000))"
                    )
                    break
                }
                await waitForForeground()
                // A hot phone slows the GPU and fails more calls. Pace, pause, or end early with what is ready.
                if await paceForHeat(draftCount: drafts.count, target: target) == .finishEarly {
                    Self.log.warning(
                        "Quiz heat finish early drafts=\(drafts.count) target=\(target) ms=\(Int(Date().timeIntervalSince(prepareStarted) * 1000))"
                    )
                    break
                }
                let writeFraction = 0.45 + (Double(drafts.count) / Double(max(target, 1))) * 0.5
                setStage(
                    String(localized: "Preparing questions"),
                    writingDetail(from: materials),
                    fraction: writeFraction,
                    caption: String(
                        format: String(localized: "%1$lld / %2$lld"),
                        drafts.count + 1,
                        target
                    )
                )
                let itemStarted = Date()
                do {
                    // One call per window — no parse-fail retry (that path burned heat on 1111…).
                    let draft = try await LocalModelRuntime.shared.makeQuizItem(
                        materialId: material.id,
                        materialTitle: material.title,
                        materialText: material.text,
                        difficulty: difficulty.promptWord,
                        replyLanguage: replyLanguage,
                        avoidStems: Array(seenStems.suffix(8))
                    )
                    let itemMs = Int(Date().timeIntervalSince(itemStarted) * 1000)
                    if let item = acceptDraft(
                        draft,
                        material: material,
                        seenStems: seenStems,
                        elapsedMs: itemMs
                    ) {
                        drafts.append(item)
                        seenStems.append(normalizedStem(item.prompt))
                        acceptedIds.insert(material.id)
                        misses = 0
                        Self.log.info(
                            "Quiz item accepted id=\(material.id, privacy: .public) ms=\(itemMs) drafts=\(drafts.count)/\(target) totalMs=\(Int(Date().timeIntervalSince(prepareStarted) * 1000))"
                        )
                    } else {
                        rejectedIds.insert(material.id)
                        misses += 1
                    }
                } catch {
                    let itemMs = Int(Date().timeIntervalSince(itemStarted) * 1000)
                    // The app left the screen during this call. The window is not at fault, so it stays in the pool.
                    if let left = lastBackgroundedAt, left >= itemStarted {
                        Self.log.info(
                            "Quiz item interrupted by background id=\(material.id, privacy: .public) ms=\(itemMs) \(error.localizedDescription, privacy: .public)"
                        )
                        continue
                    }
                    rejectedIds.insert(material.id)
                    misses += 1
                    Self.log.warning(
                        "Quiz item skip id=\(material.id, privacy: .public) ms=\(itemMs) totalMs=\(Int(Date().timeIntervalSince(prepareStarted) * 1000)) \(error.localizedDescription, privacy: .public)"
                    )
                }
            }

            // The model gave only a question and an answer. Swift builds the wrong choices and the key letter.
            let built = buildQuestions(from: drafts, materials: materials)
            guard !built.isEmpty else {
                Self.log.error(
                    "Quiz prepare empty drafts=\(drafts.count) ms=\(Int(Date().timeIntervalSince(prepareStarted) * 1000))"
                )
                phase = .failed(String(localized: "The model could not prepare questions. Try again."))
                statusDetail = ""
                statusCaption = ""
                prepareFraction = 0
                return
            }
            setStage(
                String(localized: "Almost ready"),
                String(localized: "The quiz is opening on the first question."),
                fraction: 0.98
            )
            questions = built
            answers = []
            index = 0
            picked = nil
            questionStartedAt = Date()
            phase = .taking
            statusLine = ""
            statusDetail = ""
            statusCaption = ""
            prepareFraction = 0
            Self.log.info(
                "Quiz ready count=\(built.count) difficulty=\(self.difficulty.rawValue, privacy: .public) ms=\(Int(Date().timeIntervalSince(prepareStarted) * 1000))"
            )
            #if DEBUG
            logQuestions(built)
            #endif
        } catch LocalModelError.notInstalled {
            phase = .needsModel
            statusLine = String(localized: "Download a text model in Settings.")
            statusDetail = ""
            statusCaption = ""
            prepareFraction = 0
        } catch {
            Self.log.error(
                "Quiz prepare failed ms=\(Int(Date().timeIntervalSince(prepareStarted) * 1000)) \(error.localizedDescription, privacy: .public)"
            )
            phase = .failed(String(localized: "The model could not prepare questions. Try again."))
            statusDetail = ""
            statusCaption = ""
            prepareFraction = 0
        }
    }

    #if DEBUG
    /// Debug builds only: writes every question with its choices and key so the log shows what the student sees.
    private func logQuestions(_ questions: [QuizQuestion]) {
        for (offset, question) in questions.enumerated() {
            let choices = question.choiceLines
                .map { "\($0.0.rawValue): \($0.1)" }
                .joined(separator: " | ")
            Self.log.info(
                "Quiz q\(offset + 1)/\(questions.count) key=\(question.correct.rawValue, privacy: .public) source=\(question.sourceTitle, privacy: .public) :: \(question.prompt, privacy: .public) | \(choices, privacy: .public)"
            )
        }
    }

    /// Debug builds only: fills the session with made-up answers and opens the results page for layout work.
    func loadDummyResults() {
        let samples: [(prompt: String, key: QuizChoice, choices: [QuizChoice: String], picked: QuizChoice, seconds: TimeInterval)] = [
            ("Which organelle produces most of the cell's ATP?", .a, [.a: "Mitochondria", .b: "Ribosome", .c: "Golgi apparatus"], .a, 6.4),
            ("What is the capital of Australia?", .b, [.a: "Sydney", .b: "Canberra", .c: "Melbourne"], .a, 11.2),
            ("Who wrote the novel Saatleri Ayarlama Enstitüsü?", .c, [.a: "Orhan Pamuk", .b: "Yaşar Kemal", .c: "Ahmet Hamdi Tanpınar"], .c, 8.9),
            ("What does the acronym CPU stand for?", .a, [.a: "Central processing unit", .b: "Computer personal unit", .c: "Control program utility"], .b, 14.7),
            ("Which year did the Republic of Türkiye begin?", .b, [.a: "1920", .b: "1923", .c: "1938"], .b, 5.1),
            ("Which gas do plants take in for photosynthesis?", .c, [.a: "Oxygen", .b: "Nitrogen", .c: "Carbon dioxide"], .c, 4.8),
            ("What is the derivative of sin(x)?", .a, [.a: "cos(x)", .b: "-sin(x)", .c: "tan(x)"], .c, 19.3),
            ("Which layer of the OSI model handles routing?", .b, [.a: "Data link", .b: "Network", .c: "Transport"], .b, 9.6),
            ("What is the unit of electrical resistance?", .c, [.a: "Volt", .b: "Watt", .c: "Ohm"], .c, 3.7),
            ("Which sorting algorithm has O(n log n) worst case?", .a, [.a: "Merge sort", .b: "Bubble sort", .c: "Insertion sort"], .b, 16.0),
        ]
        let built = samples.map { sample in
            QuizQuestion(
                id: UUID(),
                prompt: sample.prompt,
                choices: sample.choices,
                correct: sample.key,
                sourceKind: .block,
                sourceTitle: "Dummy source",
                blockToken: nil,
                second: nil,
                lectureID: nil,
                fileID: nil,
                courseID: nil,
                stickyToken: nil,
                sourceExcerpt: "",
                sourcePageIndex: nil
            )
        }
        questions = built
        answers = zip(built, samples).map { question, sample in
            QuizAnswerRecord(id: UUID(), question: question, picked: sample.picked, seconds: sample.seconds)
        }
        index = built.count - 1
        reviewIndex = 0
        picked = nil
        questionStartedAt = nil
        phase = .results
    }
    #endif

    private enum HeatVerdict {
        case go
        case finishEarly
    }

    /// Reads the thermal state before each model call.
    /// Serious: a short pause between questions. Critical: writing stops, the ring says the phone is cooling,
    /// and it resumes once the state drops below critical. If it stays critical too long, the quiz opens
    /// with the questions already accepted (or fails when there are none).
    private func paceForHeat(draftCount: Int, target: Int) async -> HeatVerdict {
        var state = ProcessInfo.processInfo.thermalState
        guard state == .serious || state == .critical else { return .go }
        if state == .serious {
            Self.log.info("Quiz heat serious pause drafts=\(draftCount)")
            do {
                try await Task.sleep(for: .seconds(2.5))
            } catch {
                return .finishEarly
            }
            return .go
        }
        let limit: TimeInterval = draftCount == 0 ? 180 : 60
        let started = Date()
        Self.log.warning("Quiz heat critical pause begin drafts=\(draftCount) limitSeconds=\(Int(limit))")
        setStage(
            String(localized: "Phone is cooling down"),
            String(localized: "Writing continues when the phone has cooled."),
            fraction: 0.45 + (Double(draftCount) / Double(max(target, 1))) * 0.5,
            caption: String(
                format: String(localized: "%1$lld / %2$lld"),
                draftCount + 1,
                target
            )
        )
        while state == .critical {
            if Date().timeIntervalSince(started) >= limit {
                Self.log.warning("Quiz heat critical pause gave up seconds=\(Int(limit))")
                return .finishEarly
            }
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return .finishEarly
            }
            state = ProcessInfo.processInfo.thermalState
        }
        Self.log.info(
            "Quiz heat critical pause end seconds=\(Int(Date().timeIntervalSince(started))) state=\(state.rawValue)"
        )
        return .go
    }

    private func setStage(
        _ title: String,
        _ detail: String,
        fraction: Double,
        caption: String = ""
    ) {
        statusLine = title
        statusDetail = detail
        statusCaption = caption
        prepareFraction = min(max(fraction, 0), 1)
    }

    /// Matches what the student actually put in the pool — recordings only, files only, or both.
    private func writingDetail(from materials: [Material]) -> String {
        let hasNotes = materials.contains { $0.kind == .block }
        let hasFiles = materials.contains { $0.kind == .file }
        switch (hasNotes, hasFiles) {
        case (true, true):
            return String(localized: "Each question is prepared only from the recordings and files you selected.")
        case (true, false):
            return String(localized: "Each question is prepared only from the recordings you selected.")
        case (false, _):
            // Prepare stays off with nothing selected, and an empty pool fails before this line is shown.
            return String(localized: "Each question is prepared only from the files you selected.")
        }
    }

    /// A question the model wrote, checked against its material. Choices are added later in Swift.
    private struct PendingItem {
        var prompt: String
        var answer: String
        var material: Material
    }

    /// Checks a draft and its duplicates. Logs why a draft was dropped.
    private func acceptDraft(
        _ draft: QuizDraftItem,
        material: Material,
        seenStems: [String],
        elapsedMs: Int
    ) -> PendingItem? {
        switch mapDraft(draft, fallback: material) {
        case .success(let item):
            guard !isDuplicate(item.prompt, in: seenStems) else {
                Self.log.warning(
                    "Quiz item rejected id=\(material.id, privacy: .public) reason=duplicate ms=\(elapsedMs)"
                )
                return nil
            }
            return item
        case .failure(let reason):
            Self.log.warning(
                "Quiz item rejected id=\(material.id, privacy: .public) reason=\(reason.rawValue, privacy: .public) ms=\(elapsedMs)"
            )
            return nil
        }
    }

    private enum DraftRejectReason: String, Error {
        case badStem
        case copiedStem
        case badAnswer
        case answerNotInMaterial
        case answerInStem
    }

    /// The stem must be a complete question, the answer must be words that the material really holds,
    /// and the stem must not give the answer away. The model never picks the key.
    private func mapDraft(_ draft: QuizDraftItem, fallback: Material) -> Result<PendingItem, DraftRejectReason> {
        guard let prompt = clippedStem(draft.question) else { return .failure(.badStem) }
        guard !isCopiedStem(prompt, from: fallback.text) else { return .failure(.copiedStem) }
        guard let answer = clippedAnswer(draft.answer) else { return .failure(.badAnswer) }
        guard answerAppears(in: fallback.text, answer: answer) else {
            return .failure(.answerNotInMaterial)
        }
        // The full answer as a phrase in the stem gives the key away. A single shared topic word is allowed.
        if answerPhraseAppears(in: prompt, answer: answer) { return .failure(.answerInStem) }
        return .success(PendingItem(prompt: prompt, answer: answer, material: fallback))
    }

    /// True when every answer word of length 2+ appears in the material (order does not matter).
    /// Contiguous match is preferred; word-bag match recovers “Bilişsel gelişim” vs hyphenation or reordering.
    private func answerAppears(in material: String, answer: String) -> Bool {
        let answerNorm = normalizedStem(answer)
        guard !answerNorm.isEmpty else { return false }
        let materialNorm = " \(normalizedStem(material)) "
        if materialNorm.contains(" \(answerNorm) ") { return true }
        let words = answerNorm.split(separator: " ").map(String.init).filter { $0.count >= 2 }
        guard !words.isEmpty else { return false }
        return words.allSatisfy { materialNorm.contains(" \($0) ") }
    }

    /// True when the answer’s words sit as one contiguous phrase inside the stem.
    private func answerPhraseAppears(in stem: String, answer: String) -> Bool {
        let answerNorm = normalizedStem(answer)
        guard !answerNorm.isEmpty else { return false }
        let words = answerNorm.split(separator: " ").map(String.init)
        // One short shared word (e.g. a topic name of 1 token) is not enough to call it a giveaway.
        guard words.count >= 2 || answerNorm.count >= 8 else { return false }
        return " \(normalizedStem(stem)) ".contains(" \(answerNorm) ")
    }

    /// Short words the model says answer the question. One word is fine here (a name, a date);
    /// the material check in `mapDraft` is what keeps it honest.
    private func clippedAnswer(_ raw: String) -> String? {
        var text = cleanedChoice(raw)
        let edge = CharacterSet(charactersIn: ".,;:!?\"'“”‘’()[]")
        text = text.trimmingCharacters(in: edge.union(.whitespacesAndNewlines))
        guard text.count >= 2 else { return nil }
        guard !isDegenerateText(text) else { return nil }
        guard !isWeakChoiceLabel(text) else { return nil }
        guard !looksLikeSentenceChoice(text) else { return nil }
        let words = text.split { $0.isWhitespace || $0.isNewline }.filter { !$0.isEmpty }
        guard !words.isEmpty, words.count <= Self.maxAnswerWords else { return nil }
        guard text.count <= Self.maxChoiceCharacters else { return nil }
        let lettersOnly = text.trimmingCharacters(in: CharacterSet.alphanumerics.inverted).uppercased()
        if lettersOnly.count == 1, QuizChoice(rawValue: lettersOnly) != nil { return nil }
        return text
    }

    /// Turns each checked question into A–C. The wrong choices are the other answers of this quiz,
    /// picked for a similar shape, and none of them may appear in this question's own passage.
    /// The key letter is a Swift shuffle. A question that cannot get two wrong choices is dropped.
    private func buildQuestions(from drafts: [PendingItem], materials: [Material]) -> [QuizQuestion] {
        var out: [QuizQuestion] = []
        for item in drafts {
            let others = drafts
                .filter { $0.material.id != item.material.id }
                .map(\.answer)
            guard let wrong = pickWrongChoices(for: item, others: others, materials: materials) else {
                Self.log.warning("Quiz item dropped id=\(item.material.id, privacy: .public) reason=noWrongChoices")
                continue
            }
            let shuffled = ([item.answer] + wrong).shuffled()
            guard let keyIndex = shuffled.firstIndex(of: item.answer), shuffled.count == 3 else { continue }
            let keys = QuizChoice.allCases
            var choices: [QuizChoice: String] = [:]
            for (place, text) in shuffled.enumerated() { choices[keys[place]] = text }
            let material = item.material
            out.append(
                QuizQuestion(
                    id: UUID(),
                    prompt: item.prompt,
                    choices: choices,
                    correct: keys[keyIndex],
                    sourceKind: material.kind,
                    sourceTitle: material.title,
                    blockToken: material.blockToken,
                    second: material.second,
                    lectureID: material.lectureID,
                    fileID: material.fileID,
                    courseID: material.courseID,
                    stickyToken: material.stickyToken,
                    sourceExcerpt: Self.excerptForFind(material.text),
                    sourcePageIndex: material.pageIndex
                )
            )
        }
        return out
    }

    /// Two wrong choices that look like the answer (a number next to a number, a name next to a name,
    /// a similar length) and are not in the question's own passage. With too few other answers,
    /// short phrases from other passages fill in.
    private func pickWrongChoices(for item: PendingItem, others: [String], materials: [Material]) -> [String]? {
        let ownText = " \(normalizedStem(item.material.text)) "
        var excluding: Set<String> = [item.answer.lowercased()]

        func usable(_ candidate: String) -> Bool {
            let fold = candidate.lowercased()
            if excluding.contains(where: { choicesNearlySame($0, fold) }) { return false }
            let norm = normalizedStem(candidate)
            guard !norm.isEmpty else { return false }
            return !ownText.contains(" \(norm) ")
        }

        var candidates = others.filter(usable)
        if candidates.count < 4 {
            let rest = materials.filter { $0.id != item.material.id }.shuffled().prefix(4)
            for other in rest {
                candidates.append(contentsOf: distractorPool(from: other.text, excluding: excluding).filter(usable))
            }
        }
        let ranked = candidates.shuffled().sorted {
            shapeScore(of: $0, like: item.answer) > shapeScore(of: $1, like: item.answer)
        }
        var picked: [String] = []
        for candidate in ranked {
            let fold = candidate.lowercased()
            if excluding.contains(where: { choicesNearlySame($0, fold) }) { continue }
            excluding.insert(fold)
            picked.append(candidate)
            if picked.count == 2 { return picked }
        }
        return nil
    }

    /// Higher is closer to the answer in shape: a digit next to a digit, a capital next to a capital,
    /// a similar number of words and letters.
    private func shapeScore(of candidate: String, like answer: String) -> Double {
        var score = 0.0
        if candidate.contains(where: \.isNumber) == answer.contains(where: \.isNumber) { score += 2 }
        if (candidate.first?.isUppercase ?? false) == (answer.first?.isUppercase ?? false) { score += 1 }
        let words = { (text: String) in text.split { $0.isWhitespace || $0.isNewline }.count }
        score -= Double(abs(words(candidate) - words(answer)))
        score -= Double(abs(candidate.count - answer.count)) / 10
        return score
    }

    /// Passage snippet for PDFKit find — first solid line, soft hyphens stripped, capped.
    private static func excerptForFind(_ text: String) -> String {
        let cleaned = text
            .replacingOccurrences(of: "\u{00AD}", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let line = cleaned.split(whereSeparator: \.isNewline).map(String.init)
            .first(where: { $0.trimmingCharacters(in: .whitespaces).count >= 12 })
            ?? cleaned
        let compact = line
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if compact.count <= 120 { return compact }
        let end = compact.index(compact.startIndex, offsetBy: 120)
        if let space = compact[..<end].lastIndex(where: { $0.isWhitespace }) {
            return String(compact[..<space]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(compact[..<end])
    }

    /// Short named phrases from a material window — filler when the quiz has too few other answers.
    private func distractorPool(from text: String, excluding: Set<String>) -> [String] {
        let separators = CharacterSet(charactersIn: ".\n;!?|/•·")
        var seen = Set<String>()
        var out: [String] = []
        for piece in text.components(separatedBy: separators) {
            let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let clipped = clippedChoice(trimmed) else { continue }
            let fold = clipped.lowercased()
            let words = fold.split { $0.isWhitespace || $0.isNewline }.filter { !$0.isEmpty }
            // MCQ literature: distractors should be noun phrases, not single glue words.
            guard words.count >= 2, words.count <= Self.maxChoiceWords else { continue }
            if excluding.contains(where: { choicesNearlySame($0, fold) }) { continue }
            if seen.contains(fold) { continue }
            seen.insert(fold)
            out.append(clipped)
        }
        let ideal = Self.idealChoiceCharacters
        return out.sorted { abs($0.count - ideal) < abs($1.count - ideal) }
    }

    /// True for discourse/glue labels that must never become a choice (e.g. “Örneğin”).
    private func isWeakChoiceLabel(_ text: String) -> Bool {
        let fold = text
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.weakChoiceFolds.contains(fold) { return true }
        let words = fold.split { $0.isWhitespace || $0.isNewline }.map(String.init).filter { !$0.isEmpty }
        if words.count == 1, Self.weakChoiceFolds.contains(words[0]) { return true }
        return false
    }

    private func choicesNearlySame(_ left: String, _ right: String) -> Bool {
        if left == right { return true }
        if left.hasPrefix(right) || right.hasPrefix(left) { return true }
        let leftWords = Set(left.split(separator: " "))
        let rightWords = Set(right.split(separator: " "))
        let base = max(min(leftWords.count, rightWords.count), 1)
        return Double(leftWords.intersection(rightWords).count) / Double(base) >= 0.8
    }

    /// Keeps a complete question through its first `?`. A short stem with no mark gets one `?` added
    /// when it already reads as a question (nedir / mi / what / …); statements and pastes stay rejected.
    private func clippedStem(_ raw: String) -> String? {
        var text = cleanedStem(raw)
        guard !isDegenerateText(text) else { return nil }
        if text.firstIndex(of: "?") == nil {
            let compact = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard compact.count >= 12, compact.count <= 140 else { return nil }
            guard looksLikeQuestionStem(compact) else { return nil }
            text = compact + "?"
        }
        guard let q = text.firstIndex(of: "?") else { return nil }
        let throughQ = String(text[...q]).trimmingCharacters(in: .whitespacesAndNewlines)
        let count = throughQ.count
        guard count >= 12 && count <= Self.maxStemCharacters else { return nil }
        guard !isDegenerateText(throughQ) else { return nil }
        return throughQ
    }

    /// Heuristic for a stem that forgot its `?` but is still a question, not a pasted sentence.
    private func looksLikeQuestionStem(_ text: String) -> Bool {
        let fold = text.lowercased()
        let cues = [
            "nedir", "nelerdir", "hangisi", "hangileri", "kimdir", "nasıl", "neden", "niçin",
            "kaç", "ne zaman", "hangi", " midir", " mıdır", " mudur", " müdür",
            " mi?", " mı?", " mu?", " mü?",
            "what ", "which ", "who ", "when ", "where ", "why ", "how ",
        ]
        if cues.contains(where: { fold.contains($0) }) { return true }
        // Trailing Turkish question particle without the mark: "... midir" already covered; bare "mi"/"mı" at end.
        let trimmed = fold.trimmingCharacters(in: .whitespacesAndNewlines)
        for ending in [" mi", " mı", " mu", " mü", " midir", " mıdır", " mudur", " müdür"] {
            if trimmed.hasSuffix(ending) { return true }
        }
        return false
    }

    /// True when the stem is mostly a paste of the material window, not a real question.
    private func isCopiedStem(_ stem: String, from material: String) -> Bool {
        let stemNorm = normalizedStem(stem)
        let stemWords = stemNorm.split(separator: " ").map(String.init)
        guard stemWords.count >= 12 else { return false }
        let materialNorm = normalizedStem(material)
        if materialNorm.hasPrefix(stemNorm) { return true }
        if stemNorm.count >= 48, materialNorm.contains(stemNorm) { return true }
        let lead = materialNorm.split(separator: " ").prefix(stemWords.count).map(String.init)
        guard lead.count >= 12 else { return false }
        let overlap = Set(stemWords).intersection(Set(lead)).count
        return Double(overlap) / Double(stemWords.count) >= 0.85
    }

    /// Accepts short named labels only. Full sentences and lone A/B/C are rejected (not soft-clipped into junk).
    private func clippedChoice(_ raw: String) -> String? {
        let text = cleanedChoice(raw)
        guard text.count >= 2 else { return nil }
        if text.allSatisfy(\.isNumber) { return nil }
        let lettersOnly = text
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            .uppercased()
        if lettersOnly.count == 1, QuizChoice(rawValue: lettersOnly) != nil { return nil }
        guard !isDegenerateText(text) else { return nil }
        guard !isWeakChoiceLabel(text) else { return nil }
        guard !looksLikeSentenceChoice(text) else { return nil }
        let words = text.split { $0.isWhitespace || $0.isNewline }.filter { !$0.isEmpty }
        guard words.count >= 2, words.count <= Self.maxChoiceWords else { return nil }
        guard text.count <= Self.maxChoiceCharacters else { return nil }
        return text
    }

    /// True when the model pasted a clause/paragraph instead of a short label.
    /// Titles like “Dr. George Engel, 1977” keep their abbreviation periods — those are not sentences.
    private func looksLikeSentenceChoice(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutTitles = trimmed.replacingOccurrences(
            of: #"\b(Dr|Mr|Mrs|Ms|Prof|Doç|Yrd|Jr|Sr)\."#,
            with: "$1",
            options: [.regularExpression, .caseInsensitive]
        )
        if withoutTitles.contains(". ") || withoutTitles.contains("! ") || withoutTitles.contains("? ") {
            return true
        }
        if withoutTitles.hasSuffix(".") || withoutTitles.hasSuffix("!") || withoutTitles.hasSuffix("?") {
            return true
        }
        if trimmed.contains(";") { return true }
        let words = trimmed.split { $0.isWhitespace || $0.isNewline }.filter { !$0.isEmpty }
        return words.count > Self.maxChoiceWords
    }

    /// Catches “111111…” / “aaaa…” loops that 2B sometimes emits under GuidedGen.
    private func isDegenerateText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8 else { return false }
        let unique = Set(trimmed)
        if unique.count <= 2, trimmed.count >= 12 { return true }
        var run = 1
        var previous: Character?
        for character in trimmed {
            if character == previous {
                run += 1
                if run >= 8 { return true }
            } else {
                run = 1
                previous = character
            }
        }
        return false
    }

    private func normalizedStem(_ text: String) -> String {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func isDuplicate(_ prompt: String, in seen: [String]) -> Bool {
        let norm = normalizedStem(prompt)
        guard !norm.isEmpty else { return true }
        for prior in seen {
            if prior == norm { return true }
            if prior.hasPrefix(norm) || norm.hasPrefix(prior) { return true }
            let overlap = Set(prior.split(separator: " ")).intersection(Set(norm.split(separator: " ")))
            let base = max(min(prior.split(separator: " ").count, norm.split(separator: " ").count), 1)
            if Double(overlap.count) / Double(base) >= 0.72 { return true }
        }
        return false
    }

    /// Drops a leading “A)” / “A.” the model sometimes prefixes on a choice field.
    private func cleanedChoice(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for letter in QuizChoice.allCases {
            for prefix in ["\(letter.rawValue))", "\(letter.rawValue).", "\(letter.rawValue):", "\(letter.rawValue) "] {
                if text.uppercased().hasPrefix(prefix) {
                    text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
            }
        }
        return text
    }

    /// Keeps the stem if the model stuffed “A) …” into the question field.
    private func cleanedStem(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let markers = [" A)", " A.", "\nA)", "\nA."]
        for marker in markers {
            if let range = text.range(of: marker, options: [.caseInsensitive]) {
                return String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return text
    }

    private func buildMaterials(course: Course) async throws -> [Material] {
        var materials: [Material] = []
        let courseID = course.persistentModelID

        if includeLectureNotes {
            setStage(
                String(localized: "Reading lecture notes"),
                String(localized: "Ready notes from this course are gathered for the quiz."),
                fraction: 0.22
            )
            let ready = course.lectures
                .filter { $0.state == LectureState.ready.rawValue && selectedLectureIDs.contains($0.persistentModelID) }
                .sorted { $0.startedAt > $1.startedAt }
            var noteWindows: [(chunk: String, title: String, block: Block, lecture: Lecture)] = []
            for lecture in ready {
                let blocks = lecture.blocks
                    .sorted { $0.second < $1.second }
                    .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                // Prefer emphasised and assignment-like blocks, then the rest.
                let ordered = blocks.sorted { lhs, rhs in
                    if lhs.importance != rhs.importance { return lhs.importance && !rhs.importance }
                    return lhs.second < rhs.second
                }
                for block in ordered {
                    let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    let title = lecture.title.isEmpty
                        ? lecture.startedAt.formatted(date: .abbreviated, time: .omitted)
                        : lecture.title
                    for chunk in chunked(text, size: Self.chunkSize) {
                        noteWindows.append((chunk, title, block, lecture))
                    }
                }
            }
            let noteLimit = min(
                Self.maxWindowsPerSource,
                max(Self.maxWindowsTotal - materials.count, 0)
            )
            for (blockIndex, window) in spreadPick(noteWindows, limit: noteLimit).enumerated() {
                materials.append(
                    Material(
                        id: "B\(blockIndex)",
                        kind: .block,
                        title: window.title,
                        text: window.chunk,
                        blockToken: window.block.token,
                        second: window.block.second,
                        lectureID: window.lecture.persistentModelID,
                        fileID: nil,
                        courseID: courseID,
                        stickyToken: nil,
                        pageIndex: nil
                    )
                )
            }
        }

        let files = course.files
            .filter { selectedFileIDs.contains($0.persistentModelID) }
            .sorted { lhs, rhs in
                if lhs.listOrder != rhs.listOrder { return lhs.listOrder < rhs.listOrder }
                return lhs.addedAt > rhs.addedAt
            }
        var fileIndex = 0
        let fileTotal = max(files.count, 1)
        for (place, file) in files.enumerated() {
            let kind = CourseFileKind(rawValue: file.kind) ?? .other
            guard kind == .pdf || kind == .image || kind == .slide else { continue }
            let room = Self.maxWindowsTotal - materials.count
            guard room > 0 else { break }
            let fileFraction = 0.28 + (Double(place) / Double(fileTotal)) * 0.15
            setStage(
                String(format: String(localized: "Reading %@"), file.displayName),
                String(localized: "Text is read on device from the selected PDF or image."),
                fraction: fileFraction
            )
            let url: URL
            do {
                url = try Vault.documents().appendingPathComponent(file.relativePath)
            } catch {
                continue
            }
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let pages: [FileTextPage]
            do {
                pages = try await FileTextExtractor.pages(at: url, kind: kind)
            } catch {
                Self.log.info("Quiz skip file=\(file.displayName, privacy: .public) \(error.localizedDescription, privacy: .public)")
                continue
            }
            // Whole file is chunked first; then windows are spread across start → end (not prefix-only).
            let allChunks = chunkedPages(pages, size: Self.chunkSize)
            let picked = spreadPick(allChunks, limit: min(Self.maxWindowsPerSource, room))
            Self.log.info(
                "Quiz file windows name=\(file.displayName, privacy: .public) chunks=\(allChunks.count) picked=\(picked.count)"
            )
            for chunk in picked {
                let id = "F\(fileIndex)"
                fileIndex += 1
                materials.append(
                    Material(
                        id: id,
                        kind: .file,
                        title: file.displayName,
                        text: chunk.text,
                        blockToken: nil,
                        second: nil,
                        lectureID: nil,
                        fileID: file.persistentModelID,
                        courseID: courseID,
                        stickyToken: nil,
                        pageIndex: chunk.pageIndex
                    )
                )
            }
        }

        // Shuffle so the quiz is not stuck on the opening pages of every file.
        return materials.shuffled()
    }

    /// Picks up to `limit` items spread evenly from start to end (covers a long PDF, not only the opening).
    private func spreadPick<T>(_ items: [T], limit: Int) -> [T] {
        guard limit > 0, !items.isEmpty else { return [] }
        if items.count <= limit { return items }
        var indices: [Int] = []
        indices.reserveCapacity(limit)
        for step in 0..<limit {
            let index = Int((Double(step) / Double(limit - 1)) * Double(items.count - 1))
            if indices.last != index {
                indices.append(index)
            }
        }
        if indices.count < limit {
            for index in 0..<items.count where !indices.contains(index) {
                indices.append(index)
                if indices.count == limit { break }
            }
            indices.sort()
        }
        return indices.map { items[$0] }
    }

    /// Splits long text into windows so each model call sees a different passage.
    private func chunked(_ text: String, size: Int) -> [String] {
        chunkedPages(
            [FileTextPage(pageIndex: 0, text: text)],
            size: size
        ).map(\.text)
    }

    /// Chunks page-aware file text; each window keeps the page where it starts.
    private func chunkedPages(_ pages: [FileTextPage], size: Int) -> [PagedChunk] {
        guard !pages.isEmpty else { return [] }
        var joined = ""
        var spans: [(pageIndex: Int, start: Int, end: Int)] = []
        for page in pages {
            let piece = page.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            if !joined.isEmpty {
                joined.append("\n")
            }
            let start = joined.count
            joined.append(piece)
            spans.append((page.pageIndex, start, joined.count))
        }
        let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        func pageAt(_ utf16Offset: Int) -> Int? {
            for span in spans where utf16Offset >= span.start && utf16Offset < span.end {
                return span.pageIndex
            }
            return spans.last?.pageIndex
        }

        if trimmed.count <= size {
            return [PagedChunk(text: trimmed, pageIndex: spans.first?.pageIndex)]
        }
        var parts: [PagedChunk] = []
        var start = trimmed.startIndex
        while start < trimmed.endIndex {
            let end = trimmed.index(start, offsetBy: size, limitedBy: trimmed.endIndex) ?? trimmed.endIndex
            let piece = String(trimmed[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty {
                let offset = trimmed.distance(from: trimmed.startIndex, to: start)
                parts.append(PagedChunk(text: piece, pageIndex: pageAt(offset)))
            }
            if end >= trimmed.endIndex { break }
            start = end
        }
        return parts
    }
}
