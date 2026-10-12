import Foundation

struct StudyFilter: Sendable, Equatable {
    var topic: String?
    var start: Date?
    var end: Date?
    var kind: BlockKind?
    var emphasisOnly: Bool
    var notUnderstoodOnly: Bool
    var lectureToken: UUID?

    static let wholeCourse = StudyFilter(emphasisOnly: false, notUnderstoodOnly: false)
}

struct StudyBlock: Identifiable, Sendable, Equatable {
    var id: UUID
    var at: Date
    var second: Int
    var kind: BlockKind
    var text: String
    var topics: [String]
    var listItems: [String]
    var numbers: [Double]
    var importance: Bool
    var missing: Bool
    var userFlag: Bool
    var examScope: Bool
}

enum StudySelection {
    static func select(_ blocks: [StudyBlock], filter: StudyFilter) -> [StudyBlock] {
        blocks.filter { block in
            if let start = filter.start, block.at < start { return false }
            if let end = filter.end, block.at > end { return false }
            if let kind = filter.kind, block.kind != kind { return false }
            if filter.emphasisOnly && !(block.importance || block.examScope) { return false }
            if filter.notUnderstoodOnly && !block.userFlag { return false }
            if let topic = filter.topic, !topic.isEmpty {
                return TopicMatch.match(block.topics + [block.text], [topic])
            }
            return true
        }
        .sorted { $0.at < $1.at }
    }

    static func quizOrder(_ blocks: [StudyBlock], missed: Set<UUID>) -> [StudyBlock] {
        let filtered = blocks
        return filtered.sorted { left, right in
            let leftRank = rank(left, missed: missed)
            let rightRank = rank(right, missed: missed)
            if leftRank != rightRank { return leftRank < rightRank }
            return left.at < right.at
        }
    }

    private static func rank(_ block: StudyBlock, missed: Set<UUID>) -> Int {
        if block.examScope || block.importance { return 0 }
        if missed.contains(block.id) { return 1 }
        if block.missing || block.kind == .list || block.kind == .example || block.kind == .definition { return 2 }
        return 3
    }
}
