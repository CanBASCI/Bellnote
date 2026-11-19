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
    /// Soft ceiling, named labels, not paragraph distractors.
    private static let maxChoiceCharacters = 90
    private static let maxStemCharacters = 500
    /// How many questions the text model may write per quiz. 0 builds every question in Swift, so no model runs
    /// and nothing heats up. Above 0 the model writes that many first and Swift fills in the rest.
    private static let modelQuestionBudget = 0
    /// Longest sentence Swift turns into a fill-in-the-blank question.
    private static let maxClozeSentenceCharacters = 220
    /// A sentence turned into a fill-in-the-blank stem. Longer than a question, because it is a full sentence.
    private static let maxClozeCharacters = 260
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
        // Self.log.info("Quiz app background=\(isBackground) phase=\(String(describing: self.phase), privacy: .public)")
    }

    /// Holds the write loop while the app is in the background and continues when it comes back.
    private func waitForForeground() async {
        guard isInBackground, phase == .preparing else { return }
        // let started = Date()
        // Self.log.info("Quiz pause: app is in the background")
        while isInBackground, phase == .preparing {
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
        }
        // Self.log.info("Quiz resume after background ms=\(Int(Date().timeIntervalSince(started) * 1000))")
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
                Self.modelQuestionBudget > 0 ? String(localized: "Checking the model") : String(localized: "Reading the material"),
                Self.modelQuestionBudget > 0
                    ? String(localized: "The quiz uses the text model chosen in Settings.")
                    : String(localized: "The questions are built from the text you selected."),
                fraction: 0.08
            )
        }
        Task {
            await prepare(course: course, replyLanguage: replyLanguage)
        }
    }

    /// Selects a letter and advances immediately, no separate Next tap.
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
            // Self.log.info(
                // "Quiz finished correct=\(self.correctCount) wrong=\(self.wrongCount) totalSec=\(Int(self.totalSeconds))"
            // )
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
            // Self.log.info("Quiz prepare begin target=\(self.questionCount.rawValue) difficulty=\(self.difficulty.rawValue, privacy: .public)")
            let usesModel = Self.modelQuestionBudget > 0
            if usesModel {
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
            // Self.log.info(
                // "Quiz prepare materials=\(materials.count) ms=\(Int(Date().timeIntervalSince(prepareStarted) * 1000))"
            // )

            if usesModel {
                // Cold start can take many seconds, keep 1 / 10 off screen until weights are resident.
                setStage(
                    String(localized: "Checking the model"),
                    String(localized: "The quiz uses the text model chosen in Settings."),
                    fraction: 0.4
                )
                try await LocalModelRuntime.shared.warmTextModel()
                // Self.log.info(
                    // "Quiz prepare warm done ms=\(Int(Date().timeIntervalSince(prepareStarted) * 1000))"
                // )
            }

            var drafts: [PendingItem] = []
            var seenStems: [String] = []
            let target = questionCount.rawValue
            let modelTarget = usesModel ? min(target, Self.modelQuestionBudget) : 0
            var cursor = 0
            var misses = 0
            /// Windows that already produced an accepted question, never reused this prepare.
            var acceptedIds: Set<String> = []
            /// Windows that already failed a check, never retried this prepare (retrying them burned heat).
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

            while drafts.count < modelTarget && misses < missLimit {
                guard let material = nextMaterial() else {
                    // Self.log.info(
                        // "Quiz pool exhausted accepted=\(acceptedIds.count) drafts=\(drafts.count) target=\(target) ms=\(Int(Date().timeIntervalSince(prepareStarted) * 1000))"
                    // )
                    break
                }
                await waitForForeground()
                // A hot phone slows the GPU and fails more calls. Pace, pause, or end early with what is ready.
                if await paceForHeat(draftCount: drafts.count, target: target) == .finishEarly {
                    // Self.log.warning(
                        // "Quiz heat finish early drafts=\(drafts.count) target=\(target) ms=\(Int(Date().timeIntervalSince(prepareStarted) * 1000))"
                    // )
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
                    // One call per window, no parse-fail retry (that path burned heat on 1111…).
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
                        // Self.log.info(
                            // "Quiz item accepted id=\(material.id, privacy: .public) ms=\(itemMs) drafts=\(drafts.count)/\(target) totalMs=\(Int(Date().timeIntervalSince(prepareStarted) * 1000))"
                        // )
                    } else {
                        rejectedIds.insert(material.id)
                        misses += 1
                    }
                } catch {
                    // let itemMs = Int(Date().timeIntervalSince(itemStarted) * 1000)
                    // The app left the screen during this call. The window is not at fault, so it stays in the pool.
                    if let left = lastBackgroundedAt, left >= itemStarted {
                        // Self.log.info(
                            // "Quiz item interrupted by background id=\(material.id, privacy: .public) ms=\(itemMs) \(error.localizedDescription, privacy: .public)"
                        // )
                        continue
                    }
                    rejectedIds.insert(material.id)
                    misses += 1
                    // Self.log.warning(
                        // "Quiz item skip id=\(material.id, privacy: .public) ms=\(itemMs) totalMs=\(Int(Date().timeIntervalSince(prepareStarted) * 1000)) \(error.localizedDescription, privacy: .public)"
                    // )
                }
            }

            // Swift fills in what the model did not write (all of it when the model budget is 0).
            if drafts.count < target {
                setStage(
                    String(localized: "Preparing questions"),
                    writingDetail(from: materials),
                    fraction: 0.9
                )
                // let clozeStarted = Date()
                let filled = buildClozeItems(needed: target - drafts.count, materials: materials, existing: drafts)
                drafts.append(contentsOf: filled)
                // Self.log.info(
                    // "Quiz cloze built count=\(filled.count) wanted=\(target - (drafts.count - filled.count)) ms=\(Int(Date().timeIntervalSince(clozeStarted) * 1000))"
                // )
            }

            // The model gave only a question and an answer. Swift builds the wrong choices and the key letter.
            let built = buildQuestions(from: drafts, materials: materials).shuffled()
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
            // Self.log.info(
                // "Quiz ready count=\(built.count) difficulty=\(self.difficulty.rawValue, privacy: .public) ms=\(Int(Date().timeIntervalSince(prepareStarted) * 1000))"
            // )
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
    /// Serious: a short pause between questions. Critical: writing stops, the ring says the device is cooling,
    /// and it resumes once the state drops below critical. If it stays critical too long, the quiz opens
    /// with the questions already accepted (or fails when there are none).
    private func paceForHeat(draftCount: Int, target: Int) async -> HeatVerdict {
        var state = ProcessInfo.processInfo.thermalState
        guard state == .serious || state == .critical else { return .go }
        if state == .serious {
            // Self.log.info("Quiz heat serious pause drafts=\(draftCount)")
            do {
                try await Task.sleep(for: .seconds(2.5))
            } catch {
                return .finishEarly
            }
            return .go
        }
        let limit: TimeInterval = draftCount == 0 ? 180 : 150
        let started = Date()
        // Self.log.warning("Quiz heat critical pause begin drafts=\(draftCount) limitSeconds=\(Int(limit))")
        setStage(
            String(localized: "Device is cooling down"),
            String(localized: "Writing continues when the device has cooled."),
            fraction: 0.45 + (Double(draftCount) / Double(max(target, 1))) * 0.5,
            caption: String(
                format: String(localized: "%1$lld / %2$lld"),
                draftCount + 1,
                target
            )
        )
        while state == .critical {
            if Date().timeIntervalSince(started) >= limit {
                // Self.log.warning("Quiz heat critical pause gave up seconds=\(Int(limit))")
                return .finishEarly
            }
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return .finishEarly
            }
            state = ProcessInfo.processInfo.thermalState
        }
        // Self.log.info(
            // "Quiz heat critical pause end seconds=\(Int(Date().timeIntervalSince(started))) state=\(state.rawValue)"
        // )
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

    /// Matches what the student actually put in the pool, recordings only, files only, or both.
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
        /// The original sentence when Swift built the question. It is what the source view looks for.
        var sourceSentence: String?
        /// What kind of thing the answer is, when Swift chose it. Wrong choices come from the same kind.
        var termClass: TermClass?
    }

    /// A year or a number, a name of a person or place, or a term. A wrong choice of another kind is easy to rule out.
    private enum TermClass {
        case number, name, concept
    }

    /// The kind of a phrase that was not chosen by Swift as an answer, from how it looks.
    private func shapeClass(of text: String) -> TermClass {
        if text.contains(where: \.isNumber) { return .number }
        let words = text.split(whereSeparator: \.isWhitespace)
        if !words.isEmpty, words.allSatisfy({ $0.first?.isUppercase ?? false }) { return .name }
        return .concept
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
                // Self.log.warning(
                    // "Quiz item rejected id=\(material.id, privacy: .public) reason=duplicate ms=\(elapsedMs)"
                // )
                return nil
            }
            return item
        case .failure:
            // Self.log.warning(
                // "Quiz item rejected id=\(material.id, privacy: .public) reason=\(reason.rawValue, privacy: .public) ms=\(elapsedMs)"
            // )
            #if DEBUG
            // Self.log.info(
                // "Quiz draft detail id=\(material.id, privacy: .public) q=\(draft.question, privacy: .public) | a=\(draft.answer, privacy: .public)"
            // )
            #endif
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
        let answer = clippedAnswer(draft.answer)
        var prompt = clippedStem(draft.question)
        var isCloze = false
        // The 2B model often writes a statement from the material where the question should be, with the
        // key term inside it. That is a usable fill-in-the-blank: Swift blanks the term out.
        if prompt == nil, let answer, let blanked = clozeStem(draft.question, answer: answer, material: fallback.text) {
            prompt = blanked
            isCloze = true
            // Self.log.info("Quiz item cloze id=\(fallback.id, privacy: .public)")
        }
        guard let prompt else { return .failure(.badStem) }
        if !isCloze, isCopiedStem(prompt, from: fallback.text) { return .failure(.copiedStem) }
        guard let answer else { return .failure(.badAnswer) }
        guard answerAppears(in: fallback.text, answer: answer) else {
            return .failure(.answerNotInMaterial)
        }
        // The full answer as a phrase in the stem gives the key away. A single shared topic word is allowed.
        if !isCloze, answerPhraseAppears(in: prompt, answer: answer) { return .failure(.answerInStem) }
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
        /// How many times a phrase already served as a wrong choice, so the same few do not repeat everywhere.
        var used: [String: Int] = [:]
        for item in drafts {
            let others = drafts.filter { $0.material.id != item.material.id }
            guard let wrong = pickWrongChoices(for: item, others: others, materials: materials, used: used) else {
                // Self.log.warning("Quiz item dropped id=\(item.material.id, privacy: .public) reason=noWrongChoices")
                continue
            }
            for text in wrong { used[text.lowercased(), default: 0] += 1 }
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
                    sourceExcerpt: item.sourceSentence.map { Self.excerptForFind($0) } ?? Self.excerptForFind(material.text),
                    sourcePageIndex: material.pageIndex
                )
            )
        }
        return out
    }

    /// Two wrong choices that look like the answer (a number next to a number, a name next to a name,
    /// a similar length) and are not in the question's own passage. With too few other answers,
    /// short phrases from other passages fill in.
    private func pickWrongChoices(
        for item: PendingItem,
        others: [PendingItem],
        materials: [Material],
        used: [String: Int]
    ) -> [String]? {
        let ownText = " \(normalizedStem(item.material.text)) "
        var excluding: Set<String> = [item.answer.lowercased()]

        func usable(_ candidate: String) -> Bool {
            let fold = candidate.lowercased()
            if excluding.contains(where: { choicesNearlySame($0, fold) }) { return false }
            let norm = normalizedStem(candidate)
            guard !norm.isEmpty else { return false }
            return !ownText.contains(" \(norm) ")
        }

        var candidates = others.map(\.answer).filter(usable)
        let answerClass = item.termClass ?? shapeClass(of: item.answer)
        // A year gets years near it as company, so it never stands next to a word. Real years from the other
        // questions come first; these fill in. A year that is in this question's own passage is left out (`usable`).
        if answerClass == .number, item.answer.count == 4, let year = Int(item.answer) {
            for step in [-13, -9, -6, -3, 3, 5, 8, 12] where (1000...2100).contains(year + step) {
                let invented = String(year + step)
                if usable(invented) { candidates.append(invented) }
            }
        }
        // Other answers are real terms, so they are reused before any loose phrase from a passage is tried.
        if candidates.count < 2 {
            let rest = materials.filter { $0.id != item.material.id }.shuffled().prefix(6)
            for other in rest {
                candidates.append(contentsOf: distractorPool(from: other.text, excluding: excluding).filter(usable))
            }
        }
        let answerFolds = Set(others.map { $0.answer.lowercased() })
        // Answers taken from the same file or recording as the question are likelier to be on the same topic.
        var classByFold: [String: TermClass] = [:]
        for other in others { classByFold[other.answer.lowercased()] = other.termClass ?? shapeClass(of: other.answer) }
        let sameSourceFolds = Set(others.filter { $0.material.title == item.material.title }.map { $0.answer.lowercased() })
        func score(_ candidate: String) -> Double {
            let fold = candidate.lowercased()
            var value = shapeScore(of: candidate, like: item.answer)
            if sameSourceFolds.contains(fold) { value += 1.0 }
            // The same kind of thing: a name beside a name, a term beside a term. Another kind is easy to rule out.
            value += (classByFold[fold] ?? shapeClass(of: candidate)) == answerClass ? 3.0 : -3.0
            // Another question's real answer is a better wrong choice than a loose phrase, until it has been used.
            if answerFolds.contains(fold) { value += 1.5 }
            value -= 2.0 * Double(used[fold, default: 0])
            return value
        }
        let ranked = candidates.shuffled().sorted { score($0) > score($1) }
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

    /// Passage snippet for PDFKit find, first solid line, soft hyphens stripped, capped.
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

    /// Short named phrases from a material window, filler when the quiz has too few other answers.
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
            guard words.count >= 2, words.count <= 5 else { continue }
            // A cut sentence is not a term: no commas or dashes inside, no glue word at either edge.
            if clipped.contains(where: { ",;:–—\"“”()".contains($0) }) { continue }
            if let first = words.first, Self.weakChoiceFolds.contains(String(first)) { continue }
            if let last = words.last, Self.weakChoiceFolds.contains(String(last)) { continue }
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

    /// A statement the model put in the question field becomes “Fill in the blank: … _____ …”.
    /// The statement must hold the answer, must be mostly the material's own words, and must keep real
    /// context around the blank. Nothing is invented: the words are the model's copy of the material.
    private func clozeStem(_ raw: String, answer: String, material: String) -> String? {
        let text = cleanedStem(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.contains("?") else { return nil }
        guard text.count >= 30, text.count <= Self.maxClozeCharacters else { return nil }
        guard !isDegenerateText(text) else { return nil }
        // Only the sentence that holds the answer. A second, half-written sentence is left out.
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .bySentences) { piece, _, _, _ in
            if let piece { sentences.append(piece.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        guard let sentence = sentences.first(where: {
            $0.range(of: answer, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }) else { return nil }
        guard let blanked = blankOut(sentence, answer: answer) else { return nil }
        // Most of the sentence must really be in the window, so a made-up sentence cannot pass.
        let materialWords = Set(normalizedStem(material).split(separator: " ").map(String.init))
        let sentenceWords = normalizedStem(sentence).split(separator: " ").map(String.init).filter { $0.count >= 3 }
        guard !sentenceWords.isEmpty else { return nil }
        let known = sentenceWords.filter { materialWords.contains($0) }.count
        guard Double(known) / Double(sentenceWords.count) >= 0.8 else { return nil }
        return clozePrompt(blanked)
    }

    private func clozePrompt(_ blanked: String) -> String {
        let trimmed = blanked.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!…").union(.whitespacesAndNewlines))
        return String(localized: "Fill in the blank:") + " " + trimmed
    }

    /// Replaces every whole-word occurrence of the answer with a blank. The blank also takes the letters that
    /// follow it (a Turkish case ending such as -na, or 'un after an apostrophe), so no stray suffix stays.
    /// Nil when the answer is not in the sentence or too little context is left around the blank.
    private func blankOut(_ sentence: String, answer: String) -> String? {
        let pattern = #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: answer) + #"['’]?\p{L}*"#
        let blanked = sentence.replacingOccurrences(
            of: pattern,
            with: "_____",
            options: [.regularExpression, .caseInsensitive]
        )
        guard blanked.contains("_____") else { return nil }
        // Three or more blanks leave no question to read.
        guard blanked.components(separatedBy: "_____").count - 1 <= 2 else { return nil }
        let context = blanked
            .replacingOccurrences(of: "_____", with: " ")
            .split { $0.isWhitespace || $0.isNewline }
        guard context.count >= 5 else { return nil }
        // A thin space keeps a comma or other mark from running into the underscores ("_____," read as one mark).
        return blanked.replacingOccurrences(
            of: #"_____(?=[,;:.!?)\]”»…])"#,
            with: "_____\u{2009}",
            options: .regularExpression
        )
    }

    // MARK: Questions built in Swift

    private struct ClozeCandidate {
        var material: Material
        var sentence: String
        var answer: String
        var score: Double
        var termClass: TermClass
    }

    /// Fill-in-the-blank questions built from the selected text, no model. Each window offers its best
    /// sentences. The first round takes one per window, the next round a second one, and so on, so the
    /// questions spread over everything that was selected.
    private func buildClozeItems(needed: Int, materials: [Material], existing: [PendingItem]) -> [PendingItem] {
        guard needed > 0 else { return [] }
        // Everything selected, once, so a term can be told from a phrase that only opens one sentence.
        let corpus = CorpusIndex(materials.map(\.text).joined(separator: "\n"))
        var out: [PendingItem] = []
        var seenStems = existing.map { normalizedStem($0.prompt) }
        var seenAnswers = existing.map { $0.answer.lowercased() }
        // The first pass keeps only terms the text returns to. If that leaves too few, a second pass lets the
        // rest in, so the count asked for is still met.
        for strict in [true, false] {
            guard out.count < needed else { break }
            var perWindow: [[ClozeCandidate]] = []
            for material in materials.shuffled() {
                let found = clozeCandidates(in: material, corpus: corpus, strict: strict).sorted { $0.score > $1.score }
                if !found.isEmpty { perWindow.append(found) }
            }
            let rounds = perWindow.map(\.count).max() ?? 0
            var round = 0
            while out.count < needed, round < rounds {
                for list in perWindow where round < list.count {
                    guard out.count < needed else { break }
                    let candidate = list[round]
                    guard let blanked = blankOut(candidate.sentence, answer: candidate.answer) else { continue }
                    let prompt = clozePrompt(blanked)
                    if isDuplicate(prompt, in: seenStems) { continue }
                    let fold = candidate.answer.lowercased()
                    if seenAnswers.contains(where: { choicesNearlySame($0, fold) }) { continue }
                    seenStems.append(normalizedStem(prompt))
                    seenAnswers.append(fold)
                    out.append(
                        PendingItem(
                            prompt: prompt,
                            answer: candidate.answer,
                            material: candidate.material,
                            sourceSentence: candidate.sentence,
                            termClass: candidate.termClass
                        )
                    )
                }
                round += 1
            }
        }
        return out
    }

    private func clozeCandidates(in material: Material, corpus: CorpusIndex, strict: Bool) -> [ClozeCandidate] {
        var result: [ClozeCandidate] = []
        for sentence in clozeSentences(from: material.text) {
            guard let best = bestClozeTerm(in: sentence, corpus: corpus, strict: strict) else { continue }
            result.append(
                ClozeCandidate(
                    material: material, sentence: sentence, answer: best.term, score: best.score, termClass: best.termClass
                )
            )
        }
        return result
    }

    /// Whole sentences of a window. Lines that stop mid-sentence are joined to the next line; a line that ends
    /// with a full stop (or a colon) ends the paragraph. Slide fragments without a stop merge into one long run
    /// that is then too long and is dropped.
    private func clozeSentences(from text: String) -> [String] {
        let cleaned = text
            .replacingOccurrences(of: "\u{00AD}", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
        var paragraphs: [String] = []
        var current = ""
        for raw in cleaned.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if current.isEmpty {
                current = line
            } else if let last = current.last, ".!?:;…".contains(last) {
                paragraphs.append(current)
                current = line
            } else {
                current += " " + line
            }
        }
        if !current.isEmpty { paragraphs.append(current) }
        var out: [String] = []
        // A stop followed by a capital or a digit ends a sentence even where the system splitter keeps them together
        // ("… galip geldi. 2005'de Armstrong …"). Common abbreviations are left whole.
        let boundary = #"(?<=[.!?…])(?<!\b(?:Dr|Prof|Doç|Yrd|Mr|Mrs|Ms|vb|vs|bkz|örn)\.)\s+(?=[\p{Lu}\p{N}])"#
        for paragraph in paragraphs {
            paragraph.enumerateSubstrings(in: paragraph.startIndex..<paragraph.endIndex, options: .bySentences) { piece, _, _, _ in
                guard let piece else { return }
                let parts = piece
                    .replacingOccurrences(of: boundary, with: "\u{1F}", options: .regularExpression)
                    .components(separatedBy: "\u{1F}")
                for part in parts {
                    if let sentence = self.usableClozeSentence(part) { out.append(sentence) }
                }
            }
        }
        // The last sentence of a window that stops without a full stop was probably cut in the middle.
        if let lastParagraph = paragraphs.last, let lastCharacter = lastParagraph.last,
           !".!?…\"”»)".contains(lastCharacter),
           let lastSentence = out.last, lastParagraph.hasSuffix(lastSentence) {
            out.removeLast()
        }
        return out
    }

    /// A sentence worth a question: whole, readable, not a header, a table row, a link, or a question already.
    private func usableClozeSentence(_ piece: String) -> String? {
        var sentence = piece.trimmingCharacters(in: .whitespacesAndNewlines)
        sentence = sentence.replacingOccurrences(of: #"^(?:[•▪●◦\-–—*]\s*)+"#, with: "", options: .regularExpression)
        sentence = sentence.replacingOccurrences(of: #"^\d+(?:\.\d+)*[.)]?\s+"#, with: "", options: .regularExpression)
        guard sentence.count >= 40, sentence.count <= Self.maxClozeSentenceCharacters else { return nil }
        guard !sentence.contains("?"), !sentence.contains("_____") else { return nil }
        guard !sentence.lowercased().contains("http"), !isDegenerateText(sentence) else { return nil }
        // Starts with a capital. A lowercase start is the tail of a line that was cut in the middle of a word.
        guard let first = sentence.first, first.isLetter, first.isUppercase else { return nil }
        // A bullet inside means slide lines were run together, and a stray bracket means a citation was cut.
        guard !sentence.contains(where: { "•▪●◦".contains($0) }) else { return nil }
        guard sentence.filter({ $0 == "(" }).count == sentence.filter({ $0 == ")" }).count else { return nil }
        let words = sentence.split(whereSeparator: \.isWhitespace)
        guard words.count >= 6, words.count <= 36 else { return nil }
        let letters = sentence.filter(\.isLetter).count
        guard Double(letters) / Double(max(sentence.count, 1)) >= 0.7 else { return nil }
        let capitals = words.filter { $0.first?.isUppercase ?? false }.count
        guard Double(capitals) / Double(words.count) <= 0.5 else { return nil }
        return sentence
    }

    /// The term to hide: a quoted term, the defined term at the start (“X, … is …”), a name, or a year.
    /// Nil when nothing in the sentence looks like a term worth asking about.
    /// `corpus` is all the selected text. A real term comes back in it; an opening phrase or a header word does not.
    /// With `strict` off, a term the text does not return to is allowed too.
    private func bestClozeTerm(in sentence: String, corpus: CorpusIndex, strict: Bool) -> (term: String, score: Double, termClass: TermClass)? {
        var options: [(term: String, score: Double, kind: ClozeTermKind)] = []

        let quoted = #"[“"‘]([^“”"‘’]{3,40})[”"’]"#
        if let range = sentence.range(of: quoted, options: .regularExpression) {
            let inner = String(sentence[range]).trimmingCharacters(in: CharacterSet(charactersIn: "“”\"‘’"))
            let innerWords = inner.split(whereSeparator: \.isWhitespace).count
            // One lowercase word in quotes ("nedeni") is an ordinary word, not a term.
            if (1...4).contains(innerWords), innerWords >= 2 || (inner.first?.isUppercase ?? false) {
                options.append((inner, 2.4, .quoted))
            }
        }

        // “Deneysel psikoloji, insan ve hayvan …”: the words before the first comma are what the sentence defines.
        if let comma = sentence.firstIndex(of: ",") {
            let head = String(sentence[..<comma]).trimmingCharacters(in: .whitespaces)
            let headWords = head.split(whereSeparator: \.isWhitespace)
            if (1...4).contains(headWords.count), head.count >= 4, head.count <= 40,
               head.first?.isUppercase ?? false, !head.contains(where: \.isNumber),
               let firstWord = headWords.first,
               !Self.weakChoiceFolds.contains(String(firstWord).lowercased())
            {
                options.append((head, 3.0, .head))
            }
        }

        // Names: runs of capitalised words (a lone capital at the start of the sentence is only the first word).
        let tokens = sentence.split(whereSeparator: \.isWhitespace).map(String.init)
        let edge = CharacterSet(charactersIn: ".,;:!?()[]“”\"…")
        var run: [String] = []
        func closeRun(startIndex: Int) {
            defer { run = [] }
            guard !run.isEmpty, run.count <= 4 else { return }
            if run.count == 1, startIndex == 0 { return }
            // A word after "Mirası:" or "Ögesel:" is capital because a line starts there, not because it is a name.
            if run.count == 1, startIndex > 0, tokens[startIndex - 1].hasSuffix(":") { return }
            options.append((run.joined(separator: " "), run.count >= 2 ? 2.0 : 1.4, run.count >= 2 ? ClozeTermKind.name : ClozeTermKind.singleName))
        }
        var runStart = 0
        for (index, token) in tokens.enumerated() {
            let trimmed = token.trimmingCharacters(in: edge)
            let core = trimmed.split(whereSeparator: { $0 == "'" || $0 == "’" }).first.map(String.init) ?? trimmed
            let isName = core.count >= 2 && (core.first?.isUppercase ?? false)
                && !(core == core.uppercased() && core.count > 5)
            if isName {
                if run.isEmpty { runStart = index }
                run.append(core)
                // A comma, a stop, or a suffix after an apostrophe ends the name.
                if core != token { closeRun(startIndex: runStart) }
            } else {
                closeRun(startIndex: runStart)
            }
        }
        closeRun(startIndex: runStart)

        // A single year is a good fact to ask for; two or more in one sentence leave the question unclear.
        let yearPattern = #"(?<![\d])(?:1[0-9]{3}|20[0-9]{2})(?![\d])"#
        var years: [String] = []
        var searchRange = sentence.startIndex..<sentence.endIndex
        while let range = sentence.range(of: yearPattern, options: .regularExpression, range: searchRange) {
            years.append(String(sentence[range]))
            searchRange = range.upperBound..<sentence.endIndex
        }
        if years.count == 1, let year = years.first {
            // A year that only closes a citation, "(Festinger, 1957)", cannot be reasoned out. It is the last pick.
            let inCitation = sentence.range(of: #"\([^()]*"# + year + #"[^()]*\)"#, options: .regularExpression) != nil
            options.append((year, inCitation ? 0.9 : 1.8, .year))
        }

        var best: (term: String, score: Double, termClass: TermClass)?
        for option in options {
            guard let term = clippedAnswer(option.term),
                  sentence.range(of: term, options: .caseInsensitive) != nil,
                  blankOut(sentence, answer: term) != nil,
                  isCleanClozeTerm(term)
            else { continue }
            let total = corpus.frequency(of: term, caseSensitive: false)
            let wordCount = term.split(whereSeparator: \.isWhitespace).count
            switch option.kind {
            case .head:
                // The words before the first comma are a term only when the text keeps coming back to them.
                // "Örnek olarak" or "Herhangi bir durumda" open one sentence and are gone.
                guard !strict || total >= (wordCount == 1 ? 3 : 2) else { continue }
            case .singleName:
                // A lone capital word is a name only when it is capital every time. "Sosyal" in a slide header
                // is an ordinary word that happens to start a line.
                let capital = corpus.frequency(of: term, caseSensitive: true)
                guard !strict || Double(capital) >= 0.8 * Double(total) else { continue }
            case .quoted, .name, .year:
                break
            }
            // A term the text returns to is a better thing to ask for.
            let score = option.score + 0.25 * Double(min(total, 5))
            let termClass: TermClass
            switch option.kind {
            case .name, .singleName: termClass = .name
            case .year: termClass = .number
            case .quoted, .head: termClass = .concept
            }
            if best == nil || score > (best?.score ?? 0) { best = (term, score, termClass) }
        }
        return best
    }

    private enum ClozeTermKind {
        case quoted, head, name, singleName, year
    }

    /// Words that close an opening phrase ("… olarak", "… dışında"). A term never holds one.
    private static let phraseCloserFolds: Set<String> = [
        "olarak", "için", "göre", "kadar", "sonra", "önce", "ile", "gibi", "rağmen", "dolayı", "itibaren",
        "karşın", "üzere", "boyunca", "yoluyla", "nedeniyle", "sayesinde", "yerine", "halde", "dışında",
        "içinde", "başında", "sonunda", "arasında", "ayrıca", "bunun", "herhangi",
    ]

    /// A term has no slide marks, no open bracket, no glue word, and does not end in a place or source ending
    /// (-da, -de, -dan, -den: "durumda", "basamağında"), which marks an opening phrase.
    private func isCleanClozeTerm(_ term: String) -> Bool {
        if term.contains(where: { "•▪●◦·|/\\_".contains($0) }) { return false }
        if term.filter({ $0 == "(" }).count != term.filter({ $0 == ")" }).count { return false }
        let words = term.lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
        guard let first = words.first, let last = words.last else { return false }
        // A word twice in a row is a slide that was read twice ("Yapısalcılık Yapısalcılık").
        if Set(words).count != words.count { return false }
        if words.contains(where: { Self.weakChoiceFolds.contains($0) || Self.phraseCloserFolds.contains($0) }) {
            return false
        }
        if Self.weakChoiceFolds.contains(first) || Self.weakChoiceFolds.contains(last) { return false }
        let lastCore = last.split(whereSeparator: { $0 == "'" || $0 == "’" }).first.map(String.init) ?? last
        // "Karnınız toksa": a clause with a condition, not a term.
        if lastCore.count >= 5, ["sa", "se", "ken"].contains(where: { lastCore.hasSuffix($0) }) { return false }
        if lastCore.count >= 5, ["da", "de", "ta", "te"].contains(where: { lastCore.hasSuffix($0) }) { return false }
        if lastCore.count >= 7, ["dan", "den", "tan", "ten"].contains(where: { lastCore.hasSuffix($0) }) { return false }
        return true
    }

    /// Word counts of all the selected text, to tell a term the text keeps returning to from a phrase that opens one sentence.
    private struct CorpusIndex {
        private struct WordCounts {
            private var words: [String] = []
            private var cumulative: [Int] = [0]

            init(_ counts: [String: Int]) {
                let sorted = counts.sorted { $0.key < $1.key }
                words = sorted.map(\.key)
                var running = 0
                for item in sorted {
                    running += item.value
                    cumulative.append(running)
                }
            }

            /// How many words in the text start with `prefix`.
            func count(prefix: String) -> Int {
                guard !prefix.isEmpty else { return 0 }
                var low = 0
                var high = words.count
                while low < high {
                    let mid = (low + high) / 2
                    if words[mid] < prefix { low = mid + 1 } else { high = mid }
                }
                var end = low
                while end < words.count, words[end].hasPrefix(prefix) { end += 1 }
                return cumulative[end] - cumulative[low]
            }
        }

        private let folded: WordCounts
        private let exact: WordCounts

        init(_ text: String) {
            var foldedCounts: [String: Int] = [:]
            var exactCounts: [String: Int] = [:]
            for word in Self.words(in: text) {
                foldedCounts[word.lowercased(), default: 0] += 1
                exactCounts[word, default: 0] += 1
            }
            folded = WordCounts(foldedCounts)
            exact = WordCounts(exactCounts)
        }

        private static func words(in text: String) -> [String] {
            text.components(separatedBy: CharacterSet.letters.union(.decimalDigits).inverted).filter { !$0.isEmpty }
        }

        /// How often the term is in the text, by its rarest word. A word loses its last two letters first, so a
        /// Turkish ending does not hide it. With `caseSensitive` only the same capitals count.
        func frequency(of term: String, caseSensitive: Bool) -> Int {
            var parts = Self.words(in: term)
            let long = parts.filter { $0.count >= 4 }
            if !long.isEmpty { parts = long }
            var lowest = Int.max
            for word in parts {
                let stem = word.count > 7 ? String(word.dropLast(2)) : word
                let found = caseSensitive
                    ? exact.count(prefix: stem)
                    : folded.count(prefix: stem.lowercased())
                lowest = min(lowest, found)
            }
            return lowest == Int.max ? 0 : lowest
        }
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
    /// Titles like “Dr. George Engel, 1977” keep their abbreviation periods, those are not sentences.
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
                // Self.log.info("Quiz skip file=\(file.displayName, privacy: .public) \(error.localizedDescription, privacy: .public)")
                continue
            }
            // Whole file is chunked first; then windows are spread across start → end (not prefix-only).
            let allChunks = chunkedPages(pages, size: Self.chunkSize)
            let picked = spreadPick(allChunks, limit: min(Self.maxWindowsPerSource, room))
            // Self.log.info(
                // "Quiz file windows name=\(file.displayName, privacy: .public) chunks=\(allChunks.count) picked=\(picked.count)"
            // )
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
