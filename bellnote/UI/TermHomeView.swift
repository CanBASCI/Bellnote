import OSLog
import SwiftData
import SwiftUI

struct TermHomeView: View {
    @Environment(AppSession.self) private var session
    @Query(sort: \Term.createdAt) private var terms: [Term]
    @Query(sort: \Lecture.startedAt, order: .reverse) private var lectures: [Lecture]

    @State private var showTerm = false
    @State private var showCourse = false
    @State private var showPending = false

    private var term: Term? { terms.first { $0.isOpen } ?? terms.last }

    var body: some View {
        Group {
            if let term {
                TabView {
                    NavigationStack {
                        TodayPage(term: term, showCourse: $showCourse, showPending: $showPending)
                    }
                    .tabItem { Label("Today", systemImage: "text.rectangle.page") }

                    NavigationStack {
                        ProgramPage(term: term)
                    }
                    .tabItem { Label("Timetable", systemImage: "calendar.day.timeline.left") }

                    NavigationStack {
                        CalendarPage(term: term)
                    }
                    .tabItem { Label("Calendar", systemImage: "calendar") }

                    NavigationStack {
                        SettingsPage(terms: terms)
                    }
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                }
                .tabBarMinimizeBehavior(.onScrollDown)
                .tabViewBottomAccessory(isEnabled: session.player != nil) {
                    if let player = session.player {
                        PlayerAccessory(audio: player)
                    }
                }
            } else {
                NavigationStack {
                    ContentUnavailableView {
                        Text("Bellnote")
                    } description: {
                        Text("Create a term to keep courses and a timetable.")
                    } actions: {
                        Button("New term") { showTerm = true }
                    }
                }
            }
        }
        .sheet(isPresented: $showTerm) { TermEditor(terms: terms) }
        .sheet(isPresented: $showCourse) {
            if let term { CourseEditor(term: term) }
        }
        .sheet(isPresented: $showPending) { PendingSheet(lectures: pending) }
    }

    private var pending: [Lecture] {
        lectures.filter { lecture in
            guard lecture.course?.term?.isOpen == true else { return false }
            return lecture.state == LectureState.processing.rawValue
                || lecture.state == LectureState.failed.rawValue
                || (lecture.state == LectureState.paused.rawValue && lecture.audioRelativePath != nil && lecture.stage == PipelineStage.idle.rawValue)
        }
    }
}

struct TodayPage: View {
    @Bindable var term: Term
    @Binding var showCourse: Bool
    @Binding var showPending: Bool

    @Environment(\.modelContext) private var modelContext
    @Environment(AppSession.self) private var session
    @State private var recordCourse: Course?
    @State private var showConsent = false
    @State private var activeLecture: Lecture?
    @State private var pendingCourse: Course?
    @State private var deleteNotice: String?

