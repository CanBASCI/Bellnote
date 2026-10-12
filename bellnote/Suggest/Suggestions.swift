import Foundation

enum SuggestionKind: String, Sendable {
    case examTopicMissing
    case assignmentDue
    case missedEmphasis
    case nilLink
    case missingFormula
}

struct SuggestionRow: Identifiable, Sendable, Equatable {
    var id: String
    var kind: SuggestionKind
    var sourceID: UUID
}

enum Suggestions {
    static func make(
        examTopicsWithoutNote: [UUID],
        dueAssignments: [UUID],
        missedEmphasis: [UUID],
        nilLinks: [UUID],
        missingFormulas: [UUID]
    ) -> [SuggestionRow] {
        var rows: [SuggestionRow] = []
        func take(_ ids: [UUID], kind: SuggestionKind) {
            for id in ids where rows.count < 3 {
                rows.append(SuggestionRow(id: "\(kind.rawValue)-\(id.uuidString)", kind: kind, sourceID: id))
            }
        }
        take(examTopicsWithoutNote, kind: .examTopicMissing)
        take(dueAssignments, kind: .assignmentDue)
        take(missedEmphasis, kind: .missedEmphasis)
        take(nilLinks, kind: .nilLink)
        take(missingFormulas, kind: .missingFormula)
        return rows
    }
}
