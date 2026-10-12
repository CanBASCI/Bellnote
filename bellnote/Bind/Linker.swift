import Foundation

struct BindableBlock: Identifiable, Sendable, Equatable {
    var id: UUID
    var courseId: UUID
    var at: Date
    var topics: [String]
    var embedding: [Double]

    init(
        id: UUID = UUID(),
        courseId: UUID,
        at: Date,
        topics: [String],
        embedding: [Double] = []
    ) {
        self.id = id
        self.courseId = courseId
        self.at = at
        self.topics = topics
        self.embedding = embedding
    }
}

struct BoundLink: Sendable, Equatable {
    var from: UUID
    var to: UUID?
    var why: String
}

enum Linker {
    static let embedCutoff = 0.86

    static func bind(
        _ block: BindableBlock,
        in notes: [BindableBlock],
        timeHint: TimeHint? = nil,
        aliases: [(String, String)] = []
    ) -> BoundLink {
        let pool = notes.filter { $0.courseId == block.courseId && $0.at < block.at && $0.id != block.id }
        let window = pool.filter { candidate in
            guard let timeHint else { return true }
            return timeHint.contains(candidate.at, relativeTo: block.at)
        }
        let ordered = window.sorted { $0.at > $1.at }
        if let hit = ordered.first(where: { TopicMatch.match($0.topics, block.topics, aliases: aliases) }) {
            return BoundLink(from: block.id, to: hit.id, why: "topic+time")
        }
        if let hit = ordered.first(where: { embedScore($0, block) > embedCutoff }) {
            return BoundLink(from: block.id, to: hit.id, why: "topic+time")
        }
        return BoundLink(from: block.id, to: nil, why: "no-match")
    }

    static func bindExamTopics(
        _ topics: [String],
        in notes: [BindableBlock],
        courseId: UUID,
        before: Date,
        aliases: [(String, String)] = []
    ) -> [BoundLink] {
        topics.map { topic in
            let probe = BindableBlock(courseId: courseId, at: before, topics: [topic])
            return bind(probe, in: notes, aliases: aliases)
        }
    }

    static func embedScore(_ left: BindableBlock, _ right: BindableBlock) -> Double {
        cosine(left.embedding, right.embedding)
    }

    static func cosine(_ left: [Double], _ right: [Double]) -> Double {
        guard left.count == right.count, !left.isEmpty else { return 0 }
        var dot = 0.0
        var leftNorm = 0.0
        var rightNorm = 0.0
        for index in left.indices {
            dot += left[index] * right[index]
            leftNorm += left[index] * left[index]
            rightNorm += right[index] * right[index]
        }
        let denom = leftNorm.squareRoot() * rightNorm.squareRoot()
        guard denom > 0 else { return 0 }
        return dot / denom
    }
}
