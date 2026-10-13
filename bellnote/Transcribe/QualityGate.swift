import Foundation

enum QualityGate {
    static func passes(text: String, expectedSeconds: Int) -> Bool {
        _ = expectedSeconds
        return !text.split(whereSeparator: \.isWhitespace).isEmpty
    }
}
