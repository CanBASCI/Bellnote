import OSLog
import SwiftData
import SwiftUI
import UIKit

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

    /// Stores a file the student already recorded as a lecture that was just stopped. Process reads it the same way.
    @MainActor
    static func importAudio(course: Course, faceID: Bool, from source: URL, context: ModelContext) throws {
        let lecture = make(course: course, faceID: faceID, context: context)
        do {
            let stored = try Vault.importLectureAudio(courseID: course.token, startedAt: lecture.startedAt, from: source)
            lecture.audioRelativePath = stored.relativePath
            lecture.recordedSeconds = stored.seconds
            lecture.state = LectureState.paused.rawValue
            lecture.stage = PipelineStage.idle.rawValue
            try context.save()
        } catch {
            if let path = lecture.audioRelativePath {
                do {
                    try Vault.removeStoredFile(relativePath: path)
                } catch {
                    Logger(subsystem: "app.bellnote", category: "capture").error(
                        "Imported audio could not be removed: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            context.delete(lecture)
            do {
                try context.save()
            } catch {
                Logger(subsystem: "app.bellnote", category: "capture").error(
                    "Imported lecture could not be removed: \(error.localizedDescription, privacy: .public)"
                )
            }
            throw error
        }
    }
}

/// One line under a count tile. The symbol and the word lead. The value sits at the trailing end.
/// A zero count is quiet. A past exam strikes the day and time. The kind stays plain.
private struct StatDetail: Identifiable, Hashable {
    let id: String
    let symbol: String
    let label: String
    let value: String
    let quiet: Bool
    var struck: Bool = false
}

/// Ask → Source hand-off: recording plus the Raw block to open, kept in one value for the push.
private struct AskSourceJump: Identifiable, Hashable {
    var id: UUID { blockToken }
    var lecture: Lecture
    var blockToken: UUID
    var second: Int

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.blockToken == rhs.blockToken && lhs.second == rhs.second
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(blockToken)
        hasher.combine(second)
    }
}

struct CoursePage: View {
    /// Where a Talk source should land inside this course.
    enum Focus: Hashable {
        case assignment(PersistentIdentifier)
        case inventory(PersistentIdentifier)
        case lecturer
    }

    @Bindable var course: Course
    var focus: Focus?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.locale) private var locale
    @State private var showConsent = false
    @State private var activeLecture: Lecture?
    @State private var showLecturer = false
    @State private var showAsk = false
    @State private var showInventory: Bool
    @State private var pendingDelete: Lecture?
    @State private var pendingItem: InventoryItem?
    @State private var pendingAssignment: Assignment?
    @State private var deleteNotice: String?
    /// Which list the page shows under the tiles. Recordings first; a hand-off to an assignment opens the other one.
    @State private var pane: Pane
    private enum Pane: Hashable {
        case recordings
        case assignments
    }
    /// A hand-off from Talk can name a week. The page scrolls to it; every week is on the page.
    private let initialWeek: Date?

    init(course: Course, weekStart: Date? = nil, focus: Focus? = nil) {
        self.course = course
        self.focus = focus
        self.initialWeek = weekStart
        if case .assignment = focus {
            _pane = State(initialValue: .assignments)
        } else {
            _pane = State(initialValue: .recordings)
        }
        if case .inventory = focus {
            _showInventory = State(initialValue: true)
        } else {
            _showInventory = State(initialValue: false)
        }
    }
    /// Ask → Source: one value so the push cannot lose the block token.
    @State private var askSourceJump: AskSourceJump?

    private func statList(_ proxy: ScrollViewProxy) -> some View {
        List {
            Section {
                // The tiles are the first row of the list, not a section header. A header of a plain list stays
                // at the top while the list scrolls. A row takes the side space of the other rows by itself.
                // No glass container here: it fuses neighbours and rounds their outer corners.
                // The tiles are squares in a row that scrolls sideways, like the cards of the App Store. The one
                // that does not fit on the screen is swiped into view, and the scroll stops on a tile.
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        statTile(value: visibleLectures.count, title: "Recordings", tint: CourseStyle.recordingsTint, details: lectureBreakdown(of: visibleLectures)) {
                            pane = .recordings
                        }
                        statTile(value: visibleAssignments.count, title: "Assignments", tint: CourseStyle.assignmentsTint, details: assignmentBreakdown(of: visibleAssignments)) {
                            pane = .assignments
                        }
                        statTile(value: visibleSittings.count, title: "Exams", tint: CourseStyle.examsTint, details: examLines(of: visibleSittings))
                    }
                    .scrollTargetLayout()
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.viewAligned)
                // The row has no side space, so the tiles can slide out to the screen edge. This margin puts the
                // first tile where the other rows start.
                .contentMargins(.horizontal, 16, for: .scrollContent)
                // A scroll view cuts off what is drawn outside of it. The glass of a tile casts a soft shade around
                // it, so the scroll view must not clip, and it keeps a little room above and below for that shade.
                .scrollClipDisabled()
                .contentMargins(.top, 8, for: .scrollContent)
                .contentMargins(.bottom, 4, for: .scrollContent)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                // No space under the tiles from the row itself, so the gap to the "This week" title is only the
                // top space of that title.
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            }
            // One segmented control picks the list: recordings, or assignments. Recordings are the default.
            Section {
                Picker("List", selection: $pane) {
                    Text("Recordings").tag(Pane.recordings)
                    Text("Assignments").tag(Pane.assignments)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 4, trailing: 16))
            }
            if pane == .recordings {
                // Every week is on the page, newest first. A header names the week, so no date has to be picked.
                if lectureWeeks.isEmpty {
                    Section {
                        Text("No lectures yet.")
                            .foregroundStyle(.secondary)
                            .id(Self.emptyLecturesID)
                    } header: {
                        Text(verbatim: weekTitle(Self.currentWeekStart))
                    }
                }
                ForEach(lectureWeeks, id: \.start) { week in
                    Section {
                        ForEach(week.lectures) { lecture in
                            NavigationLink {
                                LecturePage(lecture: lecture)
                            } label: {
                                lectureRow(lecture)
                            }
                            .askToDeleteSwipe { askDelete(lecture) }
                            // Top and bottom only. The side space stays the one the list gives. Each row has 8 pt above and
                            // 8 pt under it.
                            .listRowInsets(.vertical, 8)
                        }
                    } header: {
                        Text(verbatim: weekTitle(week.start))
                    }
                }
            } else {
                Section {
                    if visibleAssignments.isEmpty {
                        Text("No assignments yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(visibleAssignments) { assignment in
                        // The same row as the assignments of a recording: the same fonts, circle and spaces.
                        assignmentLink(assignment)
                            .askToDeleteSwipe { pendingAssignment = assignment }
                    }
                }
            }
            // Nothing fills the inventory yet, so the section shows only when a row exists.
            if !course.inventory.isEmpty {
                Section("Inventory", isExpanded: $showInventory) {
                    ForEach(course.inventory) { item in
                        Text(item.title)
                            .id(item.persistentModelID)
                            .askToDeleteSwipe { pendingItem = item }
                    }
                }
            }
        }
        // A plain list, like the lists of Apple Music: no rounded groups, rows run from edge to edge.
        .listStyle(.plain)
        // Space between the navigation bar and the tiles. A Spacer does not work in a list, the margin of the
        // scroll content does, and it scrolls away with the list.
        .contentMargins(.top, 16, for: .scrollContent)
    }

    /// A task with a recording is a link to it, so the list draws its arrow. The row itself is the same as the
    /// one in the assignments of a recording.
    @ViewBuilder
    private func assignmentLink(_ assignment: Assignment) -> some View {
        // The task text keeps the size it had here: `subheadline`, medium. The circle is centered in the column of
        // the date covers of the recordings above, and the task text starts where the text of a recording starts.
        let row = AssignmentRow(
            assignment: assignment,
            markWidth: Self.coverSize,
            markGap: Self.coverGap,
            smallTitle: true,
            onOpen: nil
        )
        if let lecture = assignment.sourceLecture {
            NavigationLink {
                LecturePage(lecture: lecture, startSecond: assignment.sourceSecond)
            } label: {
                row
            }
        } else {
            row
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            statList(proxy)
                .task {
                    // A hand-off that names a week and no item lands on the first recording of that week.
                    guard focus == nil, let initialWeek,
                          let first = lectureWeeks.first(where: { $0.start == initialWeek })?.lectures.first else { return }
                    try? await Task.sleep(for: .milliseconds(350))
                    proxy.scrollTo(first.id, anchor: .top)
                }
                .task(id: focus) {
                    guard let focus else { return }
                    try? await Task.sleep(for: .milliseconds(350))
                    switch focus {
                    case .assignment(let id):
                        proxy.scrollTo(id, anchor: .center)
                    case .inventory(let id):
                        proxy.scrollTo(id, anchor: .center)
                    case .lecturer:
                        showLecturer = true
                    }
                }
        }
        .confirmAssignmentDelete($pendingAssignment)
        .navigationTitle(course.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // The course name with the lecturer under it. Tapping it opens the lecturer's details, the one place they
            // are entered. A principal item is used because a plain title cannot be tapped.
            ToolbarItem(placement: .principal) {
                Button {
                    showLecturer = true
                } label: {
                    VStack(spacing: 0) {
                        // The small arrow after the name tells that it can be tapped, like the arrow of a title menu.
                        HStack(spacing: 4) {
                            Text(verbatim: course.name)
                                .appFont(.headline)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                        Text(verbatim: lecturerName)
                            .appFont(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: 220)
                }
                .buttonStyle(.plain)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .topBarTrailing) {
                // Ask about all the recordings of this course. The Ask inside a recording uses only that recording.
                Button("Ask", systemImage: "sparkles") { showAsk = true }
                    .labelStyle(.iconOnly)
            }
            // The sample weeks menu is off. Remove the comment marks to see it again in debug builds.
            // #if DEBUG
            // ToolbarItem(placement: .topBarTrailing) {
            //     debugMenu
            // }
            // #endif
            ToolbarItem(placement: .primaryAction) {
                Button("Record", systemImage: "record.circle") { showConsent = true }
                    .consentFlow(course: course, asPopover: true, isPresented: $showConsent) { course, faceID in
                        activeLecture = LectureStarter.make(course: course, faceID: faceID, context: modelContext)
                    }
            }
        }
        .sheet(item: $activeLecture) { lecture in
            RecorderSheet(lecture: lecture)
        }
        .sheet(isPresented: $showAsk) {
            StudySheet(course: course) { host, blockToken, second in
                // After the Ask sheet closes, so the push is not eaten by the dismiss animation.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    askSourceJump = AskSourceJump(lecture: host, blockToken: blockToken, second: second)
                }
            }
        }
        .navigationDestination(item: $askSourceJump) { jump in
            LecturePage(
                lecture: jump.lecture,
                startSecond: jump.second,
                focusRawBlockToken: jump.blockToken
            )
        }
        .sheet(isPresented: $showLecturer) {
            if let contact = course.lecturer {
                LecturerEditor(contact: contact)
            }
        }
        .alert(
            "Delete this recording?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let lecture = pendingDelete { delete(lecture) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("The audio, the notes and the assignments from this recording will be deleted. This cannot be undone.")
        }
        .alert(
            "Delete this item?",
            isPresented: Binding(
                get: { pendingItem != nil },
                set: { if !$0 { pendingItem = nil } }
            )
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

    #if DEBUG
    /// Debug builds only: past weeks of made-up recordings, to see how a long list looks.
    private var debugMenu: some View {
        Menu {
            Button { addSampleWeeks() } label: { Text(verbatim: "Add sample past weeks (debug)") }
            Button(role: .destructive) { removeSampleWeeks() } label: { Text(verbatim: "Remove samples (debug)") }
        } label: {
            Image(systemName: "ladybug")
        }
        .accessibilityLabel(Text(verbatim: "Debug"))
    }
    #endif

    #if DEBUG
    /// Debug builds only. These recordings carry a fixed title, so they can be told apart and removed again.
    private static let sampleTitle = "Sample (debug)"

    private func addSampleWeeks() {
        let calendar = Calendar.current
        for weeksAgo in 1...5 {
            for index in 0..<(weeksAgo % 3 + 1) {
                guard let weekDate = calendar.date(byAdding: .weekOfYear, value: -weeksAgo, to: .now),
                      let date = calendar.date(byAdding: .day, value: -index, to: weekDate) else { continue }
                let lecture = Lecture(course: course, startedAt: date, title: Self.sampleTitle)
                lecture.state = LectureState.ready.rawValue
                lecture.stage = PipelineStage.ready.rawValue
                modelContext.insert(lecture)
                course.lectures.append(lecture)
            }
        }
        saveSamples()
    }

    private func removeSampleWeeks() {
        for lecture in course.lectures where lecture.title == Self.sampleTitle {
            modelContext.delete(lecture)
        }
        saveSamples()
    }

    private func saveSamples() {
        do {
            try modelContext.save()
        } catch {
            Logger(subsystem: "app.bellnote", category: "debug").error(
                "Sample recordings could not be saved: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
    #endif

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

    /// Recordings grouped by calendar week, newest week first, newest recording first inside a week.
    private var lectureWeeks: [(start: Date, lectures: [Lecture])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: lectures) { lecture in
            calendar.dateInterval(of: .weekOfYear, for: lecture.startedAt)?.start ?? lecture.startedAt
        }
        return groups
            .map { (start: $0.key, lectures: $0.value) }
            .sorted { $0.start > $1.start }
    }

    private func weekTitle(_ start: Date) -> String {
        let calendar = Calendar.current
        let now = Date()
        if let current = calendar.dateInterval(of: .weekOfYear, for: now)?.start {
            if start == current { return String(localized: "This week") }
            if let previous = calendar.date(byAdding: .weekOfYear, value: -1, to: current), start == previous {
                return String(localized: "Last week")
            }
        }
        let end = calendar.date(byAdding: .day, value: 6, to: start) ?? start
        let first = start.formatted(.dateTime.day().month(.abbreviated))
        let last = end.formatted(.dateTime.day().month(.abbreviated))
        return "\(first) – \(last)"
    }

    /// One row per recording status. The count sits at the trailing end.
    private func lectureBreakdown(of lectures: [Lecture]) -> [StatDetail] {
        let processed = lectures.filter { !$0.isRecordedOnly }
        func count(_ state: LectureState) -> Int {
            processed.filter { $0.state == state.rawValue }.count
        }
        let recorded = lectures.filter(\.isRecordedOnly).count
        let entries: [(symbol: String, title: String, count: Int)] = [
            (LectureState.ready.symbol, LectureState.ready.title, count(.ready)),
            ("waveform", String(localized: "Recorded"), recorded),
            (LectureState.processing.symbol, LectureState.processing.title, count(.processing)),
            (LectureState.failed.symbol, LectureState.failed.title, count(.failed)),
            (LectureState.recording.symbol, LectureState.recording.title, count(.recording)),
            (LectureState.paused.symbol, LectureState.paused.title, count(.paused))
        ]
        // Every status always shows, even at 0, so the tile has the same number of lines at all times.
        return entries.map { entry in
            StatDetail(
                id: entry.symbol + entry.title,
                symbol: entry.symbol,
                label: entry.title,
                value: entry.count.formatted(.number),
                quiet: entry.count == 0
            )
        }
    }

    /// Done, cancelled and pending assignments. The big number on the tile is the total of all three.
    private func assignmentBreakdown(of assignments: [Assignment]) -> [StatDetail] {
        let pending = assignments.filter { !$0.done && !$0.cancelled }.count
        let done = assignments.filter { $0.done && !$0.cancelled }.count
        let cancelled = assignments.filter(\.cancelled).count
        return [
            StatDetail(id: "done", symbol: "checkmark.circle", label: String(localized: "Done"), value: done.formatted(.number), quiet: done == 0),
            StatDetail(id: "cancelled", symbol: "xmark.circle", label: String(localized: "Cancelled"), value: cancelled.formatted(.number), quiet: cancelled == 0),
            StatDetail(id: "pending", symbol: "circle", label: String(localized: "Pending"), value: pending.formatted(.number), quiet: pending == 0)
        ]
    }

    /// One line per exam on the card: its kind, then the day and month. A set start time follows, as in “27 Oct · 09:00”.
    /// The nearest sitting is first.
    private func examLines(of sittings: [ExamSitting]) -> [StatDetail] {
        nearestFirst(sittings)
            .map { sitting in
                return StatDetail(
                    id: sitting.token.uuidString,
                    symbol: "calendar",
                    label: examKindName(sitting),
                    value: examWhen(sitting),
                    quiet: false,
                    struck: examIsPast(sitting)
                )
            }
    }

    /// The same order as the home exam list: today or later, soonest first, then past dates, the latest of those first.
    private func nearestFirst(_ sittings: [ExamSitting]) -> [ExamSitting] {
        let rows = sittings.map { sitting in
            ExamRow(
                id: sitting.token,
                courseName: course.name,
                kind: sitting.kind,
                title: sitting.title,
                date: sitting.date,
                startMinutes: sitting.startMinutes,
                endMinutes: sitting.endMinutes
            )
        }
        let byToken = Dictionary(uniqueKeysWithValues: sittings.map { ($0.token, $0) })
        return ExamSort.ordered(rows).compactMap { byToken[$0.id] }
    }

    /// A sitting whose day is before today. Today stays open.
    private func examIsPast(_ sitting: ExamSitting) -> Bool {
        guard let date = sitting.date else { return false }
        let calendar = Calendar.current
        return calendar.startOfDay(for: date) < calendar.startOfDay(for: .now)
    }

    /// Day and month, then the start time when one is set. No year, so the kind still fits on the line.
    private func examWhen(_ sitting: ExamSitting) -> String {
        guard let date = sitting.date else { return String(localized: "Date not set") }
        let day = date.formatted(.dateTime.day().month(.abbreviated).locale(locale))
        guard let start = sitting.startMinutes else { return day }
        return "\(day) · \(ReminderScheduler.clock(start))"
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

    /// Assignments in the order the list shows them: by due date, undated ones last.
    private var sortedAssignments: [Assignment] {
        course.assignments.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
    }

    /// The first day of this week. A new recording always lands in this week.
    private static var currentWeekStart: Date {
        Calendar.current.dateInterval(of: .weekOfYear, for: .now)?.start ?? .now
    }

    /// Every recording of the course, newest first. The tiles count all of them.
    private var visibleLectures: [Lecture] { lectures }

    /// Every assignment of the course, by due date.
    private var visibleAssignments: [Assignment] { sortedAssignments }

    /// Every sitting of this course through the end of its term. The week of the lecture list does not apply.
    private var visibleSittings: [ExamSitting] {
        let calendar = Calendar.current
        guard let end = course.term.map({ calendar.startOfDay(for: $0.endsOn) }) else {
            return course.sittings
        }
        return course.sittings.filter { sitting in
            guard let date = sitting.date else { return true }
            return calendar.startOfDay(for: date) <= end
        }
    }

    private static let emptyLecturesID = "emptyLectures"
    /// The date cover of a recording and the space between it and the text. The separator line starts after both.
    private static let coverSize: CGFloat = 48
    private static let coverGap: CGFloat = 12
    /// The height of the digits of the time text (`subheadline`, at the default Dynamic Type size). It grows with the
    /// text size the student chose. The status symbol is at most this tall. This is the height of the capital
    /// letters, not the height of the whole line.
    @ScaledMetric(relativeTo: .subheadline) private var timeDigitHeight: CGFloat = UIFont.preferredFont(
        forTextStyle: .subheadline,
        compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
    ).capHeight
    /// The side of a tile. The tile is a square. The Recordings tile lists six statuses at all times (Ready,
    /// Recorded, Processing, Failed, Recording and Paused), and this is tall enough for them. It grows with the text
    /// size the student chose.
    @ScaledMetric(relativeTo: .footnote) private var tileSide: CGFloat = 180
    /// A tile is a button when it has an action, so a tap can take the student to its list.
    @ViewBuilder
    private func statTile(value: Int, title: LocalizedStringKey, tint: Color, details: [StatDetail] = [], action: (() -> Void)? = nil) -> some View {
        if let action {
            Button(action: action) {
                statTileBody(value: value, title: title, tint: tint, details: details)
            }
            .buttonStyle(.plain)
        } else {
            statTileBody(value: value, title: title, tint: tint, details: details)
        }
    }

    private func statTileBody(value: Int, title: LocalizedStringKey, tint: Color, details: [StatDetail]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // The same fonts as the recording rows: the title like the time. The lines are `footnote`, like the
            // lines of the cards on Home.
            // The total sits at the right end of the title line.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .appFont(.headline)
                    // No shrinking. Every title has the same size on every tile.
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(value, format: .number)
                    .appFont(.title3, weight: .bold, digits: true)
            }
            // White on the color, like the date covers of the recordings. White reads on the color in light and dark
            // mode. Only this line has a color. The tile itself is plain glass.
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            // Concentric with the tile: the tile corner (22) minus the tile padding (12).
            .background(tint, in: .rect(cornerRadius: 10, style: .continuous))
            // The gap between the colored line and the details. The line itself takes the place of the empty line.
            .padding(.bottom, 6)
            ForEach(details) { line in
                statDetailRow(line)
            }
        }
        .padding(12)
        // A square. Every tile has the same side, whatever it lists.
        .frame(width: tileSide, height: tileSide, alignment: .topLeading)
        // Plain glass with no color, the same as the course cards on Home. The glass is a background, not a modifier
        // of the texts. Otherwise the glass changes the text colors.
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.clear)
                .glassEffect(.regular, in: .rect(cornerRadius: 22))
        }
        .contentShape(.rect(cornerRadius: 22))
        .accessibilityElement(children: .combine)
    }

    /// Symbol, word, then the value at the trailing end. A zero count is secondary.
    private func statDetailRow(_ line: StatDetail) -> some View {
        HStack(alignment: .center, spacing: 6) {
            // A narrow symbol such as pause would pull its word to the left. Every symbol uses the same width.
            Image(systemName: line.symbol)
                .frame(width: 18, alignment: .center)
                .accessibilityHidden(true)
            Text(verbatim: line.label)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(verbatim: line.value)
                .appFont(.footnote, digits: true)
                .layoutPriority(1)
                .strikethrough(line.struck)
                .foregroundStyle(line.quiet || line.struck ? Color.secondary : Color.primary)
        }
        .appFont(.footnote)
        .foregroundStyle(line.quiet ? Color.secondary : Color.primary)
    }

    private func lectureRow(_ lecture: Lecture) -> some View {
        // The day is the cover on the left, like the cover of a song in Apple Music. The title is the time of day.
        let separatorStart = Self.coverSize + Self.coverGap
        return HStack(spacing: Self.coverGap) {
            DateCover(date: lecture.startedAt, color: course.color, size: Self.coverSize, outlined: true)
                .accessibilityValue(Text(lecture.statusTitle))
            // The time and the length on the first line, the summary under them.
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(lecture.startedAt.formatted(.dateTime.hour().minute().locale(locale)))
                        .appFont(.subheadline, weight: .medium)
                        .foregroundStyle(.secondary)
                    Image(systemName: lecture.statusSymbol)
                        // The same weight as the time. The symbol is scaled so that it is at most as tall as the digits
                        // of the time. A wide symbol is lower than that, it never goes above it.
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: timeDigitHeight)
                        .appFont(.subheadline, weight: .medium)
                        .foregroundStyle(.secondary)
                        // The cover already tells the status to VoiceOver.
                        .accessibilityHidden(true)
                    if lecture.recordedSeconds >= 60 {
                        Text(String(format: String(localized: "%lld min"), lecture.recordedSeconds / 60))
                            .appFont(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                let excerpt = preview(lecture)
                if !excerpt.isEmpty {
                    Text(excerpt)
                        .appFont(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // The separator line starts at the text, not under the cover, like the song rows of Apple Music.
        // The value is measured from the left edge of the row content, where the cover starts, so it is the
        // distance to the text and does not add the default start of the line.
        // The closure is Sendable, so it gets a copy of the value, not the main actor property.
        .alignmentGuide(.listRowSeparatorLeading) { [separatorStart] _ in
            separatorStart
        }
    }

    /// The headline of the lecture. A lecture from before the headlines has none, and shows the start of
    /// its AI correction instead.
    private func preview(_ lecture: Lecture) -> String {
        let title = lecture.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        let summary = lecture.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return "" }
        return CorrectionText.plain(summary)
    }

    private func ensureLecturer() {
        guard course.lecturer == nil else { return }
        // The link is set only from the course. SwiftData fills the other side itself. Setting both sides made the
        // page miss the change, so it kept watching "no lecturer" and did not show the first names that were typed.
        let created = LecturerContact()
        modelContext.insert(created)
        course.lecturer = created
    }
}

struct LecturerEditor: View {
    @Bindable var contact: LecturerContact
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    /// What the student asked for with an icon. The system call or mail opens only after the confirmation.
    @State private var pending: ContactAction?
    @State private var notice: String?

    private enum ContactAction {
        case call
        case mail
    }

    private var phone: String { contact.phone.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var email: String { contact.email.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $contact.title)
                TextField("Given name", text: $contact.givenName)
                TextField("Family name", text: $contact.familyName)
                HStack(spacing: 12) {
                    TextField("Phone", text: $contact.phone)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                    if !phone.isEmpty {
                        Button("Call", systemImage: "phone.fill") { pending = .call }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                    }
                }
                HStack(spacing: 12) {
                    TextField("Email", text: $contact.email)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !email.isEmpty {
                        Button("Write email", systemImage: "envelope.fill") { pending = .mail }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                    }
                }
                TextField("Other contact", text: $contact.extra)
            }
            .navigationTitle("Lecturer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                confirmationTitle,
                isPresented: Binding(
                    get: { pending != nil },
                    set: { if !$0 { pending = nil } }
                ),
                titleVisibility: .visible
            ) {
                switch pending {
                case .call:
                    Button("Call") { open(.call) }
                case .mail:
                    Button("Write email") { open(.mail) }
                case nil:
                    EmptyView()
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert(
                notice ?? "",
                isPresented: Binding(
                    get: { notice != nil },
                    set: { if !$0 { notice = nil } }
                )
            ) {
                Button("OK", role: .cancel) { notice = nil }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var confirmationTitle: Text {
        switch pending {
        case .call: Text(verbatim: String(format: String(localized: "Call %@?"), phone))
        case .mail: Text(verbatim: String(format: String(localized: "Write to %@?"), email))
        case nil: Text(verbatim: "")
        }
    }

    /// `tel:` takes digits, a leading plus, and the dial characters. Spaces, dashes and brackets are dropped.
    private var callURL: URL? {
        let allowed = Set("0123456789+*#")
        let digits = String(phone.filter { allowed.contains($0) })
        guard !digits.isEmpty else { return nil }
        var parts = URLComponents()
        parts.scheme = "tel"
        parts.path = digits
        return parts.url
    }

    private var mailURL: URL? {
        guard !email.isEmpty else { return nil }
        var parts = URLComponents()
        parts.scheme = "mailto"
        parts.path = email
        return parts.url
    }

    private func open(_ action: ContactAction) {
        let url: URL?
        let failure: String
        switch action {
        case .call:
            url = callURL
            failure = String(localized: "The call could not be started.")
        case .mail:
            url = mailURL
            failure = String(localized: "The email could not be opened.")
        }
        guard let url else {
            notice = failure
            return
        }
        openURL(url) { accepted in
            if !accepted { notice = failure }
        }
    }
}
