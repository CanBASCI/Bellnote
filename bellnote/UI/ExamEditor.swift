import OSLog
import SwiftData
import SwiftUI

/// Adds one exam to this course, or updates one already saved. Edit course opens this.
struct ExamEditor: View {
    @Bindable var term: Term
    /// The course this exam belongs to. The sheet does not ask the student to pick another.
    private let course: Course
    /// The sitting being changed. Nil adds a new one.
    private let editing: ExamSitting?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var kind: ExamKind = .midterm
    @State private var title = ""
    @State private var date = Calendar.current.startOfDay(for: .now)
    @State private var hasTime = false
    @State private var timeChoice: ExamTimeChoice = .other
    @State private var start = Date()
    @State private var end = Date()
    @State private var placePreset: PlacePreset = .other
    @State private var placeCustom = ""
    @State private var reminder: ReminderKind = .none
    @State private var leadDays = 1
    /// A whole number from 0 to 100, or empty until the result is out.
    @State private var scoreText = ""

    init(term: Term, course: Course, editing: ExamSitting? = nil) {
        self.term = term
        self.course = course
        self.editing = editing
        let calendar = Calendar.current
        let storedKind = ExamKind(rawValue: editing?.kind ?? "") ?? .midterm
        _kind = State(initialValue: storedKind)
        _title = State(initialValue: editing?.title ?? "")
        let storedDate = editing?.date ?? calendar.startOfDay(for: .now)
        _date = State(initialValue: storedDate)
        let startMinutes = editing?.startMinutes
        _hasTime = State(initialValue: startMinutes != nil)
        let hour = calendar.dateInterval(of: .hour, for: .now)?.end ?? .now
        _start = State(initialValue: startMinutes.map { Self.clockDate($0, on: storedDate) } ?? hour)
        _end = State(initialValue: (editing?.endMinutes ?? startMinutes).map { Self.clockDate($0, on: storedDate) } ?? hour)
        let weekday = calendar.component(.weekday, from: storedDate)
        let slots = term.slots
            .filter { $0.course?.token == course.token && $0.weekday == weekday }
        let choice: ExamTimeChoice
        if let startMinutes, let endMinutes = editing?.endMinutes,
           let slot = slots.first(where: { $0.startMinutes == startMinutes && $0.endMinutes == endMinutes }) {
            choice = .slot(slot.token)
        } else {
            choice = .other
        }
        _timeChoice = State(initialValue: choice)
        let place = PlacePreset.resolved(from: editing?.place ?? "")
        _placePreset = State(initialValue: place.0)
        _placeCustom = State(initialValue: place.1)
        _reminder = State(initialValue: ReminderKind(rawValue: editing?.reminderKind ?? "") ?? .none)
        let lead = editing?.leadDays ?? 1
        _leadDays = State(initialValue: min(max(lead, 0), 60))
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Kind", selection: $kind) {
                    ForEach(ExamKind.allCases, id: \.self) { item in
                        Text(item.title).tag(item)
                    }
                }
                if kind == .other {
                    TextField("Exam name", text: $title)
                }
                DatePicker("Date", selection: $date, displayedComponents: .date)
                Toggle("Set a time", isOn: $hasTime)
                if hasTime {
                    if !courseSlots.isEmpty {
                        Picker("Time", selection: $timeChoice) {
                            ForEach(courseSlots) { slot in
                                Text(slotLabel(slot)).tag(ExamTimeChoice.slot(slot.token))
                            }
                            Text("Other").tag(ExamTimeChoice.other)
                        }
                        .pickerStyle(.inline)
                    }
                    if courseSlots.isEmpty || timeChoice == .other {
                        DatePicker("Start", selection: $start, displayedComponents: .hourAndMinute)
                            .onChange(of: start) { _, newStart in
                                // The end opens on the start, the same way a new class time does.
                                end = newStart
                            }
                        DatePicker("End", selection: $end, displayedComponents: .hourAndMinute)
                    }
                }
                Picker("Place", selection: $placePreset) {
                    ForEach(PlacePreset.allCases) { preset in
                        Text(LocalizedStringKey(preset.menuTitle)).tag(preset)
                    }
                }
                .pickerStyle(.menu)
                if placePreset == .other {
                    TextField("Place name", text: $placeCustom)
                }
                Picker("Reminder", selection: $reminder) {
                    ForEach(ReminderKind.allCases, id: \.self) { item in
                        Text(item.title).tag(item)
                    }
                }
                if reminder != .none {
                    Stepper(value: $leadDays, in: 0...60) {
                        Text(String(format: String(localized: "%lld days before"), leadDays))
                    }
                }
                LabeledContent("Score") {
                    TextField("Out of 100", text: $scoreText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .onChange(of: scoreText) { _, newValue in
                            let clipped = Self.clippedScore(newValue)
                            if clipped != newValue { scoreText = clipped }
                        }
                }
            }
            .onChange(of: hasTime) { _, on in
                if on { applyDefaultTime() }
            }
            .onChange(of: date) { _, _ in
                keepTimeOnThisDay()
            }
            .onChange(of: timeChoice) { _, choice in
                if choice == .other { end = start }
            }
            .navigationTitle(editing == nil ? LocalizedStringKey("Add exam") : LocalizedStringKey("Edit exam"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(hasTime && selectedSlot == nil && minutes(end) <= minutes(start))
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() async {
        let sitting: ExamSitting
        if let editing {
            sitting = editing
            sitting.kind = kind.rawValue
            sitting.title = kind == .other ? title.trimmingCharacters(in: .whitespacesAndNewlines) : ""
            sitting.date = Calendar.current.startOfDay(for: date)
        } else {
            sitting = ExamSitting(
                course: course,
                kind: kind,
                title: kind == .other ? title.trimmingCharacters(in: .whitespacesAndNewlines) : "",
                date: Calendar.current.startOfDay(for: date)
            )
            modelContext.insert(sitting)
            course.sittings.append(sitting)
        }
        if hasTime {
            if let slot = selectedSlot {
                sitting.startMinutes = slot.startMinutes
                sitting.endMinutes = slot.endMinutes
            } else if minutes(end) > minutes(start) {
                sitting.startMinutes = minutes(start)
                sitting.endMinutes = minutes(end)
            }
        } else {
            sitting.startMinutes = nil
            sitting.endMinutes = nil
        }
        sitting.place = placePreset.storedName(custom: placeCustom)
        sitting.scoreText = Self.storedScore(scoreText)
        sitting.leadDays = leadDays
        if reminder == .none {
            sitting.reminderKind = ReminderKind.none.rawValue
        } else {
            let allowed = await ReminderScheduler.askPermission()
            sitting.reminderKind = allowed ? reminder.rawValue : ReminderKind.none.rawValue
        }
        ReminderScheduler.replaceExam(sitting, courseName: course.name)
        do {
            try modelContext.save()
            dismiss()
        } catch {
            Logger(subsystem: "app.bellnote", category: "exam").error(
                "Save failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// A time of day on the exam’s date, so the hour wheel opens on the saved clock.
    private static func clockDate(_ minutes: Int, on day: Date) -> Date {
        let calendar = Calendar.current
        var parts = calendar.dateComponents([.year, .month, .day], from: day)
        parts.hour = minutes / 60
        parts.minute = minutes % 60
        return calendar.date(from: parts) ?? day
    }

    /// Class hours of the chosen course that fall on the exam’s weekday. A Friday exam does not offer Thursday.
    private var courseSlots: [WeeklySlot] {
        let weekday = Calendar.current.component(.weekday, from: date)
        return term.slots
            .filter { $0.course?.token == course.token && $0.weekday == weekday }
            .sorted { $0.startMinutes < $1.startMinutes }
    }

    private var selectedSlot: WeeklySlot? {
        guard hasTime, case .slot(let token) = timeChoice else { return nil }
        return courseSlots.first { $0.token == token }
    }

    private func keepTimeOnThisDay() {
        guard hasTime else { return }
        if case .slot(let token) = timeChoice, courseSlots.contains(where: { $0.token == token }) {
            return
        }
        applyDefaultTime()
    }

    private func applyDefaultTime() {
        if let slot = courseSlots.first {
            timeChoice = .slot(slot.token)
        } else {
            timeChoice = .other
            end = start
        }
    }

    private func slotLabel(_ slot: WeeklySlot) -> String {
        "\(ReminderScheduler.clock(slot.startMinutes))–\(ReminderScheduler.clock(slot.endMinutes))"
    }

    private func minutes(_ date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    /// Digits only, at most 100. Anything past that stops at 100. Empty stays empty.
    private static func clippedScore(_ raw: String) -> String {
        let digits = raw.filter(\.isNumber)
        let clipped = String(digits.prefix(3))
        guard let number = Int(clipped) else { return "" }
        return number > 100 ? "100" : clipped
    }

    /// The stored score is the number itself, with no leading zeros. Empty means no result yet.
    private static func storedScore(_ raw: String) -> String {
        guard let number = Int(clippedScore(raw)), (0...100).contains(number) else { return "" }
        return String(number)
    }
}

/// A class time already on the course, or a start and end typed for this exam.
private enum ExamTimeChoice: Hashable {
    case slot(UUID)
    case other
}
