import Foundation

enum AnswerGrade: String, Sendable {
    case correct
    case partial
    case wrong
    case skip
}

enum QuizScore {
    static func grade(answer: String, blockText: String, numbers: [Double] = []) -> AnswerGrade {
        let spoken = normalize(answer)
        let source = normalize(blockText)
        if spoken.isEmpty || source.isEmpty {
            return .wrong
        }
        if source == spoken || source.contains(spoken) && spoken.split(separator: " ").count >= 3 {
            return .correct
        }
        let sourceTokens = Set(source.split(separator: " ").map(String.init))
        let spokenTokens = Set(spoken.split(separator: " ").map(String.init).filter { $0.count > 2 })
        guard !spokenTokens.isEmpty else { return .wrong }
        let overlap = spokenTokens.intersection(sourceTokens).count
        let ratio = Double(overlap) / Double(spokenTokens.count)
        if ratio >= 0.85 && spokenTokens.count >= max(3, sourceTokens.count / 2) {
            return .correct
        }
        if contradicts(spokenTokens, sourceTokens) {
            return .wrong
        }
        if ratio >= 0.35 {
            return .partial
        }
        if !numbers.isEmpty {
            let spokenNumbers = numbersIn(answer)
            if !spokenNumbers.isEmpty && Set(spokenNumbers) == Set(numbers) && ratio >= 0.2 {
                return .partial
            }
            if !spokenNumbers.isEmpty && Set(spokenNumbers).isDisjoint(with: numbers) {
                return .wrong
            }
        }
        return .wrong
    }

    private static func contradicts(_ spoken: Set<String>, _ source: Set<String>) -> Bool {
        let negations: Set<String> = ["not", "never", "no"]
        let spokenNeg = !spoken.isDisjoint(with: negations)
        let sourceNeg = !source.isDisjoint(with: negations)
        return spokenNeg != sourceNeg && !spoken.intersection(source).isEmpty
    }

    private static func numbersIn(_ text: String) -> [Double] {
        let pattern = #"-?\d+(?:\.\d+)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let span = Range(match.range, in: text) else { return nil }
            return Double(text[span])
        }
    }

    static func normalize(_ raw: String) -> String {
        raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
