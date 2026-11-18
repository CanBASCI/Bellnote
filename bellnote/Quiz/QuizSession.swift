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
        do {
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

            // Cold start can take many seconds — keep 1 / 10 off screen until weights are resident.
            setStage(
                String(localized: "Checking the model"),
                String(localized: "The quiz uses the text model chosen in Settings."),
                fraction: 0.4
            )
            try await LocalModelRuntime.shared.warmTextModel()

            var built: [QuizQuestion] = []
            var seenStems: [String] = []
            let target = questionCount.rawValue
            var cursor = 0
            var misses = 0
            /// Windows that already produced an accepted question — never reused this prepare.
            var acceptedIds: Set<String> = []
            /// Windows that just failed — skip until the rest of the unused pool has been tried once.
            var coolDownIds: Set<String> = []
            let missLimit = max(materials.count * 4, target * 3)

            func nextMaterial(clearCoolDownIfStuck: Bool) -> Material? {
                func pick(skipping cool: Set<String>) -> Material? {
                    for _ in 0..<materials.count {
                        let candidate = materials[cursor % materials.count]
                        cursor += 1
                        if acceptedIds.contains(candidate.id) { continue }
                        if cool.contains(candidate.id) { continue }
                        return candidate
                    }
                    return nil
                }
                if let material = pick(skipping: coolDownIds) {
                    return material
                }
                guard clearCoolDownIfStuck, !coolDownIds.isEmpty else { return nil }
                coolDownIds.removeAll()
                return pick(skipping: [])
            }

            while built.count < target && misses < missLimit {
                guard let material = nextMaterial(clearCoolDownIfStuck: true) else {
                    Self.log.info(
                        "Quiz pool exhausted accepted=\(acceptedIds.count) built=\(built.count) target=\(target)"
                    )
                    break
                }
                let writeFraction = 0.45 + (Double(built.count) / Double(max(target, 1))) * 0.5
                setStage(
                    String(localized: "Preparing questions"),
                    writingDetail(from: materials),
                    fraction: writeFraction,
                    caption: String(
                        format: String(localized: "%1$lld / %2$lld"),
                        built.count + 1,
                        target
                    )
                )
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
                    if let question = acceptDraft(draft, material: material, seenStems: seenStems) {
                        built.append(question)
                        seenStems.append(normalizedStem(question.prompt))
                        acceptedIds.insert(material.id)
                        coolDownIds.remove(material.id)
                        misses = 0
                    } else {
                        coolDownIds.insert(material.id)
                        misses += 1
                    }
                } catch {
                    coolDownIds.insert(material.id)
                    misses += 1
                    Self.log.warning(
                        "Quiz item skip id=\(material.id, privacy: .public) \(error.localizedDescription, privacy: .public)"
                    )
                }
            }

            guard !built.isEmpty else {
                phase = .failed(String(localized: "The model could not prepare questions. Try again."))
                statusDetail = ""
                statusCaption = ""
                prepareFraction = 0
                return
            }
            if built.count > target {
                built = Array(built.prefix(target))
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
            Self.log.info("Quiz ready count=\(built.count) difficulty=\(self.difficulty.rawValue, privacy: .public)")
        } catch LocalModelError.notInstalled {
            phase = .needsModel
            statusLine = String(localized: "Download a text model in Settings.")
            statusDetail = ""
            statusCaption = ""
            prepareFraction = 0
        } catch {
            Self.log.error("Quiz prepare failed \(error.localizedDescription, privacy: .public)")
            phase = .failed(String(localized: "The model could not prepare questions. Try again."))
            statusDetail = ""
            statusCaption = ""
            prepareFraction = 0
        }
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

    /// Matches what the student actually put in the pool — notes only, files only, or both.
    private func writingDetail(from materials: [Material]) -> String {
        let hasNotes = materials.contains { $0.kind == .block }
        let hasFiles = materials.contains { $0.kind == .file }
        switch (hasNotes, hasFiles) {
        case (true, true):
            return String(localized: "Each question is prepared only from the notes and files you selected.")
        case (true, false):
            return String(localized: "Each question is prepared only from the lecture notes you included.")
        case (false, true):
            return String(localized: "Each question is prepared only from the files you selected.")
        case (false, false):
            return String(localized: "Each question is prepared only from the material you selected.")
        }
    }

    /// Maps a draft and checks duplicates. Logs why a draft was dropped.
    private func acceptDraft(
        _ draft: QuizDraftItem,
        material: Material,
        seenStems: [String]
    ) -> QuizQuestion? {
        switch mapDraft(draft, fallback: material) {
        case .success(let question):
            guard !isDuplicate(question.prompt, in: seenStems) else {
                Self.log.warning("Quiz item rejected id=\(material.id, privacy: .public) reason=duplicate")
                return nil
            }
            return question
        case .failure(let reason):
            Self.log.warning(
                "Quiz item rejected id=\(material.id, privacy: .public) reason=\(reason.rawValue, privacy: .public)"
            )
            return nil
        }
    }

    private enum DraftRejectReason: String, Error {
        case badCorrect
        case badStem
        case copiedStem
        case badChoice
        case duplicateChoices
    }

    private func mapDraft(_ draft: QuizDraftItem, fallback: Material) -> Result<QuizQuestion, DraftRejectReason> {
        guard let correct = QuizChoice(rawValue: draft.correct.rawValue) else {
            return .failure(.badCorrect)
        }
        // 2B often pastes A) B) C) into the stem and leaves choice fields as junk / numbers.
        let embedded = parseEmbeddedChoices(draft.question)
        let rawA = embedded?.choices[.a] ?? draft.choiceA
        let rawB = embedded?.choices[.b] ?? draft.choiceB
        let rawC = embedded?.choices[.c] ?? draft.choiceC
        let stemSource = embedded?.stem ?? draft.question
        guard let prompt = clippedStem(stemSource) else { return .failure(.badStem) }
        guard !isCopiedStem(prompt, from: fallback.text) else { return .failure(.copiedStem) }
        var slots: [String?] = [clippedChoice(rawA), clippedChoice(rawB), clippedChoice(rawC)]
        let hadNil = slots.contains(where: { $0 == nil })
        guard let filled = completeChoices(
            &slots,
            materialText: fallback.text,
            materialId: fallback.id
        ) else {
            return .failure(hadNil ? .badChoice : .duplicateChoices)
        }
        // Always keep the material we asked for — the model often invents sourceId.
        let material = fallback
        return .success(
            QuizQuestion(
                id: UUID(),
                prompt: prompt,
                choices: [.a: filled[0], .b: filled[1], .c: filled[2]],
                correct: correct,
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

    /// Fills missing choices and replaces duplicates with short phrases taken from the same material.
    private func completeChoices(
        _ slots: inout [String?],
        materialText: String,
        materialId: String
    ) -> [String]? {
        var excluding = Set(slots.compactMap { $0?.lowercased() })
        var pool = distractorPool(from: materialText, excluding: excluding)
        var salvaged = 0
        for index in slots.indices where slots[index] == nil {
            guard let next = takeDistractor(from: &pool, excluding: &excluding) else { return nil }
            slots[index] = next
            salvaged += 1
        }
        var seen: [String] = []
        for index in slots.indices {
            guard let current = slots[index] else { return nil }
            let fold = current.lowercased()
            if seen.contains(where: { choicesNearlySame($0, fold) }) {
                guard let next = takeDistractor(from: &pool, excluding: &excluding) else { return nil }
                slots[index] = next
                seen.append(next.lowercased())
                salvaged += 1
            } else {
                seen.append(fold)
            }
        }
        let filled = slots.compactMap { $0 }
        guard filled.count == 3 else { return nil }
        let folds = filled.map { $0.lowercased() }
        guard Set(folds).count == 3 else { return nil }
        // One soft repair is OK; two+ means the draft was mostly junk — drop it.
        guard salvaged <= 1 else {
            Self.log.info(
                "Quiz choices salvage rejected id=\(materialId, privacy: .public) count=\(salvaged)"
            )
            return nil
        }
        if salvaged > 0 {
            Self.log.info(
                "Quiz choices salvaged id=\(materialId, privacy: .public) count=\(salvaged)"
            )
        }
        return filled
    }

    private func takeDistractor(from pool: inout [String], excluding: inout Set<String>) -> String? {
        while let next = pool.first {
            pool.removeFirst()
            let fold = next.lowercased()
            if excluding.contains(where: { choicesNearlySame($0, fold) }) { continue }
            excluding.insert(fold)
            return next
        }
        return nil
    }

    /// Named phrases from the material window — used only to repair one junk/duplicate choice.
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

    /// When the model stuffs `A) … B) … C) …` into `question`, pull stem + three choices out.
    private func parseEmbeddedChoices(
        _ raw: String
    ) -> (stem: String, choices: [QuizChoice: String])? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let a = choiceMarkerRange("A", in: text),
              let b = choiceMarkerRange("B", in: text, after: a.upperBound),
              let c = choiceMarkerRange("C", in: text, after: b.upperBound)
        else { return nil }
        let stem = String(text[..<a.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let choiceA = String(text[a.upperBound..<b.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let choiceB = String(text[b.upperBound..<c.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        // Ignore a trailing “D)” the model sometimes still appends.
        var choiceC = String(text[c.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = choiceMarkerRange("D", in: choiceC) {
            choiceC = String(choiceC[..<d.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !stem.isEmpty, !choiceA.isEmpty, !choiceB.isEmpty, !choiceC.isEmpty else {
            return nil
        }
        return (stem, [.a: choiceA, .b: choiceB, .c: choiceC])
    }

    private func choiceMarkerRange(
        _ letter: String,
        in text: String,
        after start: String.Index? = nil
    ) -> Range<String.Index>? {
        let from = start ?? text.startIndex
        let slice = text[from...]
        for marker in [" \(letter))", " \(letter).", " \(letter):", "\n\(letter))", "\n\(letter).", "\n\(letter):"] {
            if let range = slice.range(of: marker, options: [.caseInsensitive]) {
                return range
            }
        }
        // Leading “A)” with no space before it.
        if start == nil {
            for marker in ["\(letter))", "\(letter).", "\(letter):"] {
                if text.range(of: marker, options: [.caseInsensitive, .anchored]) != nil {
                    return text.range(of: marker, options: [.caseInsensitive, .anchored])
                }
            }
        }
        return nil
    }

    /// Keeps a complete question through its first `?`. Never mid-sentence soft-clip; never invents `?`.
    private func clippedStem(_ raw: String) -> String? {
        let text = cleanedStem(raw)
        guard !isDegenerateText(text) else { return nil }
        guard let q = text.firstIndex(of: "?") else { return nil }
        let throughQ = String(text[...q]).trimmingCharacters(in: .whitespacesAndNewlines)
        let count = throughQ.count
        guard count >= 12 && count <= Self.maxStemCharacters else { return nil }
        guard !isDegenerateText(throughQ) else { return nil }
        return throughQ
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
    private func looksLikeSentenceChoice(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains(". ") || trimmed.contains("! ") || trimmed.contains("? ") { return true }
        if trimmed.hasSuffix(".") || trimmed.hasSuffix("!") || trimmed.hasSuffix("?") { return true }
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
                .filter { $0.state == LectureState.ready.rawValue }
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
