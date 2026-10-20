import OSLog
import SwiftData
import SwiftUI

struct TermHomeView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Term.createdAt) private var terms: [Term]
    @Query(sort: \Lecture.startedAt, order: .reverse) private var lectures: [Lecture]

    @State private var showTerm = false
    @State private var showSlot = false
    @State private var showPending = false
    @State private var openedByDate = false

    private var term: Term? { terms.first { $0.isOpen } ?? terms.last }

    var body: some View {
        Group {
            if let term {
                TabView {
                    NavigationStack {
                        TodayPage(
                            term: term,
                            terms: terms,
                            showSlot: $showSlot,
                            showTerm: $showTerm,
                            showPending: $showPending
                        )
                    }
                    .tabItem { Label("Home", systemImage: "text.rectangle.page") }

                    NavigationStack {
                        ProgramPage(term: term)
                    }
                    .tabItem { Label("Timetable", systemImage: "calendar.day.timeline.left") }
                    // Off while a recording is processed — keep focus on the run.
                    .disabled(PipelineActivity.shared.isBusy)

                    NavigationStack {
                        AssistantPage()
                    }
                    .tabItem { Label("Assistant", systemImage: "waveform.and.mic") }
                    // Off while a recording is processed — Talk and the pipeline share the text model and memory.
                    .disabled(PipelineActivity.shared.isBusy)

                    NavigationStack {
                        SettingsPage()
                    }
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                    // Off while a recording is processed — model changes must not race the pipeline.
                    .disabled(PipelineActivity.shared.isBusy)
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
        .task {
            Logger(subsystem: "app.bellnote", category: "home").info("Home appeared, \(terms.count, privacy: .public) terms")
            // A lecture still saved as "processing" while nothing runs it goes back to paused.
            LecturePipeline.recoverInterrupted(context: modelContext)
            openCurrentTermOnLaunch()
            // Courses from before the color was stored get one, so no two courses of a term share a color.
            for item in terms { item.fillMissingCourseColors() }
        }
        .sheet(isPresented: $showTerm) { TermEditor(terms: terms) }
        .sheet(isPresented: $showSlot) {
            // The same sheet as "Add slot" in the timetable. A new course is made there, with its language.
            if let term { SlotEditor(term: term, weekday: Calendar.current.component(.weekday, from: .now)) }
        }
        .sheet(isPresented: $showPending) { PendingSheet(lectures: pending) }
    }

    /// When the app starts, the term whose dates include today opens. Later picks in the menu stay until the next start.
    /// With no such term the open one stays. When two terms overlap, the one that started last wins.
    private func openCurrentTermOnLaunch() {
        guard !openedByDate else { return }
        openedByDate = true
        let calendar = Calendar.current
        let today = Date.now
        let current = terms
            .filter { item in
                guard let dayAfterEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: item.endsOn)) else {
                    return false
                }
                return calendar.startOfDay(for: item.startsOn) <= today && today < dayAfterEnd
            }
            .max { ($0.startsOn, $0.createdAt) < ($1.startsOn, $1.createdAt) }
        guard let current, !current.isOpen else { return }
        for item in terms { item.isOpen = item.persistentModelID == current.persistentModelID }
    }

    private var pending: [Lecture] {
        lectures.filter { lecture in
            guard lecture.course?.term?.isOpen == true else { return false }
            // A paused lecture with audio is waiting to be processed, from the start (stage idle) or after a stop or an
            // interrupted run, which leave the last finished stage. A ready one is done.
            return lecture.state == LectureState.processing.rawValue
                || lecture.state == LectureState.failed.rawValue
                || (lecture.state == LectureState.paused.rawValue && lecture.audioRelativePath != nil && lecture.stage != PipelineStage.ready.rawValue)
        }
    }
}

/// The label of the button as it is. The system plain style fades the label while the button is held down.
private struct UnfadedCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

struct TodayPage: View {
    @Bindable var term: Term
    var terms: [Term]
    @Binding var showSlot: Bool
    @Binding var showTerm: Bool
    @Binding var showPending: Bool

