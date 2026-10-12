import Foundation

enum QualityGate {
    static func passes(text: String, expectedSeconds: Int) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace).count
        if expectedSeconds < 30 { return words >= 3 }
        let wordsPerMinute = Double(words) / (Double(expectedSeconds) / 60.0)
        return wordsPerMinute >= 40
    }
}
