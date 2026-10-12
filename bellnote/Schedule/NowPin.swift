import Foundation

struct SlotClock: Sendable, Equatable, Identifiable {
    var id: UUID
    var courseID: UUID
    var courseName: String
    var weekday: Int
    var startMinutes: Int
    var endMinutes: Int
}

enum NowPin {
    static let leadMinutes = 5

    static func active(
        slots: [SlotClock],
        at date: Date,
        calendar: Calendar = .current
    ) -> [SlotClock] {
        let weekday = calendar.component(.weekday, from: date)
        let minutes = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        return slots.filter { slot in
            guard slot.weekday == weekday else { return false }
            let windowStart = slot.startMinutes - leadMinutes
            return minutes >= windowStart && minutes < slot.endMinutes
        }
    }
}
