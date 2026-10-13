import OSLog
import SwiftData
import SwiftUI

enum LectureStarter {
    @MainActor
    static func make(course: Course, faceID: Bool, context: ModelContext) -> Lecture {
        let lecture = Lecture(course: course)
        let attestation = Attestation(
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
            faceIDSucceeded: faceID
        )
        lecture.attestation = attestation
        context.insert(attestation)
        context.insert(lecture)
        course.lectures.append(lecture)
        return lecture
    }
}

struct CoursePage: View {
    @Bindable var course: Course
    @Environment(\.modelContext) private var modelContext

    @State private var showConsent = false
    @State private var activeLecture: Lecture?
    @State private var showLecturer = false
    @State private var showInventory = false
    @State private var assignmentTarget: AssignmentTarget?
    @State private var pendingDelete: Lecture?
    @State private var pendingItem: InventoryItem?
    @State private var pendingAssignment: Assignment?
    @State private var deleteNotice: String?

    var body: some View {
        List {
            Section {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(course.name)
                        .font(.largeTitle.bold())
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 8)
                    Button {
                        showLecturer = true
                    } label: {
                        Text(lecturerName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                            .lineLimit(2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Lecturer"))
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 4, trailing: 20))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            Section {
                HStack(spacing: 10) {
                    statTile(value: lectures.count, title: "Recordings")
                    statTile(value: course.assignments.filter { !$0.done && !$0.cancelled }.count, title: "Assignments")
                    statTile(value: course.sittings.count, title: "Exams")
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            Section("Lectures") {
                if lectures.isEmpty {
                    Text("No lectures yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(lectures) { lecture in
                    NavigationLink {
                        LecturePage(lecture: lecture)
                    } label: {
                        lectureRow(lecture)
                    }
                }
                .onDelete { offsets in
                    if let index = offsets.first { askDelete(lectures[index]) }
                }
            }
            if !course.assignments.isEmpty {
                Section("Assignments") {
                    let sorted = course.assignments.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
                    ForEach(sorted) { assignment in
                        AssignmentRow(assignment: assignment) { second in
                            guard let lecture = assignment.sourceLecture else { return }
                            assignmentTarget = AssignmentTarget(lecture: lecture, second: second)
                        }
                    }
                    .onDelete { offsets in
                        pendingAssignment = offsets.first.map { sorted[$0] }
                    }
                }
            }
            // Nothing fills the inventory yet, so the section shows only when a row exists.
            if !course.inventory.isEmpty {
                Section("Inventory", isExpanded: $showInventory) {
                    ForEach(course.inventory) { item in
                        Text(item.title)
                    }
                    .onDelete { offsets in
                        pendingItem = offsets.first.map { course.inventory[$0] }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .confirmAssignmentDelete($pendingAssignment)
        .navigationDestination(item: $assignmentTarget) { target in
            LecturePage(lecture: target.lecture, startSecond: target.second)
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Record", systemImage: "record.circle") { showConsent = true }
            }
        }
        .sheet(isPresented: $showConsent) {
            ConsentSheet(course: course) { faceID in
                activeLecture = LectureStarter.make(course: course, faceID: faceID, context: modelContext)
            }
        }
        .sheet(item: $activeLecture) { lecture in
            RecorderSheet(lecture: lecture)
        }
        .sheet(isPresented: $showLecturer) {
            if let contact = course.lecturer {
                LecturerEditor(contact: contact)
            }
        }
        .confirmationDialog(
            "Delete this recording?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let lecture = pendingDelete { delete(lecture) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("The audio, the notes and the assignments from this recording will be deleted. This cannot be undone.")
        }
        .confirmationDialog(
            "Delete this item?",
            isPresented: Binding(
                get: { pendingItem != nil },
                set: { if !$0 { pendingItem = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let item = pendingItem { modelContext.delete(item) }
                pendingItem = nil
            }
            Button("Cancel", role: .cancel) { pendingItem = nil }
        } message: {
            Text("It is removed from the list. The recording stays.")
        }
        .alert(
            deleteNotice ?? "",
            isPresented: Binding(
                get: { deleteNotice != nil },
                set: { if !$0 { deleteNotice = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        }
        .onAppear(perform: ensureLecturer)
    }

    private func askDelete(_ lecture: Lecture) {
        guard LectureRemoval.canDelete(lecture) else {
            deleteNotice = String(localized: "Wait until this recording has been processed, then delete it.")
            return
        }
        pendingDelete = lecture
    }

    private func delete(_ lecture: Lecture) {
        do {
            try LectureRemoval.delete(lecture, context: modelContext)
        } catch {
            Logger(subsystem: "app.bellnote", category: "delete").error(
                "Lecture delete failed: \(error.localizedDescription, privacy: .public)"
            )
            deleteNotice = String(localized: "The recording could not be deleted.")
        }
    }

    private var lecturerName: String {
        guard let contact = course.lecturer else { return String(localized: "Lecturer") }
        let parts = [contact.title, contact.givenName, contact.familyName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? String(localized: "Lecturer") : parts.joined(separator: " ")
    }

    private var lectures: [Lecture] {
        course.lectures.sorted { $0.startedAt > $1.startedAt }
    }

    private func statTile(value: Int, title: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value, format: .number)
                .font(.title2.weight(.bold).monospacedDigit())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func lectureRow(_ lecture: Lecture) -> some View {
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(lecture.startedAt.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                    .font(.headline)
                if lecture.recordedSeconds >= 60 {
                    Text(String(format: String(localized: "%lld min"), lecture.recordedSeconds / 60))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                StatusChip(title: lecture.statusTitle, tint: lecture.statusTint)
            }
            let excerpt = preview(lecture)
            if !excerpt.isEmpty {
                Text(excerpt)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private func preview(_ lecture: Lecture) -> String {
        let summary = lecture.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return "" }
        return CorrectionText.plain(summary)
    }

    private func ensureLecturer() {
        guard course.lecturer == nil else { return }
        let created = LecturerContact()
        created.course = course
        course.lecturer = created
        modelContext.insert(created)
    }
}

struct LecturerEditor: View {
    @Bindable var contact: LecturerContact
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $contact.title)
                TextField("Given name", text: $contact.givenName)
                TextField("Family name", text: $contact.familyName)
                TextField("Phone", text: $contact.phone)
                TextField("Email", text: $contact.email)
                TextField("Other contact", text: $contact.extra)
            }
            .navigationTitle("Lecturer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
