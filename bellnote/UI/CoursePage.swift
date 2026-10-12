import SwiftData
import SwiftUI

struct CoursePage: View {
    @Bindable var course: Course
    @Environment(\.modelContext) private var modelContext
    @Environment(AppSession.self) private var session

    @State private var showConsent = false
    @State private var showRecorder = false
    @State private var showAssignments = false
    @State private var showStudy = false
    @State private var studyMode: StudyMode = .ask
    @State private var showLecturer = false
    @State private var showInventory = false
    @State private var activeLecture: Lecture?

    var body: some View {
        List {
            Section {
                Button {
                    showAssignments = true
                } label: {
                    Text(headline)
                        .font(.subheadline)
                }
                Text(attendanceLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Section("Lectures") {
                ForEach(lectures) { lecture in
                    NavigationLink {
                        LecturePage(lecture: lecture)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(lecture.startedAt.formatted(date: .abbreviated, time: .shortened))
                            Text(lecture.state)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Lecturer", isExpanded: $showLecturer) {
                if let contact = course.lecturer {
                    LecturerFields(contact: contact)
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
        .navigationTitle(course.name)
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                Button("Record", systemImage: "record.circle") {
                    beginRecord()
                }
            }
            ToolbarItem(placement: .bottomBar) {
                Picker("Study", selection: $studyMode) {
                    Text("Ask").tag(StudyMode.ask)
                    Text("Quiz").tag(StudyMode.quiz)
                }
                .pickerStyle(.segmented)
            }
            ToolbarItem(placement: .bottomBar) {
                Button("Speak", systemImage: "mic") { showStudy = true }
            }
        }
        .sheet(isPresented: $showConsent) {
            ConsentSheet(course: course) { faceID in
                startLecture(faceID: faceID)
            }
        }
        .sheet(item: $activeLecture) { lecture in
            RecorderSheet(lecture: lecture)
        }
        .sheet(isPresented: $showAssignments) {
            AssignmentSheet(course: course)
        }
        .sheet(isPresented: $showStudy) {
            StudySheet(course: course, mode: studyMode)
        }
        .onAppear(perform: ensureLecturer)
    }

    private var lectures: [Lecture] {
        course.lectures.sorted { $0.startedAt > $1.startedAt }
    }

    private var headline: String {
        let open = course.assignments.filter { !$0.done }.count
        if let exam = course.sittings.compactMap(\.date).sorted().first {
            return String(localized: "\(open) open · \(exam.formatted(date: .abbreviated, time: .omitted))")
        }
        return String(localized: "\(open) open")
    }

    private var attendanceLine: String {
        let recorded = course.lectures.filter { $0.state == LectureState.ready.rawValue }.count
        return String(localized: "\(recorded) recorded")
    }

    private func ensureLecturer() {
        guard course.lecturer == nil else { return }
        let created = LecturerContact()
        created.course = course
        course.lecturer = created
        modelContext.insert(created)
    }

    private func beginRecord() {
        showConsent = true
    }

    private func startLecture(faceID: Bool) {
        let lecture = Lecture(course: course)
        lecture.attestation = Attestation(
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
            faceIDSucceeded: faceID
        )
        if let attestation = lecture.attestation {
            modelContext.insert(attestation)
        }
        modelContext.insert(lecture)
        course.lectures.append(lecture)
        activeLecture = lecture
    }
}

struct LecturerFields: View {
    @Bindable var contact: LecturerContact

    var body: some View {
        TextField("Title", text: $contact.title)
        TextField("Given name", text: $contact.givenName)
        TextField("Family name", text: $contact.familyName)
        TextField("Phone", text: $contact.phone)
        TextField("Email", text: $contact.email)
        TextField("Other contact", text: $contact.extra)
    }
}
