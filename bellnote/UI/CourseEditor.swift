import SwiftData
import SwiftUI

/// Changes a course of the term: its name and language, and every time it has in the timetable. A time opens the
/// same form as "Add slot", filled with its day, hours and place. The times are saved as soon as their form is
/// saved. The name and the language are saved with Save.
struct CourseEditor: View {
    @Bindable var course: Course
    var term: Term
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var language: AppLanguage
    @State private var editingSlot: WeeklySlot?
    @State private var addingSlot = false
    @State private var pendingDelete: WeeklySlot?

    init(course: Course, term: Term) {
        self.course = course
        self.term = term
        _name = State(initialValue: course.name)
        _language = State(initialValue: course.localeIdentifier.hasPrefix("tr") ? .turkish : .english)
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
            .alert(
                "Delete this time from the timetable?",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                )
            ) {
                Button("Delete", role: .destructive) {
                    if let slot = pendingDelete { modelContext.delete(slot) }
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
        let detail = slot.placeName.isEmpty ? span : "\(span) · \(slot.placeName)"
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: day)
                    .foregroundStyle(.primary)
                Text(verbatim: detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .contentShape(.rect)
    }

    private func save() {
        let oldName = course.name
        course.name = trimmedName
        if !languageIsLocked {
            course.localeIdentifier = language.speechLocaleIdentifier
        }
        // A reminder shows the name of the course, so the reminders of its times are made again with the new name.
        if oldName != course.name {
            for slot in slots {
                ReminderScheduler.replaceSlot(slot, courseName: course.name)
            }
        }
        dismiss()
    }
}
