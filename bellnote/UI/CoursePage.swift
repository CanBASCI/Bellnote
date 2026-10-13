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
            Section("Lectures") {
                if lectures.isEmpty {
                    Text("No lectures yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(lectures) { lecture in
                    NavigationLink {
                        LecturePage(lecture: lecture)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(lecture.startedAt.formatted(date: .abbreviated, time: .shortened))
                            Text(LectureState(rawValue: lecture.state)?.title ?? lecture.state)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Lecturer") {
                Button {
                    showLecturer = true
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(lecturerName)
                                .foregroundStyle(.primary)
                            if let detail = lecturerDetail {
                                Text(detail)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                        Text("Edit")
                            .font(.subheadline)
                            .foregroundStyle(.tint)
                    }
                }
                .buttonStyle(.plain)
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
        .navigationTitle(course.name)
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
        guard let contact = course.lecturer else { return String(localized: "Not set") }
        let parts = [contact.title, contact.givenName, contact.familyName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? String(localized: "Not set") : parts.joined(separator: " ")
    }

    private var lecturerDetail: String? {
        guard let contact = course.lecturer else { return nil }
        let parts = [contact.email, contact.phone]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var lectures: [Lecture] {
        course.lectures.sorted { $0.startedAt > $1.startedAt }
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