    @Environment(\.modelContext) private var modelContext
    @Environment(AppSession.self) private var session
    @State private var recordCourse: Course?
    @State private var showConsent = false
    @State private var activeLecture: Lecture?
    @State private var pendingCourse: Course?
    @State private var pendingTermDelete = false
    @State private var showEditTerm = false
    /// The side of the badge on the hero card: as high as one line of the name (title 2) and the line of the lecturer
    /// (subheadline) together with the room between them. It grows with the text size, and it is not measured from the
    /// laid out texts, so the badge and the texts cannot push each other around in a loop.
    @ScaledMetric(relativeTo: .title2) private var heroBadgeSize: CGFloat = 50
    @State private var openedCourse: Course?
    @State private var editingCourse: Course?
    @State private var deleteNotice: String?

    var body: some View {
        List {
            if let slot = nextSlot {
                // The card is in the section header, like the course cards below it: a list row would clip the glass
                // edge and its shadow.
                Section {
                    EmptyView()
                } header: {
                    hero(slot)
                        .textCase(nil)
                        .foregroundStyle(.primary)
                        // Room between the navigation bar and the card. It comes on top of the room the list gives.
                        .padding(.top, Self.heroTopInset)
                }
            }
            // Two glass cards per row. They sit in the section header, like the stat tiles of a course:
            // a list row would clip the glass shadow and draw a grey band under the cards.
            // The delete of a course is in the menu icon at the end of the name row of its card.
            if !orderedCourses.isEmpty {
                Section {
                    EmptyView()
                } header: {
                    VStack(alignment: .leading, spacing: 0) {
                        // Looks like the section titles of the course page ("This week", "Assignments"), which the
                        // system draws in a plain list. This header sits in a grouped list, so the look is set by hand
                        // here. Change the font in this one place if the two do not match.
                        Text("Courses")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            // The cards go 16 pt out to the sides (below). The title goes out the same, so it
                            // starts at the left edge of the cards, like "This week" on the course page.
                            .padding(.leading, -16)
                            // Same gap as "This week" → first recording: the plain-list header space plus the 8 pt
                            // top inset of that row (`CoursePage` listRowInsets).
                            .padding(.bottom, Self.coursesTitleToCards)
                        LazyVGrid(columns: Self.noteColumns, spacing: Self.noteSpacing) {
                            ForEach(orderedCourses) { course in
                                // The card does not fade while it is held down.
                                // The menu is not inside the label of that button but above it, so both stay tappable.
                                Button {
                                    openedCourse = course
                                } label: {
                                    noteCard(course)
                                }
                                .buttonStyle(UnfadedCardStyle())
                                .overlay(alignment: .topTrailing) {
                                    courseMenu(course)
                                        .padding(.top, menuTopInset)
                                        .padding(.trailing, Self.cardPadding)
                                }
                            }
                        }
                        .padding(.horizontal, -16)
                    }
                    .textCase(nil)
                    .foregroundStyle(.primary)
                }
            }
            if !examRows.isEmpty {
                Section {
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
                } header: {
                    Text("Exams")
                }
            }
        }
        .listStyle(.insetGrouped)
        .listRowSpacing(4)
        .overlay {
            // A term with no course shows only this, in the middle of the screen.
            if orderedCourses.isEmpty {
                VStack(spacing: 12) {
                    Text("No courses yet")
                        .foregroundStyle(.secondary)
                    Button("New course", systemImage: "plus") { showSlot = true }
                        .buttonStyle(.glass)
                }
            }
        }
        .navigationTitle(termTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationSubtitle(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(session.locale)))
        .navigationDestination(item: $openedCourse) { course in
            CoursePage(course: course)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Pending", systemImage: "clock") { showPending = true }
            }
            ToolbarItem(placement: .primaryAction) {
                termMenu
            }
        }
        .sheet(isPresented: $showEditTerm) { TermEditor(terms: terms, editing: term) }
        .sheet(item: $editingCourse) { course in
            CourseEditor(course: course, term: term)
        }
        .sheet(item: $activeLecture) { lecture in
            RecorderSheet(lecture: lecture)
        }
        .alert(
            "Delete this course?",
            isPresented: Binding(
                get: { pendingCourse != nil },
                set: { if !$0 { pendingCourse = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let course = pendingCourse { deleteCourse(course) }
                pendingCourse = nil
            }
            Button("Cancel", role: .cancel) { pendingCourse = nil }
        } message: {
            Text("All recordings, notes, assignments and exams of this course will be deleted. This cannot be undone.")
        }
        .alert("Delete this term?", isPresented: $pendingTermDelete) {
            Button("Delete", role: .destructive) { deleteTerm() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All courses, recordings, notes, assignments and exams of this term will be deleted. This cannot be undone.")
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

    /// "Year 1 · Term 2" in the language of the app. Built from Text so the app language picks the words,
    /// not only the system language.
    private func yearAndTerm(_ item: Term) -> Text {
        Text("\(Text("Year \(item.yearOfStudy)")) · \(Text("Term \(item.termNumber)"))")
    }

    /// "Year 1 · Term 2", with the name the student gave the term in front of it when there is one.
    private var termTitle: Text {
        let name = term.customName.trimmingCharacters(in: .whitespacesAndNewlines)
        // A term with a name is shown by that name alone. Without a name it is "year, term".
        return name.isEmpty ? yearAndTerm(term) : Text(verbatim: name)
    }

    /// Icon only. Picks which term the app shows. Opening one closes the others; no term is deleted.
    private var termMenu: some View {
        Menu {
            Picker("Term", selection: openTerm) {
                ForEach(terms.sorted { ($0.yearOfStudy, $0.termNumber) > ($1.yearOfStudy, $1.termNumber) }) { item in
                    yearAndTerm(item).tag(item.persistentModelID)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button("New course", systemImage: "plus") { showSlot = true }
            Button("New term", systemImage: "calendar.badge.plus") { showTerm = true }
            Button("Edit term", systemImage: "pencil") { showEditTerm = true }
            Divider()
            Button("Delete term", systemImage: "trash", role: .destructive) { askDeleteTerm() }
        } label: {
            Image(systemName: "graduationcap")
        }
        .accessibilityLabel(Text("Term"))
    }

    private var openTerm: Binding<PersistentIdentifier> {
        Binding(
            get: { term.persistentModelID },
            set: { id in
                for item in terms { item.isOpen = item.persistentModelID == id }
            }
        )
    }

    private var orderedCourses: [Course] {
        term.courses.sorted { lhs, rhs in
            if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
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

    /// An icon and a text with a narrow gap of 4 pt. `Label` puts a wider gap of its own between them.
    private func iconLine(_ text: String, systemImage: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .accessibilityHidden(true)
            Text(verbatim: text)
        }
    }

    /// Hero fact line: muted palette icon when the value is real, secondary when it is an empty placeholder.
    /// `emphasized` matches the day line (semibold) for the time row.
    private func heroFact(
        _ text: String,
        systemImage: String,
        active: Bool,
        iconTint: Color,
        emphasized: Bool = false
    ) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .foregroundStyle(active ? iconTint : Color.secondary)
                .accessibilityHidden(true)
            Text(verbatim: text)
                .foregroundStyle(active ? Color.primary : Color.secondary)
        }
        .font(emphasized ? .subheadline.weight(.semibold) : .subheadline)
    }

    /// Same symbol as the course page bar (`record.circle`), drawn at the course badge size on the trailing side.
    /// Later recordings use the same confirm as the course page Record control (title + red Start recording button).
    /// A `Menu` can only show text rows; the glass Start recording control needs that confirm.
    private func startRecordIcon(_ course: Course) -> some View {
        Button {
            recordCourse = course
            showConsent = true
        } label: {
            Image(systemName: "record.circle")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.red)
                // A bit over half the course badge (0.5 × 1.25), so it stays under the name block height.
                .frame(width: heroBadgeSize * 0.625, height: heroBadgeSize * 0.625)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text("Record"))
        .consentFlow(course: recordCourse, asPopover: true, isPresented: $showConsent) { course, faceID in
            activeLecture = LectureStarter.make(course: course, faceID: faceID, context: modelContext)
        }
    }

    @ViewBuilder
    private func hero(_ slot: WeeklySlot) -> some View {
        let soon = slot.weekday == Calendar.current.component(.weekday, from: .now)
        let name = slot.course?.name ?? String(localized: "Course")
        VStack(alignment: .leading, spacing: 10) {
            let lecturer = slot.course?.lecturer?.displayName ?? ""
            // The top row: badge and name on the left, record control on the right at the same size as the badge.
            HStack(alignment: .center, spacing: 10) {
                // A square as high as the name and the lecturer together (one line of the name). The width is the
                // same as the height, so the shape does not change.
                CourseBadge(name: name, color: slot.course?.color ?? CourseStyle.color(for: name), size: heroBadgeSize)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.title2.bold())
                        .minimumScaleFactor(0.7)
                        .lineLimit(2)
                    iconLine(lecturer.isEmpty ? String(localized: "Lecturer") : lecturer, systemImage: "person.crop.circle")
                        .font(.subheadline)
                        .foregroundStyle(lecturer.isEmpty ? Color.secondary : Color.primary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let course = slot.course {
                    // Inset from the card edge so the control is not stuck to the right.
                    startRecordIcon(course)
                        .padding(.trailing, Self.cardPadding)
                }
            }
            // Eight facts in two columns of four, lines level across the row:
            //   day            | days left
            //   time           | minutes left
            //   place          | next exam
            //   last recording | open assignments
            // Real values use primary text + palette icons; empty placeholders stay secondary.
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: Self.heroInfoSpacing) {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar")
                            .foregroundStyle(soon ? Color.accentColor : CourseStyle.scheduleDayTint)
                            .accessibilityHidden(true)
                        Text(verbatim: status(for: slot))
                            .foregroundStyle(soon ? Color.accentColor : Color.primary)
                    }
                    .font(.subheadline.weight(.semibold))
                    heroFact(
                        slotDetail(slot),
                        systemImage: "clock",
                        active: true,
                        iconTint: soon ? Color.accentColor : CourseStyle.scheduleDayTint,
                        emphasized: true
                    )
                    heroFact(
                        slot.placeName.isEmpty ? String(localized: "Place not added") : slot.placeName,
                        systemImage: "mappin.and.ellipse",
                        active: !slot.placeName.isEmpty,
                        iconTint: CourseStyle.placeTint
                    )
                    if let course = slot.course {
                        heroFact(
                            lastRecordingText(for: course),
                            systemImage: "waveform",
                            active: !course.lectures.isEmpty,
                            iconTint: CourseStyle.recordingsTint
                        )
                    } else {
                        heroFact(
                            String(localized: "No recording yet"),
                            systemImage: "waveform",
                            active: false,
                            iconTint: CourseStyle.recordingsTint
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: Self.heroInfoSpacing) {
                    heroFact(
                        daysUntilText(for: slot),
                        systemImage: "hourglass.tophalf.filled",
                        active: true,
                        iconTint: CourseStyle.daysUntilTint
                    )
                    let liveMinutes = minutesLeft(for: slot) != nil
                    HStack(spacing: 4) {
                        Image(systemName: "hourglass")
                            .foregroundStyle(liveMinutes ? Color.accentColor : Color.secondary)
                            .accessibilityHidden(true)
                        Text(verbatim: minutesLeftText(for: slot))
                            .foregroundStyle(liveMinutes ? Color.accentColor : Color.secondary)
                    }
                    .font(.subheadline)
                    if let course = slot.course {
                        let openCount = course.assignments.filter { !$0.done && !$0.cancelled }.count
                        let hasUpcomingExam = course.sittings.contains { sitting in
                            guard let date = sitting.date else { return false }
                            return Calendar.current.startOfDay(for: date) >= Calendar.current.startOfDay(for: .now)
                        }
                        heroFact(
                            nextExamText(for: course),
                            systemImage: "calendar.badge.clock",
                            active: hasUpcomingExam,
                            iconTint: CourseStyle.examsTint
                        )
                        heroFact(
                            openAssignmentsText(for: course),
                            systemImage: "checklist",
                            active: openCount > 0,
                            iconTint: CourseStyle.assignmentsTint
                        )
                    } else {
                        heroFact(
                            String(localized: "Exam not added"),
                            systemImage: "calendar.badge.clock",
                            active: false,
                            iconTint: CourseStyle.examsTint
                        )
                        heroFact(
                            String(format: String(localized: "Pending assignments: %lld"), 0),
                            systemImage: "checklist",
                            active: false,
                            iconTint: CourseStyle.assignmentsTint
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .lineLimit(1)
        }
        // At the sides the same room between the edge and the content as in the course cards. Above and under, a bit
        // more: the corners of this card are close to the texts, and it is wider than a course card.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Self.cardPadding)
        .padding(.vertical, Self.heroVerticalPadding)
        // The same glass, corner and edge as the course cards. The glass is a background, not a modifier of the
        // texts, so it does not change their colours.
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.clear)
                .glassEffect(.regular, in: .rect(cornerRadius: 22))
        }
        // The card sits in a section header (see `body`), which has its own font. The texts and the button keep the
        // fonts set above, so this is only the base.
        .font(.body)
        // Out to the sides by the inset of the header, like the course cards, so the edges line up.
        .padding(.horizontal, -16)
    }

    private static let noteColumns = [
        GridItem(.flexible(), spacing: noteSpacing),
        GridItem(.flexible(), spacing: noteSpacing),
    ]
    private static let noteSpacing: CGFloat = 10
    private static let cardPadding: CGFloat = 12
    /// Vertical room under "Courses", matched to "This week" on the course page (header + first-row top inset).
    private static let coursesTitleToCards: CGFloat = 16
    /// Room between the lines of the block on the right of the hero card.
    private static let heroInfoSpacing: CGFloat = 4
    /// Room above and under the content of the hero card, between the content and the edge of the card.
    private static let heroVerticalPadding: CGFloat = 20
    /// Extra room above the hero card, under the navigation bar. Change this one number to move the card.
    private static let heroTopInset: CGFloat = 16
    /// The same height as the course badge, so the icon is centred on the name row.
    private static let menuSize: CGFloat = 34

    /// The height of one line of the name (`headline`) and of the lecturer (`caption2`). They follow the text size.
    @ScaledMetric(relativeTo: .headline) private var nameLineHeight: CGFloat = 22
    @ScaledMetric(relativeTo: .caption2) private var lecturerLineHeight: CGFloat = 13
    /// Recordings / Assignments / Exams on the course card: between footnote (13) and subheadline (15).
    @ScaledMetric(relativeTo: .footnote) private var courseTotalSize: CGFloat = 14

    /// The space above the menu icon, from the top of the card, so that its middle is on the middle of the name line.
    /// The row of the card is as tall as the badge or the name with the lecturer, whichever is taller, and the
    /// name is at the top of its block.
    private var menuTopInset: CGFloat {
        let block = nameLineHeight + lecturerLineHeight
        let row = max(Self.menuSize, block)
        return max(0, Self.cardPadding + (row - block) / 2 + nameLineHeight / 2 - Self.menuSize / 2)
    }

    /// The menu icon at the far end of the name row of a card. The favourite and the delete of the course are in it.
    private func courseMenu(_ course: Course) -> some View {
        Menu {
            Button(
                course.isFavorite ? "Remove from favorites" : "Add to favorites",
                systemImage: course.isFavorite ? "star.slash" : "star"
            ) {
                course.isFavorite.toggle()
            }
            Button("Edit course", systemImage: "pencil") { editingCourse = course }
            Button("Delete", systemImage: "trash", role: .destructive) { askDelete(course) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: Self.menuSize, height: Self.menuSize)
                .contentShape(.rect)
        }
        .menuIndicator(.hidden)
    }

    /// One course as a glass card. The three numbers are the totals of the whole course, not of one week.
    private func noteCard(_ course: Course) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // The badge is in the middle of the name and the lecturer. The menu icon (above the card) is on the line
            // of the name, see `menuTopInset`.
            HStack(spacing: 8) {
                CourseBadge(name: course.name, color: course.color, size: 34)
                // The name with the lecturer under it as a subtitle, like the course page. A course with no
                // lecturer name shows "Lecturer" there, the same as the course page.
                let lecturer = course.lecturer?.displayName ?? ""
                VStack(alignment: .leading, spacing: 0) {
                    // Only the name line leaves room for the menu icon, which sits above the card at the far end of
                    // it. The lecturer line is under the icon, so it goes on to the right edge of the card.
                    HStack(spacing: 0) {
                        Text(course.name)
                            .font(.headline)
                            // One line. A long name is cut at the end with "…".
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                        Color.clear.frame(width: Self.menuSize, height: 0)
                    }
                    Text(verbatim: lecturer.isEmpty ? String(localized: "Lecturer") : lecturer)
                        .font(.caption2)
                        .foregroundStyle(lecturer.isEmpty ? Color.secondary : Color.primary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Extra height of a taller neighbour goes here, between the name and the rest, so the totals and the
            // times keep the same distance in every card.
            Spacer(minLength: 4)
            // Nearest upcoming slot first and primary; the rest of the week stays secondary.
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(scheduleLines(course).enumerated()), id: \.element) { index, line in
                    Text(verbatim: line)
                        .font(.subheadline)
                        .foregroundStyle(index == 0 ? Color.primary : Color.secondary)
                        .lineLimit(1)
                }
            }
            HStack(spacing: 10) {
                total(course.lectures.count, "waveform", "Recordings", tint: CourseStyle.recordingsTint)
                total(course.assignments.count, "checklist", "Assignments", tint: CourseStyle.assignmentsTint)
                total(course.sittings.count, "calendar", "Exams", tint: CourseStyle.examsTint)
                Spacer(minLength: 0)
                // A favourite course has a star at the far end of the totals.
                if course.isFavorite {
                    // Outline only on the card: colored stroke, no fill.
                    Image(systemName: "star")
                        .font(.subheadline)
                        .foregroundStyle(CourseStyle.favoriteTint)
                        .accessibilityLabel(Text("Favorite"))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(Self.cardPadding)
        // A square: the height is the width of the column, so every card has the same size, whatever the course
        // has in it. The free room goes to the space under the name.
        .aspectRatio(1, contentMode: .fit)
        // The glass is a background, not a modifier of the texts. Otherwise the glass changes the text colours
        // and they no longer match the grey of the Start recording card.
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.clear)
                .glassEffect(.regular, in: .rect(cornerRadius: 22))
        }
        .contentShape(.rect(cornerRadius: 22))
    }

    /// Count chip on a course card. Zero stays secondary; a real count uses the same muted tint as the course page tiles.
    private func total(_ count: Int, _ symbol: String, _ name: LocalizedStringKey, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .foregroundStyle(count > 0 ? tint : Color.secondary)
            Text(count, format: .number)
                .foregroundStyle(count > 0 ? Color.primary : Color.secondary)
        }
        .font(.system(size: courseTotalSize, weight: .medium))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(name))
        .accessibilityValue(Text(count, format: .number))
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

    /// The next exam of the course that is today or later: "Midterm · 12 days later". A dash when there is none.
    private func nextExamText(for course: Course) -> String {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let upcoming = course.sittings
            .compactMap { sitting -> (sitting: ExamSitting, date: Date)? in
                guard let date = sitting.date, calendar.startOfDay(for: date) >= today else { return nil }
                return (sitting, date)
            }
            .min { $0.date < $1.date }
        guard let upcoming else { return String(localized: "Exam not added") }
        let days = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: upcoming.date)).day ?? 0
        let when: String
        switch days {
        case 0: when = String(localized: "Today")
        case 1: when = String(localized: "Tomorrow")
        default: when = String(format: String(localized: "%lld days later"), days)
        }
        return "\(examName(upcoming.sitting)) · \(when)"
    }

    /// The title the student gave the exam, or the name of its kind.
    private func examName(_ sitting: ExamSitting) -> String {
        let title = sitting.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        switch ExamKind(rawValue: sitting.kind) {
        case .midterm: return String(localized: "Midterm")
        case .final: return String(localized: "Final")
        case .other, nil: return String(localized: "Exam")
        }
    }

    /// The assignments that are not done and not cancelled, the same count as "Pending" on the course page.
    private func openAssignmentsText(for course: Course) -> String {
        let open = course.assignments.filter { !$0.done && !$0.cancelled }.count
        return String(format: String(localized: "Pending assignments: %lld"), open)
    }

    /// The newest recording of the course: today, yesterday, or its date. Empty courses say there is none yet.
    private func lastRecordingText(for course: Course) -> String {
        guard let last = course.lectures.max(by: { $0.startedAt < $1.startedAt }) else {
            return String(localized: "No recording yet")
        }
        let calendar = Calendar.current
        let when: String
        if calendar.isDateInToday(last.startedAt) {
            when = String(localized: "Today")
        } else if calendar.isDateInYesterday(last.startedAt) {
            when = String(localized: "Yesterday")
        } else {
            when = last.startedAt.formatted(.dateTime.day().month(.abbreviated))
        }
        return String(format: String(localized: "Last recording: %@"), when)
    }

    /// The minutes until the class ends, only while it is going on now. Otherwise nil.
    private func minutesLeft(for slot: WeeklySlot) -> Int? {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: .now)
        let minutes = calendar.component(.hour, from: .now) * 60 + calendar.component(.minute, from: .now)
        guard slot.weekday == weekday, minutes >= slot.startMinutes, minutes < slot.endMinutes else { return nil }
        return slot.endMinutes - minutes
    }

    /// How many days are left to the class: "Today", "Tomorrow" or "3 days later".
    private func daysUntilText(for slot: WeeklySlot) -> String {
        let weekday = Calendar.current.component(.weekday, from: .now)
        let days = (slot.weekday - weekday + 7) % 7
        switch days {
        case 0: return String(localized: "Today")
        case 1: return String(localized: "Tomorrow")
        default: return String(format: String(localized: "%lld days later"), days)
        }
    }

    /// The minutes until the class ends while it goes on. Before that it says the class has not started.
    private func minutesLeftText(for slot: WeeklySlot) -> String {
        guard let left = minutesLeft(for: slot) else { return String(localized: "Not started") }
        return String(format: String(localized: "%lld min left"), left)
    }

    private func slotDetail(_ slot: WeeklySlot) -> String {
        "\(ReminderScheduler.clock(slot.startMinutes))–\(ReminderScheduler.clock(slot.endMinutes))"
    }

    /// Minutes until this slot’s next occurrence (0 while the class is on). Used to put the nearest line first.
    private func minutesUntilNextOccurrence(_ slot: WeeklySlot) -> Int {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: .now)
        let minutes = calendar.component(.hour, from: .now) * 60 + calendar.component(.minute, from: .now)
        var days = (slot.weekday - weekday + 7) % 7
        if days == 0 {
            if minutes < slot.endMinutes {
                return max(0, slot.startMinutes - minutes)
            }
            days = 7
        }
        return days * 24 * 60 + slot.startMinutes - minutes
    }

