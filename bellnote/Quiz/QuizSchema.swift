import Foundation
import FoundationModels
import SwiftData

/// Forced A–C letter so GuidedGen cannot omit or invent `correct`.
@Generable
enum QuizDraftLetter: String, Sendable {
    case a = "A"
    case b = "B"
    case c = "C"
}

/// One multiple-choice item. Generated alone — a 2B model often breaks on a batch array.
/// Field order matters: question and choices first so a short token budget still fills them.
@Generable
struct QuizDraftItem {
    /// Stem only. Never include A, B, C or the choice text here.
    /// No Regex pattern on the stem — length patterns made GuidedGen stall mid-field on 2B.
    @Guide(description: "One short complete question ending with ?. At most 140 characters — stop when done, do not paste material. No A/B/C inside.")
    var question: String

    @Guide(description: "Short named concept from the material for A, 2–8 words, under 90 characters. Not a sentence. Not only a letter.")
    var choiceA: String

    @Guide(description: "Short named concept from the material for B, different from A and C, 2–8 words, under 90 characters. Not a sentence.")
    var choiceB: String

    @Guide(description: "Short named concept from the material for C, different from A and B, 2–8 words, under 90 characters. Not a sentence.")
    var choiceC: String

    @Guide(description: "The one correct choice letter: A, B, or C.")
    var correct: QuizDraftLetter

    /// Short id from the materials list, such as B0 or F1.
    @Guide(description: "Material id such as B0 or F1.")
    var sourceId: String
}

enum QuizDifficulty: String, CaseIterable, Identifiable, Sendable {
    case easy
    case medium
    case hard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .easy: String(localized: "Easy")
        case .medium: String(localized: "Medium")
        case .hard: String(localized: "Hard")
        }
    }

    var promptWord: String {
        switch self {
        case .easy: "easy"
        case .medium: "medium"
        case .hard: "hard"
        }
    }
}

enum QuizChoice: String, CaseIterable, Identifiable, Sendable {
    case a = "A"
    case b = "B"
    case c = "C"

    var id: String { rawValue }
}

enum QuizQuestionCount: Int, CaseIterable, Identifiable, Sendable {
    case ten = 10
    case twenty = 20
    case thirty = 30
    case fifty = 50

    var id: Int { rawValue }

    var title: String { String(rawValue) }
}

enum QuizSourceKind: String, Sendable {
    case block
    case file
    case sticky
}

/// One prepared question. Session-only; not stored in SwiftData.
struct QuizQuestion: Identifiable, Equatable, Sendable {
    let id: UUID
    let prompt: String
    let choices: [QuizChoice: String]
    let correct: QuizChoice
    let sourceKind: QuizSourceKind
    let sourceTitle: String
    /// Block token when the source is a note.
    let blockToken: UUID?
    let second: Int?
    let lectureID: PersistentIdentifier?
    let fileID: PersistentIdentifier?
    let courseID: PersistentIdentifier?
    let stickyToken: UUID?
    /// Material window text used to find the passage in a PDF source.
    let sourceExcerpt: String
    /// 0-based PDF page for file sources when known.
    let sourcePageIndex: Int?

    var choiceLines: [(QuizChoice, String)] {
        QuizChoice.allCases.compactMap { key in
            guard let text = choices[key] else { return nil }
            return (key, text)
        }
    }
}

struct QuizAnswerRecord: Identifiable, Equatable, Sendable {
    let id: UUID
    let question: QuizQuestion
    let picked: QuizChoice
    let seconds: TimeInterval

    var isCorrect: Bool { picked == question.correct }
}
