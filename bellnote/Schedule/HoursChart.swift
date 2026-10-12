import Foundation

struct SlotHours: Sendable, Equatable {
    var courseName: String
    var weeklyMinutes: Int
}

enum HoursChart {
    static func weekly(slots: [(courseName: String, startMinutes: Int, endMinutes: Int)]) -> [SlotHours] {
        var totals: [String: Int] = [:]
        for slot in slots {
            let span = max(0, slot.endMinutes - slot.startMinutes)
            totals[slot.courseName, default: 0] += span
        }
        return totals
            .map { SlotHours(courseName: $0.key, weeklyMinutes: $0.value) }
            .sorted { $0.courseName.localizedCompare($1.courseName) == .orderedAscending }
    }

    static func termTotal(weeklyMinutes: Int, weekCount: Int, cancelledWeeks: Int) -> Int {
        let active = max(0, weekCount - cancelledWeeks)
        return weeklyMinutes * active
    }

    static func weekCount(start: Date, end: Date, calendar: Calendar = .current) -> Int {
        let startDay = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: end)
        let days = calendar.dateComponents([.day], from: startDay, to: endDay).day ?? 0
        return max(1, Int(ceil(Double(days) / 7.0)))
    }
}
