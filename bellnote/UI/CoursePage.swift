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
                    statTile(value: course.assignments.filter { !$0.done }.count, title: "Assignments")
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
            }
            if !course.assignments.isEmpty {
                Section("Assignments") {
                    ForEach(course.assignments.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }) { assignment in
                        AssignmentRow(assignment: assignment)
                    }
                }
            }
            Section("Inventory", isExpanded: $showInventory) {
                if course.inventory.isEmpty {
                    Text("Nothing named in a lecture yet.")
                }
                ForEach(course.inventory) { item in
                    Text(item.title)
                }
            }
        }
        .listStyle(.insetGrouped)
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
        .onAppear(perform: ensureLecturer)
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
        let state = LectureState(rawValue: lecture.state)
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
                StatusChip(title: state?.title ?? lecture.state, tint: state?.tint ?? .gray)
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
