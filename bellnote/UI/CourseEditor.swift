import OSLog
import SwiftData
import SwiftUI

/// Changes a course of the term: its name, language, and color, and every time it has in the timetable. A time
/// opens the same form as "Add slot", filled with its day, hours and place. The times are saved as soon as their
/// form is saved. Add exam starts a sitting for this course. An existing exam opens the form filled, and Save
/// updates that sitting. The name, the language, and the color are saved with Save.
struct CourseEditor: View {
    @Bindable var course: Course
    var term: Term
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var language: AppLanguage
    @State private var colorIndex: Int
    @State private var editingSlot: WeeklySlot?
    @State private var addingSlot = false
    @State private var pendingDelete: WeeklySlot?
    @State private var editingSitting: ExamSitting?
    @State private var addingExam = false

    init(course: Course, term: Term) {
        self.course = course
        self.term = term
        _name = State(initialValue: course.name)
        _language = State(initialValue: course.localeIdentifier.hasPrefix("tr") ? .turkish : .english)
        let count = CourseStyle.paletteCount
        let stored = course.colorIndex
        let initial = count > 0 && stored >= 0 ? stored % count : 0
        _colorIndex = State(initialValue: initial)
    }

    /// The language of a course with recordings does not change. Its recordings were made in that language.
    private var languageIsLocked: Bool { !course.lectures.isEmpty }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The times of this course, in the order of the week and then of the day.
    private var slots: [WeeklySlot] {
        let calendar = Calendar.current
        func position(_ slot: WeeklySlot) -> Int { (slot.weekday - calendar.firstWeekday + 7) % 7 }
        return term.slots
            .filter { $0.course?.token == course.token }
            .sorted { lhs, rhs in
                if position(lhs) != position(rhs) { return position(lhs) < position(rhs) }
                return lhs.startMinutes < rhs.startMinutes
            }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Course", text: $name)
                    Picker("Language", selection: $language) {
                        ForEach(AppLanguage.courseChoices, id: \.self) { item in
                            Text(LocalizedStringKey(item.title)).tag(item)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(languageIsLocked)
                } footer: {
                    if languageIsLocked {
                        Text("The language is fixed once a course has recordings.")
                    }
                }
                Section("Color") {
                    colorChoices
                }
                Section("Times") {
                    ForEach(slots) { slot in
                        Button {
                            editingSlot = slot
                        } label: {
                            slotRow(slot)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = slot }
                        }
                    }
                    Button("Add time", systemImage: "plus") { addingSlot = true }
                }
                Section("Exams") {
                    ForEach(sittings) { sitting in
                        Button {
                            editingSitting = sitting
                        } label: {
                            examRow(sitting)
                        }
                        .buttonStyle(.plain)
                    }
                    Button("Add exam", systemImage: "plus") { addingExam = true }
                }
            }
            .navigationTitle("Edit course")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(trimmedName.isEmpty)
                }
            }
            .sheet(item: $editingSlot) { slot in
                SlotEditor(term: term, weekday: slot.weekday, editing: slot)
            }
            .sheet(isPresented: $addingSlot) {
                SlotEditor(term: term, weekday: Calendar.current.component(.weekday, from: .now), course: course)
            }
            .sheet(item: $editingSitting) { sitting in
                ExamEditor(term: term, course: course, editing: sitting)
            }
            .sheet(isPresented: $addingExam) {
                ExamEditor(term: term, course: course)
            }
            .alert(
                "Delete this time from the timetable?",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                )
            ) {
                Button("Delete", role: .destructive) {
                    if let slot = pendingDelete {
                        modelContext.delete(slot)
                        commit()
                    }
                    pendingDelete = nil
                }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: {
                Text("The recordings of this course stay.")
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func slotRow(_ slot: WeeklySlot) -> some View {
        let symbols = Calendar.current.weekdaySymbols
        let day = symbols.indices.contains(slot.weekday - 1) ? symbols[slot.weekday - 1] : ""
        let span = "\(ReminderScheduler.clock(slot.startMinutes))–\(ReminderScheduler.clock(slot.endMinutes))"
        let place = PlacePreset.displayName(for: slot.placeName)
        let detail = place.isEmpty ? span : "\(span) · \(place)"
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: day)
                    .foregroundStyle(.primary)
                Text(verbatim: detail)
                    .appFont(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .appFont(.footnote, weight: .semibold)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .contentShape(.rect)
    }

    /// This course’s exams, earliest date first. One with no date stays last.
    private var sittings: [ExamSitting] {
        course.sittings.sorted { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
    }

    private func examRow(_ sitting: ExamSitting) -> some View {
        let day = sitting.date?.formatted(date: .abbreviated, time: .omitted) ?? String(localized: "Date not set")
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: examKindName(sitting))
                    .foregroundStyle(.primary)
                Text(verbatim: day)
                    .appFont(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .appFont(.footnote, weight: .semibold)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .contentShape(.rect)
    }

    /// Midterm, final, or the name typed for another exam.
    private func examKindName(_ sitting: ExamSitting) -> String {
        let title = sitting.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if ExamKind(rawValue: sitting.kind) == .other, !title.isEmpty { return title }
        switch ExamKind(rawValue: sitting.kind) {
        case .midterm: return String(localized: "Midterm")
        case .final: return String(localized: "Final")
        case .other: return String(localized: "Other")
        case nil: return String(localized: "Exam")
        }
    }

    /// The twelve course colors. The chosen one shows a check.
    private var colorChoices: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 4)], spacing: 4) {
            ForEach(0..<CourseStyle.paletteCount, id: \.self) { index in
                Button {
                    colorIndex = index
                } label: {
                    Circle()
                        .fill(CourseStyle.color(at: index, fallbackName: trimmedName))
                        .frame(width: 28, height: 28)
                        .overlay {
                            if colorIndex == index {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(CourseStyle.paletteTitle(at: index)))
                .accessibilityAddTraits(colorIndex == index ? .isSelected : [])
            }
        }
    }

    private func save() {
        let oldName = course.name
        course.name = trimmedName
        if !languageIsLocked {
            course.localeIdentifier = language.speechLocaleIdentifier
        }
        course.colorIndex = colorIndex
        // A reminder shows the name of the course, so the reminders of its times are made again with the new name.
        if oldName != course.name {
            for slot in slots {
                ReminderScheduler.replaceSlot(slot, courseName: course.name)
            }
        }
        commit()
        dismiss()
    }

    /// Writes the course fields. A time or an exam is already written by its own sheet.
    private func commit() {
        do {
            try modelContext.save()
        } catch {
            Logger(subsystem: "app.bellnote", category: "course").error(
                "Save failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
