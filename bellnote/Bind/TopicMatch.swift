import Foundation

enum TopicMatch {
    static func normalize(_ raw: String) -> String {
        raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    static func match(_ left: [String], _ right: [String], aliases: [(String, String)] = []) -> Bool {
        let a = Set(left.map(normalize).filter { !$0.isEmpty })
        let b = Set(right.map(normalize).filter { !$0.isEmpty })
        if !a.isDisjoint(with: b) {
            return true
        }
        for (rawLeft, rawRight) in aliases {
            let x = normalize(rawLeft)
            let y = normalize(rawRight)
            let leftHits = a.contains(x) || a.contains(y)
            let rightHits = b.contains(x) || b.contains(y)
            if leftHits && rightHits {
                return true
            }
        }
        return false
    }
}