    /// One line per weekly slot: nearest upcoming first ("Mon 09:00–10:30"), then the rest of the week.
    private func scheduleLines(_ course: Course) -> [String] {
        let symbols = Calendar.current.shortWeekdaySymbols
        return term.slots
            .filter { $0.course?.token == course.token }
            .sorted { minutesUntilNextOccurrence($0) < minutesUntilNextOccurrence($1) }
            .compactMap { slot in
                guard symbols.indices.contains(slot.weekday - 1) else { return nil }
                let span = "\(ReminderScheduler.clock(slot.startMinutes))–\(ReminderScheduler.clock(slot.endMinutes))"
                return "\(symbols[slot.weekday - 1]) \(span)"
            }
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

    /// Deletes the term that is open now, with everything under it.
    private func askDeleteTerm() {
        let lectures = term.courses.flatMap(\.lectures)
        guard lectures.allSatisfy(LectureRemoval.canDelete) else {
            deleteNotice = String(localized: "Wait until the recordings of this term have been processed, then delete it.")
            return
        }
        pendingTermDelete = true
    }

    private func deleteTerm() {
        do {
            for course in term.courses {
                try Vault.removeCourseDirectory(id: course.token)
                if session.focusCourseToken == course.token { session.focusCourseToken = nil }
            }
            // The latest term that is left opens in its place.
            let next = terms
                .filter { $0.persistentModelID != term.persistentModelID }
                .max { ($0.yearOfStudy, $0.termNumber) < ($1.yearOfStudy, $1.termNumber) }
            modelContext.delete(term)
            next?.isOpen = true
        } catch {
            Logger(subsystem: "app.bellnote", category: "delete").error(
                "Term delete failed: \(error.localizedDescription, privacy: .public)"
            )
            deleteNotice = String(localized: "The term could not be deleted.")
        }
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
