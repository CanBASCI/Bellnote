import Foundation
import FoundationModels
import SwiftData

/// One question and its answer span. Generated alone, a 2B model often breaks on a batch array.
/// The model writes only these two fields. Swift checks the answer against the material, builds the
/// wrong choices, and shuffles the letter, so the model never picks the key.
/// The order in the encoded schema is not under our control, so neither field may depend on the other.
@Generable
struct QuizDraftItem {
    /// Stem only. Never include the answer or A, B, C here.
    /// No Regex pattern on the stem, length patterns made GuidedGen stall mid-field on 2B.
    @Guide(description: "One short complete question ending with ?. At most 140 characters. Never include the answer in it. No A/B/C.")
    var question: String

    /// Words copied from the material, so Swift can check the fact is really there.
    @Guide(description: "The exact words from the material that answer the question: a name, term, number, or short phrase of 1 to 6 words, copied as written. Not a sentence.")
    var answer: String
}

enum QuizDifficulty: String, CaseIterable, Identifiable, Sendable {
    case easy
    case medium
    case hard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .easy: L10n.text("Easy")
        case .medium: L10n.text("Medium")
        case .hard: L10n.text("Hard")
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
    case forty = 40
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
