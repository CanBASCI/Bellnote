import SwiftData
import SwiftUI

struct TermHomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppSession.self) private var session
    @Query(sort: \Term.createdAt) private var terms: [Term]
    @Query(sort: \Lecture.startedAt, order: .reverse) private var lectures: [Lecture]
    @Query private var gaps: [LectureGap]

    @State private var segment = 0
    @State private var showTerm = false
    @State private var showCourse = false
    @State private var showTimetable = false
    @State private var showModels = false
    @State private var showSettings = false
    @State private var showPending = false
    @State private var nowCourse: Course?

    private var term: Term? { terms.first { $0.isOpen } ?? terms.last }

    var body: some View {
        NavigationStack {
            Group {
                if let term {
                    List {
                        if let pin = nowPin(in: term) {
                            Section {
                                Button(pin.courseName) { openNow(pin, in: term) }
                            } header: {
                                Text("Now")
                            }
                        }
                        Picker("Section", selection: $segment) {
                            Text("Courses").tag(0)
                            Text("Exams").tag(1)
                        }
                        .pickerStyle(.segmented)
                        .listRowSeparator(.hidden)
                        if segment == 0 {
                            courseSection(term)
                        } else {
                            examSection(term)
                        }
                    }
                    .listStyle(.insetGrouped)
                    .navigationTitle("Bellnote")
                } else {
                    ContentUnavailableView {
                        Text("Bellnote")
                    } description: {
                        Text("Create a term to keep courses and a timetable.")
                    } actions: {
                        Button("New term") { showTerm = true }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Pending", systemImage: "clock") { showPending = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("New term") { showTerm = true }
                        Button("Timetable") { showTimetable = true }
                        Button("Models") { showModels = true }
                        Button("Settings") { showSettings = true }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("New course", systemImage: "plus") { showCourse = true }
                        .disabled(term == nil)
                }
            }
            .navigationDestination(item: $nowCourse) { course in
                CoursePage(course: course)
            }
            .sheet(isPresented: $showTerm) { TermEditor(terms: terms) }
            .sheet(isPresented: $showCourse) {
                if let term { CourseEditor(term: term) }
            }
            .sheet(isPresented: $showTimetable) {
                if let term { TimetableSheet(term: term) }
            }
            .sheet(isPresented: $showModels) { ModelsSheet() }
            .sheet(isPresented: $showSettings) { SettingsSheet() }
            .sheet(isPresented: $showPending) { PendingSheet(lectures: pending) }
        }
    }

    private var pending: [Lecture] {
        lectures.filter { lecture in
            guard lecture.course?.term?.isOpen == true else { return false }
            return lecture.state == LectureState.processing.rawValue
                || lecture.state == LectureState.failed.rawValue
                || (lecture.state == LectureState.paused.rawValue && lecture.audioRelativePath != nil && lecture.stage == PipelineStage.idle.rawValue)
        }
    }

    @ViewBuilder
    private func courseSection(_ term: Term) -> some View {
        Section {
            ForEach(term.courses.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }) { course in
                NavigationLink(value: course) {
                    VStack(alignment: .leading) {
                        Text(course.name)
                        Text(courseSummary(course))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { offsets in
                let ordered = term.courses.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
                for index in offsets {
                    deleteCourse(ordered[index])
                }
            }
        }
        .navigationDestination(for: Course.self) { course in
            CoursePage(course: course)
        }
    }

    @ViewBuilder
    private func examSection(_ term: Term) -> some View {
        let rows = ExamSort.markingOverlaps(examRows(term))
        Section {
            if rows.isEmpty {
                Text("No exam dates yet.")
            }
            ForEach(rows) { row in
                VStack(alignment: .leading) {
                    Text(row.courseName)
                    Text(examLine(row))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if row.overlaps {
                        Text("Overlaps another sitting.")
                            .font(.footnote)
                    }
                }
            }
        }
    }

    private func courseSummary(_ course: Course) -> String {
        let open = course.assignments.filter { !$0.done }.count
        let nextExam = course.sittings.compactMap(\.date).sorted().first
        let gaps = noRecordingCount(course)
        var parts: [String] = []
        if let nextExam {
            parts.append(nextExam.formatted(date: .abbreviated, time: .omitted))
        }
        parts.append(String(localized: "\(open) open"))
        parts.append(String(localized: "\(gaps) without a recording"))
        return parts.joined(separator: " · ")
    }

    private func noRecordingCount(_ course: Course) -> Int {
        gaps.filter { $0.courseID == course.token && $0.mark != GapMark.cancelled.rawValue }.count
    }

    private func examRows(_ term: Term) -> [ExamRow] {
        term.courses.flatMap { course in
            course.sittings.map { sitting in
                ExamRow(
                    id: sitting.token,
                    courseName: course.name,
                    kind: sitting.kind,
                    date: sitting.date,
                    startMinutes: sitting.startMinutes,
                    endMinutes: sitting.endMinutes
                )
            }
        }
    }

    private func examLine(_ row: ExamRow) -> String {
        let date = row.date?.formatted(date: .abbreviated, time: .omitted) ?? String(localized: "Date not set")
        let time = row.startMinutes.map { ReminderScheduler.clock($0) } ?? String(localized: "Time not set")
        return "\(row.kind) · \(date) · \(time)"
    }

    private func nowPin(in term: Term) -> SlotClock? {
        let clocks = term.slots.compactMap { slot -> SlotClock? in
            guard let course = slot.course else { return nil }
            return SlotClock(
                id: UUID(),
                courseID: course.token,
                courseName: course.name,
                weekday: slot.weekday,
                startMinutes: slot.startMinutes,
                endMinutes: slot.endMinutes
            )
        }
        return NowPin.active(slots: clocks, at: .now).first
    }

    private func openNow(_ pin: SlotClock, in term: Term) {
        nowCourse = term.courses.first { $0.token == pin.courseID }
    }

    private func deleteCourse(_ course: Course) {
        do {
            try Vault.removeCourseDirectory(id: course.token)
            modelContext.delete(course)
        } catch {
            session.focusCourseToken = nil
        }
    }
}
