import Foundation

struct TimeHint: Sendable, Equatable {
    var daysBack: Int?

    func contains(_ candidate: Date, relativeTo anchor: Date, calendar: Calendar = .current) -> Bool {
        guard let daysBack else { return true }
        let start = calendar.date(byAdding: .day, value: -daysBack, to: calendar.startOfDay(for: anchor)) ?? anchor
        return candidate >= start && candidate < anchor
    }

    static func parse(_ raw: String) -> TimeHint? {
        let folded = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en"))
        if folded.contains("previous lecture") || folded.contains("last lecture") || folded.contains("last class") {
            return TimeHint(daysBack: 14)
        }
        if folded.contains("last week") {
            return TimeHint(daysBack: 14)
        }
        if folded.contains("earlier") {
            return TimeHint(daysBack: nil)
        }
        return nil
    }
}
