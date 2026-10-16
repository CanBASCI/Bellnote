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
}

struct CoursePage: View {
    @Bindable var course: Course
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale
    @State private var showConsent = false
    @State private var activeLecture: Lecture?
    @State private var showLecturer = false
    @State private var showAsk = false
    @State private var showInventory = false
    @State private var pendingDelete: Lecture?
    @State private var pendingItem: InventoryItem?
    @State private var pendingAssignment: Assignment?
    @State private var deleteNotice: String?
    @State private var selectedWeek = CoursePage.currentWeekStart

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
                            scrollToRecordings(proxy)
                        }
                        statTile(value: visibleAssignments.count, title: "Assignments", tint: CourseStyle.assignmentsTint, details: assignmentBreakdown(of: visibleAssignments)) {
                            scrollToAssignments(proxy)
                        }
                        statTile(value: visibleSittings.count, title: "Exams", tint: CourseStyle.examsTint)
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
            Section {
                if visibleLectures.isEmpty {
                    Text("No lectures yet.")
                        .foregroundStyle(.secondary)
                        .id(Self.emptyLecturesID)
                }
                ForEach(visibleLectures) { lecture in
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
                Text(verbatim: weekTitle(selectedWeek))
            }
            // TEMPORARY comparison, switched off: the same recordings with the old row. Remove the comment marks to
            // see it again. Delete it, with `oldLectureRow`, after the look is decided.
            // Section {
            //     ForEach(visibleLectures) { lecture in
            //         NavigationLink {
            //             LecturePage(lecture: lecture)
            //         } label: {
            //             oldLectureRow(lecture)
            //         }
            //     }
            // } header: {
            //     Text(verbatim: "\(weekTitle(selectedWeek)) (old)")
            // }
            if !visibleAssignments.isEmpty {
                Section {
                    ForEach(visibleAssignments) { assignment in
                        // The same row as the assignments of a recording: the same fonts, circle and spaces.
                        assignmentLink(assignment)
                            .askToDeleteSwipe { pendingAssignment = assignment }
                    }
                } header: {
                    Text("Assignments")
                }
                // TEMPORARY comparison, switched off: the same tasks with the old row. Remove the comment marks to
                // see it again. Delete it after the look is decided.
                // Section {
                //     ForEach(visibleAssignments) { assignment in
                //         AssignmentRow(assignment: assignment)
                //     }
                // } header: {
                //     Text(verbatim: "Assignments (old)")
                // }
            }
            // Nothing fills the inventory yet, so the section shows only when a row exists.
            if !course.inventory.isEmpty {
                Section("Inventory", isExpanded: $showInventory) {
                    ForEach(course.inventory) { item in
                        Text(item.title)
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
        }
        .confirmAssignmentDelete($pendingAssignment)
        .navigationTitle(course.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationSubtitle(
            selectedWeek == Self.currentWeekStart ? lecturerName : "\(lecturerName) · \(weekTitle(selectedWeek))"
        )
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // Ask about all the recordings of this course. The Ask inside a recording uses only that recording.
                Button("Ask", systemImage: "sparkles") { showAsk = true }
                    .labelStyle(.iconOnly)
            }
            ToolbarItem(placement: .topBarTrailing) {
                weekMenu
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Lecturer", systemImage: "person.crop.circle") { showLecturer = true }
                    .labelStyle(.iconOnly)
            }
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
            StudySheet(course: course, mode: .ask)
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

    /// Icon only. The icon changes when the page shows a week other than this one.
    private var weekMenu: some View {
        Menu {
            Picker("Week", selection: $selectedWeek) {
                ForEach(weekChoices, id: \.self) { start in
                    Text(verbatim: weekTitle(start))
                        .tag(start)
                }
            }
            #if DEBUG
            Divider()
            Button { addSampleWeeks() } label: { Text(verbatim: "Add sample past weeks (debug)") }
            Button(role: .destructive) { removeSampleWeeks() } label: { Text(verbatim: "Remove samples (debug)") }
            #endif
        } label: {
            Image(systemName: selectedWeek == Self.currentWeekStart ? "calendar" : "calendar.badge.clock")
        }
        .accessibilityLabel(Text("Week"))
    }

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
        selectedWeek = Self.currentWeekStart
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

    /// Counts of recordings per status, such as "9 Ready".
    private func lectureBreakdown(of lectures: [Lecture]) -> [String] {
        let processed = lectures.filter { !$0.isRecordedOnly }
        func count(_ state: LectureState) -> Int {
            processed.filter { $0.state == state.rawValue }.count
        }
        let entries: [(title: String, count: Int)] = [
            (LectureState.ready.title, count(.ready)),
            (String(localized: "Recorded"), lectures.filter(\.isRecordedOnly).count),
            (LectureState.processing.title, count(.processing)),
            (LectureState.failed.title, count(.failed)),
            (LectureState.recording.title, count(.recording)),
            (LectureState.paused.title, count(.paused))
        ]
        // Every status always shows, even at 0, so the tile has the same number of lines at all times.
        return entries.map { "\($0.count) \($0.title)" }
    }

    /// Done, cancelled and pending assignments. The big number on the tile is the total of all three.
    private func assignmentBreakdown(of assignments: [Assignment]) -> [String] {
        let pending = assignments.filter { !$0.done && !$0.cancelled }.count
        let done = assignments.filter { $0.done && !$0.cancelled }.count
        let cancelled = assignments.filter(\.cancelled).count
        return [
            "\(done) \(String(localized: "Done"))",
            "\(cancelled) \(String(localized: "Cancelled"))",
            "\(pending) \(String(localized: "Pending"))"
        ]
    }

    /// Assignments in the order the list shows them: by due date, undated ones last.
    private var sortedAssignments: [Assignment] {
        course.assignments.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
    }

    /// The first day of this week. A new recording always lands in this week.
    private static var currentWeekStart: Date {
        Calendar.current.dateInterval(of: .weekOfYear, for: .now)?.start ?? .now
    }

    /// The recordings of the chosen week, newest first.
    private var visibleLectures: [Lecture] {
        lectureWeeks.first { $0.start == selectedWeek }?.lectures ?? []
    }

    /// The assignments of the chosen week: the ones that came out of its recordings.
    /// An assignment without a recording belongs to this week.
    private var visibleAssignments: [Assignment] {
        let calendar = Calendar.current
        return sortedAssignments.filter { assignment in
            let start = assignment.sourceLecture.flatMap {
                calendar.dateInterval(of: .weekOfYear, for: $0.startedAt)?.start
            } ?? Self.currentWeekStart
            return start == selectedWeek
        }
    }

    /// The exams that fall in the chosen week. An exam without a date is in no week.
    private var visibleSittings: [ExamSitting] {
        let calendar = Calendar.current
        return course.sittings.filter { sitting in
            guard let date = sitting.date else { return false }
            return calendar.dateInterval(of: .weekOfYear, for: date)?.start == selectedWeek
        }
    }

    /// The weeks the menu offers: this week, and every week that has a recording.
    private var weekChoices: [Date] {
        var starts = Set(lectureWeeks.map(\.start))
        starts.insert(Self.currentWeekStart)
        return starts.sorted(by: >)
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
    private func scrollToRecordings(_ proxy: ScrollViewProxy) {
        if let first = visibleLectures.first {
            withAnimation { proxy.scrollTo(first.id, anchor: .top) }
        } else {
            withAnimation { proxy.scrollTo(Self.emptyLecturesID, anchor: .top) }
        }
    }

    private func scrollToAssignments(_ proxy: ScrollViewProxy) {
        guard let first = visibleAssignments.first else { return }
        withAnimation { proxy.scrollTo(first.id, anchor: .top) }
    }

    /// A tile is a button when it has an action, so a tap can take the student to its list.
    @ViewBuilder
    private func statTile(value: Int, title: LocalizedStringKey, tint: Color, details: [String] = [], action: (() -> Void)? = nil) -> some View {
        if let action {
            Button(action: action) {
                statTileBody(value: value, title: title, tint: tint, details: details)
            }
            .buttonStyle(.plain)
        } else {
            statTileBody(value: value, title: title, tint: tint, details: details)
        }
    }

    private func statTileBody(value: Int, title: LocalizedStringKey, tint: Color, details: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // The same fonts as the recording rows: the title like the time. The lines are `footnote`, like the
            // lines of the cards on Home.
            // The total sits at the right end of the title line.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.headline)
                    // No shrinking. Every title has the same size on every tile.
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(value, format: .number)
                    .font(.title3.weight(.bold).monospacedDigit())
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
            ForEach(details, id: \.self) { line in
                Text(verbatim: line)
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
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

    private func lectureRow(_ lecture: Lecture) -> some View {
        // The day is the cover on the left, like the cover of a song in Apple Music. The title is the time of day.
        let separatorStart = Self.coverSize + Self.coverGap
        return HStack(spacing: Self.coverGap) {
            DateCover(date: lecture.startedAt, color: course.color, size: Self.coverSize)
                .accessibilityValue(Text(lecture.statusTitle))
            // The time and the length on the first line, the summary under them.
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(lecture.startedAt.formatted(.dateTime.hour().minute().locale(locale)))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    Image(systemName: lecture.statusSymbol)
                        // The same weight as the time. The symbol is scaled so that it is at most as tall as the digits
                        // of the time. A wide symbol is lower than that, it never goes above it.
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: timeDigitHeight)
                        .font(.subheadline.weight(.medium))
                        // The system colours are bright. On the light background a small symbol in them is hard to
                        // see, so there they are mixed with black. On the dark background they stay as they are.
                        .foregroundStyle(
                            colorScheme == .dark ? lecture.statusTint : lecture.statusTint.mix(with: .black, by: 0.3)
                        )
                        // The cover already tells the status to VoiceOver.
                        .accessibilityHidden(true)
                    if lecture.recordedSeconds >= 60 {
                        Text(String(format: String(localized: "%lld min"), lecture.recordedSeconds / 60))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                let excerpt = preview(lecture)
                if !excerpt.isEmpty {
                    Text(excerpt)
                        .font(.subheadline)
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

    // TEMPORARY comparison: the recording row as it was before the date cover. Delete with the old sections.
    private func oldLectureRow(_ lecture: Lecture) -> some View {
        let separatorStart = Self.coverSize + Self.coverGap
        return HStack(spacing: Self.coverGap) {
            DateCover(date: lecture.startedAt, color: course.color, size: Self.coverSize)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(lecture.startedAt.formatted(.dateTime.hour().minute().locale(locale)))
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
        }
        .padding(.vertical, 2)
        // The separator starts at the text, not under the cover, the same as in the row above.
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
