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

    /// Picks the blocks that matter for one question, so a small on-device model reads a few thousand characters
    /// instead of the whole course. Words are matched by their first letters (Turkish endings differ), and a word
    /// that appears in many blocks counts for little (BM25), so no word list is needed. The model still writes
    /// the answer; this only chooses which stored blocks it sees.
    /// Returns every block when the notes are already short or when no word of the question is found.
    static func relevant(
        _ blocks: [StudyBlock],
        to question: String,
        locale: Locale,
        wholeLimit: Int = 6_000,
        budget: Int = 7_000,
        topCount: Int = 8
    ) -> [StudyBlock] {
        let ordered = blocks.sorted { ($0.at, $0.second) < ($1.at, $1.second) }
        guard ordered.reduce(0, { $0 + $1.text.count }) > wholeLimit else { return ordered }
        let queryStems = Set(stems(of: question, locale: locale))
        guard !queryStems.isEmpty else { return ordered }

        var counts: [[String: Int]] = []
        var lengths: [Double] = []
        for block in ordered {
            var tally: [String: Int] = [:]
            let words = stems(of: ([block.text] + block.topics).joined(separator: " "), locale: locale)
            for stem in words { tally[stem, default: 0] += 1 }
            counts.append(tally)
            lengths.append(Double(max(words.count, 1)))
        }
        let total = Double(ordered.count)
        let averageLength = lengths.reduce(0, +) / total
        var weight: [String: Double] = [:]
        for stem in queryStems {
            let documents = Double(counts.filter { $0[stem] != nil }.count)
            if documents > 0 { weight[stem] = log(1 + (total - documents + 0.5) / (documents + 0.5)) }
        }
        guard !weight.isEmpty else { return ordered }

        // BM25: a short block that holds a rare word of the question beats a long block that only holds many
        // common ones, so a short remark is not crowded out by a long chapter.
        let k1 = 1.2
        let b = 0.75
        let scores: [Double] = counts.indices.map { index in
            weight.reduce(0.0) { sum, entry in
                guard let count = counts[index][entry.key] else { return sum }
                let tf = Double(count)
                let norm = tf + k1 * (1 - b + b * lengths[index] / averageLength)
                return sum + entry.value * tf * (k1 + 1) / norm
            }
        }
        let ranked = scores.indices.filter { scores[$0] > 0 }.sorted { scores[$0] > scores[$1] }
        var chosen = Set<Int>()
        var used = 0
        func take(_ candidate: Int) {
            guard ordered.indices.contains(candidate), !chosen.contains(candidate) else { return }
            let size = ordered[candidate].text.count
            if !chosen.isEmpty && used + size > budget { return }
            chosen.insert(candidate)
            used += size
        }
        // The best blocks first, then the blocks next to them while there is room.
        for index in ranked.prefix(topCount) { take(index) }
        for index in ranked.prefix(topCount) {
            take(index - 1)
            take(index + 1)
        }
        return chosen.sorted().map { ordered[$0] }
    }

    /// Lowercased words of three or more letters, cut to their first four letters.
    private static func stems(of text: String, locale: Locale) -> [String] {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: locale)
            .split { !$0.isLetter && !$0.isNumber }
            .filter { $0.count >= 3 }
            .map { String($0.prefix(4)) }
    }

}