    var body: some View {
        List {
            if let slot = nextSlot {
                Section {
                    hero(slot)
                }
            }
            Section("Latest notes") {
                ForEach(orderedCourses) { course in
                    NavigationLink(value: course) {
                        noteRow(course)
                    }
                }
                .onDelete { offsets in
                    if let index = offsets.first { askDelete(orderedCourses[index]) }
                }
            }
            if !examRows.isEmpty {
                Section("Exams") {
                    ForEach(ExamSort.markingOverlaps(examRows)) { row in
                        VStack(alignment: .leading, spacing: 4) {
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
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Today")
        .navigationSubtitle(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)))
        .navigationDestination(for: Course.self) { course in
            CoursePage(course: course)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Pending", systemImage: "clock") { showPending = true }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("New course", systemImage: "plus") { showCourse = true }
                    .labelStyle(.iconOnly)
            }
        }
        .sheet(isPresented: $showConsent) {
            if let recordCourse {
                ConsentSheet(course: recordCourse) { faceID in
                    activeLecture = LectureStarter.make(course: recordCourse, faceID: faceID, context: modelContext)
                }
            }
        }
        .sheet(item: $activeLecture) { lecture in
            RecorderSheet(lecture: lecture)
        }
        .confirmationDialog(
            "Delete this course?",
            isPresented: Binding(
                get: { pendingCourse != nil },
                set: { if !$0 { pendingCourse = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let course = pendingCourse { deleteCourse(course) }
                pendingCourse = nil
            }
            Button("Cancel", role: .cancel) { pendingCourse = nil }
        } message: {
            Text("All recordings, notes, assignments and exams of this course will be deleted. This cannot be undone.")
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
    }

    private var orderedCourses: [Course] {
        term.courses.sorted { lhs, rhs in
            let left = lhs.lectures.map(\.startedAt).max() ?? .distantPast
            let right = rhs.lectures.map(\.startedAt).max() ?? .distantPast
            if left != right { return left > right }
            return lhs.name.localizedCompare(rhs.name) == .orderedAscending
        }
    }

    private var nextSlot: WeeklySlot? {
        let calendar = Calendar.current
        let now = Date.now
        let weekday = calendar.component(.weekday, from: now)
        let minutes = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        let slots = term.slots
        if let today = slots
            .filter({ $0.weekday == weekday && $0.endMinutes > minutes })
            .sorted(by: { $0.startMinutes < $1.startMinutes })
            .first {
            return today
        }
        for offset in 1...6 {
            let day = ((weekday - 1 + offset) % 7) + 1
            if let slot = slots.filter({ $0.weekday == day }).sorted(by: { $0.startMinutes < $1.startMinutes }).first {
                return slot
            }
        }
        return nil
    }

    private var examRows: [ExamRow] {
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

    @ViewBuilder
    private func hero(_ slot: WeeklySlot) -> some View {
        let soon = slot.weekday == Calendar.current.component(.weekday, from: .now)
        let name = slot.course?.name ?? String(localized: "Course")
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                CourseBadge(name: name, size: 28)
                Text(status(for: slot))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(soon ? Color.accentColor : Color.secondary)
            }
            Text(name)
                .font(.largeTitle.bold())
                .minimumScaleFactor(0.7)
                .lineLimit(2)
            Label(slotDetail(slot), systemImage: "clock")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let course = slot.course {
                Button {
                    recordCourse = course
                    showConsent = true
                } label: {
                    Label("Start recording", systemImage: "record.circle.fill")
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .tint(.red)
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 6)
    }

    private func noteRow(_ course: Course) -> some View {
        HStack(alignment: .top, spacing: 12) {
            CourseBadge(name: course.name)
            VStack(alignment: .leading, spacing: 3) {
                Text(course.name)
                    .font(.headline)
                Text(excerpt(course))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let meta = noteMeta(course) {
                    Text(meta)
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func status(for slot: WeeklySlot) -> String {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: .now)
        let minutes = calendar.component(.hour, from: .now) * 60 + calendar.component(.minute, from: .now)
        if slot.weekday == weekday, minutes >= slot.startMinutes, minutes < slot.endMinutes {
            return String(localized: "Now")
        }
        if slot.weekday == weekday, slot.startMinutes > minutes {
            let delta = slot.startMinutes - minutes
            if delta == 0 { return String(localized: "Now") }
            return String(format: String(localized: "%lld min later"), delta)
        }
        return weekdayName(slot.weekday)
    }

    private func slotDetail(_ slot: WeeklySlot) -> String {
        let span = "\(ReminderScheduler.clock(slot.startMinutes))–\(ReminderScheduler.clock(slot.endMinutes))"
        guard !slot.placeName.isEmpty else { return span }
        return "\(span) · \(slot.placeName)"
    }

    private func excerpt(_ course: Course) -> String {
        guard let lecture = course.lectures.max(by: { $0.startedAt < $1.startedAt }) else {
            return String(localized: "No lectures yet.")
        }
        let summary = lecture.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty { return MediaClock.sentence(CorrectionText.plain(summary)) }
        if let text = lecture.blocks.sorted(by: { $0.second < $1.second }).first(where: { !$0.text.isEmpty })?.text {
            return MediaClock.sentence(text)
        }
        return lecture.statusTitle
    }

    private func noteMeta(_ course: Course) -> String? {
        if let lecture = course.lectures.max(by: { $0.startedAt < $1.startedAt }) {
            let date = lecture.startedAt.formatted(date: .abbreviated, time: .omitted)
            guard lecture.recordedSeconds >= 60 else { return date }
            let minutes = String(format: String(localized: "%lld min"), lecture.recordedSeconds / 60)
            return "\(date) · \(minutes)"
        }
        guard let slot = term.slots.filter({ $0.course?.token == course.token }).sorted(by: { $0.startMinutes < $1.startMinutes }).first else {
            return nil
        }
        return "\(weekdayName(slot.weekday)) · \(ReminderScheduler.clock(slot.startMinutes))"
    }

    private func examLine(_ row: ExamRow) -> String {
        let date = row.date?.formatted(date: .abbreviated, time: .omitted) ?? String(localized: "Date not set")
        let time = row.startMinutes.map { ReminderScheduler.clock($0) } ?? String(localized: "Time not set")
        return "\(row.kind) · \(date) · \(time)"
    }

    private func weekdayName(_ day: Int) -> String {
        let symbols = Calendar.current.weekdaySymbols
        guard symbols.indices.contains(day - 1) else { return "" }
        return symbols[day - 1]
    }

    private func askDelete(_ course: Course) {
        guard course.lectures.allSatisfy(LectureRemoval.canDelete) else {
            deleteNotice = String(localized: "Wait until the recordings of this course have been processed, then delete it.")
            return
        }
        pendingCourse = course
    }

    private func deleteCourse(_ course: Course) {
        do {
            try Vault.removeCourseDirectory(id: course.token)
            modelContext.delete(course)
            if session.focusCourseToken == course.token { session.focusCourseToken = nil }
        } catch {
            Logger(subsystem: "app.bellnote", category: "delete").error(
                "Course delete failed: \(error.localizedDescription, privacy: .public)"
            )
            deleteNotice = String(localized: "The course could not be deleted.")
        }
    }
}
