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
                        .tint(Color.accentColor)
                    }
                    .tabItem { Label("Home", systemImage: "text.rectangle.page") }

                    NavigationStack {
                        ProgramPage(term: term)
                            .tint(Color.accentColor)
                    }
                    .tabItem { Label("Timetable", systemImage: "calendar.day.timeline.left") }
                    // Off while a recording is processed — keep focus on the run.
                    .disabled(PipelineActivity.shared.isBusy)

                    NavigationStack {
                        AssistantPage()
                            .tint(Color.accentColor)
                    }
                    .tabItem { Label("Assistant", systemImage: "waveform.and.mic") }
                    // Off while a recording is processed — Talk and the pipeline share the text model and memory.
                    .disabled(PipelineActivity.shared.isBusy)

                    NavigationStack {
                        SettingsPage()
                            .tint(Color.accentColor)
                    }
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                    // Off while a recording is processed — model changes must not race the pipeline.
                    .disabled(PipelineActivity.shared.isBusy)
                }
                // Selected tab is primary: dark on a light page, light on a dark page. Unselected tabs stay the system gray.
                .tint(.primary)
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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppSession.self) private var session
    /// Missed and cancelled marks for a meeting. A cancelled one is left out of the card’s bar.
    @Query(sort: \LectureGap.day) private var gaps: [LectureGap]
    @State private var recordCourse: Course?
    @State private var showConsent = false
    @State private var activeLecture: Lecture?
    @State private var pendingCourse: Course?
    @State private var pendingTermDelete = false
    @State private var showEditTerm = false
    /// The side of the badge. It matches one line of the course name plus the lecturer, and it grows
    /// with the text size. It is not measured from the laid out texts, so the badge and the texts cannot
    /// push each other around in a loop.
    @ScaledMetric(relativeTo: .title2) private var heroBadgeSize: CGFloat = 44
    /// Course name while the hero is open. One step under the old 20 pt size.
    @ScaledMetric(relativeTo: .body) private var heroNameSize: CGFloat = 18
    /// Course name and the time once the hero has closed.
    @ScaledMetric(relativeTo: .callout) private var heroCollapsedSize: CGFloat = 16
    /// Lecturer, a step under the name. Scales with caption.
    @ScaledMetric(relativeTo: .caption) private var heroLecturerSize: CGFloat = 12
    /// Open size of the time. The count matches the course name; the small word is quieter.
    /// Collapsed, both words meet the course name at `heroCollapsedSize`.
    @ScaledMetric(relativeTo: .body) private var heroTimeAmountSize: CGFloat = 18
    @ScaledMetric(relativeTo: .subheadline) private var heroTimeWordSize: CGFloat = 15
    /// Matches the quiet fact line, so the collapse distance includes that row.
    @ScaledMetric(relativeTo: .footnote) private var heroDetailLineHeight: CGFloat = 18
    @State private var openedCourse: Course?
    @State private var editingCourse: Course?
    @State private var deleteNotice: String?
    /// Width of the three count icons on a course card, so the bar ends with the last of them and not at the star.
    @State private var countWidths: [UUID: CGFloat] = [:]
    /// Left edge of the section header. The cards and the hero sit `cardRowOutset` further out, on the grouped list edge.
    @State private var courseCardLeading: CGFloat = 32
    /// Height of the glass band as it is laid out now, open or collapsed.
    @State private var heroBandHeight: CGFloat = 0
    /// Height of the glass band while the hero is fully open. The list keeps this top margin, so shrinking the band does not jump the cards.
    @State private var heroExpandedHeight: CGFloat = 0
    /// How far the course list has moved up from its resting position.
    @State private var courseScroll: CGFloat = 0

    var body: some View {
        ZStack(alignment: .top) {
            // The course cards report their left edge in this space, and the fixed hero uses it.
            Color(.systemGroupedBackground)
                .ignoresSafeArea()
            List {
            // Two glass cards per row. They sit in the section header, like the stat tiles of a course:
            // a list row would clip the glass shadow and draw a grey band under the cards.
            // The delete of a course is in the menu icon at the end of the name row of its card.
            if !orderedCourses.isEmpty {
                Section {
                    EmptyView()
                } header: {
                    VStack(alignment: .leading, spacing: 0) {
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
                        .padding(.horizontal, -Self.cardRowOutset)
                    }
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.frame(in: .named("home")).minX
                    } action: { leading in
                        guard abs(leading - courseCardLeading) > 0.5 else { return }
                        courseCardLeading = leading
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
                                .appFont(.subheadline)
                                .foregroundStyle(.secondary)
                            if row.overlaps {
                                Text("Overlaps another sitting.")
                                    .appFont(.footnote)
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
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        // The list fills the page. Its first row starts under the open glass band, then scrolls up behind it.
        // The margin stays at the open height, so the band can shrink without moving the cards.
        .contentMargins(.top, courseListTopMargin, for: .scrollContent)
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            // At rest this is 0. Scrolling the cards up makes it positive.
            max(0, geo.contentOffset.y + geo.contentInsets.top)
        } action: { _, scrolled in
            guard abs(scrolled - courseScroll) > 0.5 else { return }
            courseScroll = scrolled
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                termMenu
            }
            // Pending sits just left of Record. Record stays the outer trailing icon.
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Pending", systemImage: "clock") { showPending = true }
                if let course = nextSlot?.course {
                    Button("Record", systemImage: "record.circle") {
                        recordCourse = course
                        showConsent = true
                    }
                    .tint(.red)
                    .consentFlow(course: recordCourse, asPopover: true, isPresented: $showConsent) { course, faceID in
                        activeLecture = LectureStarter.make(course: course, faceID: faceID, context: modelContext)
                    }
                }
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
            if let slot = nextSlot {
                // Fixed over the list. Scrolling the courses up collapses this glass; scrolling back opens it.
                hero(slot)
                    .foregroundStyle(.primary)
                    // 4 pt under the navigation bar, then the course row.
                    // The cards sit 20 pt out of the header, 12 pt from the screen. The glass uses that same edge.
                    .padding(.horizontal, max(courseCardLeading - Self.cardRowOutset, 0))
                    .padding(.bottom, Self.heroTopInset)
                    // Course color in the glass for the whole band, from the top of the screen to the gap before the course cards.
                    .background {
                        GeometryReader { geo in
                            let name = slot.course?.name ?? String(localized: "Course")
                            let tint = slot.course?.color ?? CourseStyle.color(for: name)
                            heroBandShape
                                .fill(.clear)
                                .glassEffect(
                                    .regular.tint(tint.opacity(colorScheme == .dark ? 0.5 : 0.28)),
                                    in: heroBandShape
                                )
                                .frame(width: geo.size.width, height: geo.size.height)
                        }
                        .ignoresSafeArea(edges: .top)
                        .allowsHitTesting(false)
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        if abs(height - heroBandHeight) > 0.5 {
                            heroBandHeight = height
                        }
                        // Only while open. During the collapse the live height is shorter on purpose.
                        guard heroCollapse < 0.02, abs(height - heroExpandedHeight) > 0.5 else { return }
                        heroExpandedHeight = height
                    }
            }
        }
        .coordinateSpace(.named("home"))
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

    /// Top margin of the course list. Stays at the open band so the cards do not jump while the hero closes.
    private var courseListTopMargin: CGFloat {
        guard nextSlot != nil else { return 0 }
        return heroExpandedHeight > 0 ? heroExpandedHeight : heroBandHeight
    }

    /// The fact line, including the gap above it. This part of the band closes with the scroll.
    private var heroFactSpan: CGFloat {
        heroDetailLineHeight + 10
    }

    /// Room under the lecturer line so its words sit on the icon's bottom edge, not under it.
    private static let heroLecturerLift: CGFloat = 2

    /// The lecturer line plus the gap under the name.
    private var heroLecturerBlock: CGFloat {
        UIFont.systemFont(ofSize: heroLecturerSize).lineHeight + 2
    }

    /// One line of the open course name.
    private var heroNameLineHeight: CGFloat {
        UIFont.systemFont(ofSize: heroNameSize, weight: .semibold).lineHeight
    }

    /// One line once the hero has closed. The name and the time meet at this size.
    private var heroCollapsedLineHeight: CGFloat {
        UIFont.systemFont(ofSize: heroCollapsedSize, weight: .semibold).lineHeight
    }

    /// The open name row: the badge, or the name with the lecturer when that is taller.
    private var heroOpenRow: CGFloat {
        max(heroBadgeSize, heroNameLineHeight + heroLecturerBlock)
    }

    /// How much shorter the name row is once the badge and the lecturer have closed.
    private var heroRowDrop: CGFloat {
        max(0, heroOpenRow - heroCollapsedLineHeight)
    }

    /// Scroll that fully closes the fact line, the badge, and the lecturer. Matches the height the band loses.
    private var heroLowerSpan: CGFloat {
        heroFactSpan + heroRowDrop
    }

    /// 0 while the hero is open, 1 when the icon, the lecturer, and the fact line have closed.
    private var heroCollapse: CGFloat {
        guard heroLowerSpan > 1 else { return 0 }
        return min(1, max(0, courseScroll / heroLowerSpan))
    }

    @ViewBuilder
    private func hero(_ slot: WeeklySlot) -> some View {
        let name = slot.course?.name ?? String(localized: "Course")
        let tint = slot.course?.color ?? CourseStyle.color(for: name)
        let lecturer = slot.course?.lecturer?.displayName ?? ""
        let collapse = heroCollapse
        let nameSize = heroNameSize + (heroCollapsedSize - heroNameSize) * collapse
        VStack(alignment: .leading, spacing: 0) {
            // Open: badge, name, lecturer, and the large time on the bottom of that row.
            // Closed: the name and the time only, at the same size.
            HStack(alignment: .bottom, spacing: 10 * (1 - collapse)) {
                CourseBadge(name: name, color: tint, size: heroBadgeSize)
                    .frame(
                        width: heroBadgeSize * (1 - collapse),
                        height: heroOpenRow * (1 - collapse) + heroCollapsedLineHeight * collapse,
                        alignment: .bottom
                    )
                    .clipped()
                    .opacity(1 - collapse)
                    .accessibilityHidden(collapse > 0.95)
                VStack(alignment: .leading, spacing: 0) {
                    Text(name)
                        .appFont(size: nameSize, weight: .semibold)
                        .lineLimit(2)
                    iconLine(lecturer.isEmpty ? String(localized: "Lecturer") : lecturer, systemImage: "person.crop.circle")
                        .appFont(size: heroLecturerSize)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.top, 2)
                        .frame(height: heroLecturerBlock * (1 - collapse), alignment: .bottom)
                        .clipped()
                        // The line box was flush with the icon's bottom, so the words sat under that edge.
                        .padding(.bottom, Self.heroLecturerLift * (1 - collapse))
                        .opacity(1 - collapse)
                        .accessibilityHidden(collapse > 0.95)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                heroMoment(slot, collapse: collapse)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
            }
            // The quiet fact line closes upward as the cards scroll up.
            HeroDetailLine(items: heroDetail(slot))
                .padding(.top, 10)
                .frame(height: heroFactSpan * (1 - collapse), alignment: .top)
                .clipped()
                .opacity(1 - collapse)
                .accessibilityHidden(collapse > 0.95)
        }
        // A little room inside the glass, between its edge and the badge.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Self.heroContentSidePadding)
        .padding(.top, Self.heroContentTopPadding)
        .padding(.bottom, Self.heroVerticalPadding)
        // The card sits above the scrolling list, which has its own font. The texts and the button keep the
        // fonts set above, so this is only the base.
        .appFont(.body)
    }

    /// The large time on the hero. While the class is on, the minutes left. Before it starts today, the minutes
    /// until it starts. On another day, today, tomorrow, or the day count.
    private func heroMoment(_ slot: WeeklySlot, collapse: CGFloat) -> some View {
        let amount: String
        let word: LocalizedStringKey?
        if let left = minutesLeft(for: slot) {
            amount = String(format: String(localized: "%lld min"), left)
            word = "left"
        } else if let until = minutesUntilStart(for: slot) {
            amount = String(format: String(localized: "%lld min"), until)
            word = "later"
        } else {
            let days = daysUntil(slot)
            switch days {
            case 0:
                amount = String(localized: "Today")
                word = nil
            case 1:
                amount = String(localized: "Tomorrow")
                word = nil
            default:
                amount = String(format: String(localized: "%lld days"), days)
                word = "later"
            }
        }
        // Both words meet the closed course name. The number must not shrink by itself, or it
        // ends smaller than "later" and the line jumps when the badge closes.
        let amountSize = heroTimeAmountSize + (heroCollapsedSize - heroTimeAmountSize) * collapse
        let wordSize = heroTimeWordSize + (heroCollapsedSize - heroTimeWordSize) * collapse
        // The gap matches a word space, the same room as between the count and "gün".
        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(verbatim: amount)
                .appFont(size: amountSize, weight: .semibold)
                .lineLimit(1)
            if let word {
                Text(word)
                    .appFont(size: wordSize)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(.primary)
        .accessibilityElement(children: .combine)
    }

    /// One quiet line under the large time. Each fact keeps a small symbol: the clock span, the place when it
    /// is set, the last recording, open assignments when there are some, and the next exam when one is coming.
    private func heroDetail(_ slot: WeeklySlot) -> [HeroDetailItem] {
        var items = [HeroDetailItem(symbol: "clock", text: slotDetail(slot))]
        if !slot.placeName.isEmpty {
            items.append(HeroDetailItem(symbol: "mappin.and.ellipse", text: slot.placeName))
        }
        if let course = slot.course {
            items.append(HeroDetailItem(symbol: "waveform", text: lastRecordingText(for: course)))
            if course.assignments.contains(where: { !$0.done && !$0.cancelled }) {
                items.append(HeroDetailItem(symbol: "checklist", text: openAssignmentsText(for: course)))
            }
            if let exam = nextExamText(for: course) {
                items.append(HeroDetailItem(symbol: "calendar.badge.clock", text: exam))
            }
        } else {
            items.append(HeroDetailItem(symbol: "waveform", text: String(localized: "No recording yet")))
        }
        return items
    }

    /// The glass band. Square at the top of the screen. The bottom corners match the old hero card.
    private var heroBandShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            bottomLeadingRadius: 22,
            bottomTrailingRadius: 22,
            style: .continuous
        )
    }

    private static let noteColumns = [
        GridItem(.flexible(), spacing: noteSpacing),
        GridItem(.flexible(), spacing: noteSpacing),
    ]
    private static let noteSpacing: CGFloat = 10
    /// Pulls the course row out of the section header, 4 pt past the grouped list edge.
    /// That edge is 16 pt from the screen, so the glass and the cards land at 12 pt.
    private static let cardRowOutset: CGFloat = 20
    private static let cardPadding: CGFloat = 12
    /// Inside the hero glass, between the glass edge and the badge.
    private static let heroContentSidePadding: CGFloat = 6
    /// Room under the scrolling line, inside the glass.
    private static let heroVerticalPadding: CGFloat = 8
    /// Room above the course row, inside the glass. The gap under the navigation bar is 4 pt.
    private static let heroContentTopPadding: CGFloat = 4
    /// Extra room under the hero content, above the course cards. The top gap is separate and is 0.
    private static let heroTopInset: CGFloat = 4
    /// The same height as the course badge, so the icon is centred on the name row.
    private static let menuSize: CGFloat = 34

    /// The height of one line of the name (15 pt, semibold) and of the lecturer (`caption2`). They follow the text size.
    @ScaledMetric(relativeTo: .subheadline) private var nameLineHeight: CGFloat = 20
    @ScaledMetric(relativeTo: .caption2) private var lecturerLineHeight: CGFloat = 13
    /// Recordings / Assignments / Exams on the course card: between footnote (13) and subheadline (15).
    @ScaledMetric(relativeTo: .footnote) private var courseTotalSize: CGFloat = 14

    /// The space above the menu icon, from the top of the card, so that its middle is on the middle of the name line.
    /// The name sits at the bottom of the row, with the lecturer under it, so any spare height is above the name.
    private var menuTopInset: CGFloat {
        let block = nameLineHeight + lecturerLineHeight
        let row = max(Self.menuSize, block)
        return max(0, Self.cardPadding + (row - block) + nameLineHeight / 2 - Self.menuSize / 2)
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
                .appFont(.body, weight: .semibold)
                .foregroundStyle(.secondary)
                .frame(width: Self.menuSize, height: Self.menuSize)
                .contentShape(.rect)
        }
        .menuIndicator(.hidden)
    }

    /// One course as a glass card. The three numbers are the totals of the whole course, not of one week.
    private func noteCard(_ course: Course) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // The name and the lecturer sit on the bottom of this row, like the open hero. The menu icon
            // (above the card) stays on the line of the name, see `menuTopInset`.
            HStack(alignment: .bottom, spacing: 8) {
                CourseBadge(name: course.name, color: course.color, size: 34)
                // The name with the lecturer under it as a subtitle, like the course page. A course with no
                // lecturer name shows "Lecturer" there, the same as the course page.
                let lecturer = course.lecturer?.displayName ?? ""
                VStack(alignment: .leading, spacing: 0) {
                    // Only the name line leaves room for the menu icon, which sits above the card at the far end of
                    // it. The lecturer line is under the icon, so it goes on to the right edge of the card.
                    HStack(spacing: 0) {
                        Text(course.name)
                            .appFont(.subheadline, weight: .semibold)
                            // One line. A long name is cut at the end with "…".
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                        Color.clear.frame(width: Self.menuSize, height: 0)
                    }
                    Text(verbatim: lecturer.isEmpty ? String(localized: "Lecturer") : lecturer)
                        .appFont(.caption2)
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
                        .appFont(.subheadline)
                        .foregroundStyle(index == 0 ? Color.primary : Color.secondary)
                        .lineLimit(1)
                }
            }
            // One system bar: of the meetings already held, how many have a recording. No bar until one has ended.
            // The bar and its count are as wide as the three icons under them, so the count sits at the exams
            // number, not at the far edge of the card.
            if let share = recordedShare(for: course), let width = countWidths[course.token], width > 0 {
                attendanceBar(share, tint: course.color)
                    .frame(width: width, alignment: .leading)
            }
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    total(course.lectures.count, "waveform", "Recordings", tint: CourseStyle.recordingsTint)
                    total(course.assignments.count, "checklist", "Assignments", tint: CourseStyle.assignmentsTint)
                    total(course.sittings.count, "calendar", "Exams", tint: CourseStyle.examsTint)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                    guard abs((countWidths[course.token] ?? 0) - width) > 0.5 else { return }
                    countWidths[course.token] = width
                }
                Spacer(minLength: 0)
                // A favourite course has a star at the far end of the totals.
                if course.isFavorite {
                    // Outline only on the card: colored stroke, no fill.
                    Image(systemName: "star")
                        .appFont(.subheadline)
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
        // Plain glass, same as the hero. A background, so it does not change the text colours.
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.clear)
                .glassEffect(.regular, in: .rect(cornerRadius: 22))
        }
        .contentShape(.rect(cornerRadius: 22))
    }

    /// Past meetings of one course, and how many of them have a recording.
    private struct RecordedShare {
        var recorded: Int
        var past: Int
    }

    /// The short system bar under the dates. The fill is the course color. Zero stays an empty track, and its count is secondary.
    private func attendanceBar(_ share: RecordedShare, tint: Color) -> some View {
        HStack(spacing: 6) {
            ProgressView(value: Double(share.recorded), total: Double(share.past))
                .tint(tint)
                .controlSize(.small)
                .frame(maxWidth: .infinity)
            Text(verbatim: String(format: String(localized: "%lld recorded"), share.recorded))
                .appFont(.caption2)
                .foregroundStyle(share.recorded > 0 ? Color.primary : Color.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text(verbatim: String(format: String(localized: "%1$lld of %2$lld recorded"), share.recorded, share.past))
        )
    }

    /// Past meetings of this course, and how many of them have a recording. Today’s meeting counts only after it has
    /// ended. A cancelled week or a cancelled meeting is left out. Nil when none have ended yet.
    private func recordedShare(for course: Course) -> RecordedShare? {
        let calendar = Calendar.current
        let now = Date.now
        let today = calendar.startOfDay(for: now)
        let termStart = calendar.startOfDay(for: term.startsOn)
        let termEnd = calendar.startOfDay(for: term.endsOn)
        let lastDay = min(today, termEnd)
        guard lastDay >= termStart else { return nil }

        let slots = term.slots.filter { $0.course?.token == course.token }
        guard !slots.isEmpty else { return nil }

        let nowMinutes = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        var lecturesLeft: [Date: Int] = [:]
        for lecture in course.lectures {
            let day = calendar.startOfDay(for: lecture.startedAt)
            lecturesLeft[day, default: 0] += 1
        }
        let courseGaps = gaps.filter { $0.courseID == course.token }

        var past = 0
        var recorded = 0
        var day = termStart
        while day <= lastDay {
            let weekday = calendar.component(.weekday, from: day)
            let weekStart = calendar.dateInterval(of: .weekOfYear, for: day)?.start
            let termCancelled = weekStart.map { start in
                term.cancelledWeeks.contains { calendar.isDate($0.weekStart, inSameDayAs: start) }
            } ?? false
            if !termCancelled {
                let todays = slots
                    .filter { $0.weekday == weekday }
                    .sorted { $0.startMinutes < $1.startMinutes }
                for slot in todays {
                    if calendar.isDate(day, inSameDayAs: today) {
                        let end = endMinutes(of: slot, weekStart: weekStart, calendar: calendar)
                        if nowMinutes < end { continue }
                    }
                    if meetingCancelled(slot, day: day, weekStart: weekStart, gaps: courseGaps, calendar: calendar) {
                        continue
                    }
                    past += 1
                    let left = lecturesLeft[day, default: 0]
                    if left > 0 {
                        recorded += 1
                        lecturesLeft[day] = left - 1
                    }
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        guard past > 0 else { return nil }
        return RecordedShare(recorded: recorded, past: past)
    }

    /// The end of this meeting. A one-week time change on the slot replaces the usual end.
    private func endMinutes(of slot: WeeklySlot, weekStart: Date?, calendar: Calendar) -> Int {
        let exception = slot.exceptions.first { exception in
            guard let weekStart else { return false }
            return calendar.isDate(exception.weekStart, inSameDayAs: weekStart)
        }
        return exception?.overrideEndMinutes ?? slot.endMinutes
    }

    /// A cancelled week of this slot, or a gap the student marked cancelled, is not a meeting that was held.
    private func meetingCancelled(
        _ slot: WeeklySlot,
        day: Date,
        weekStart: Date?,
        gaps: [LectureGap],
        calendar: Calendar
    ) -> Bool {
        if slot.exceptions.contains(where: { exception in
            guard exception.cancelled else { return false }
            if calendar.isDate(exception.weekStart, inSameDayAs: day) { return true }
            guard let weekStart else { return false }
            return calendar.isDate(exception.weekStart, inSameDayAs: weekStart)
        }) {
            return true
        }
        return gaps.contains { gap in
            gap.slotID == slot.token
                && gap.mark == GapMark.cancelled.rawValue
                && calendar.isDate(gap.day, inSameDayAs: day)
        }
    }

    /// Count chip on a course card. Zero stays secondary; a real count uses the same muted tint as the course page tiles.
    private func total(_ count: Int, _ symbol: String, _ name: LocalizedStringKey, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .foregroundStyle(count > 0 ? tint : Color.secondary)
            Text(count, format: .number)
                .foregroundStyle(count > 0 ? Color.primary : Color.secondary)
        }
        .appFont(size: courseTotalSize, weight: .medium)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(name))
        .accessibilityValue(Text(count, format: .number))
    }

    /// The next exam of the course that is today or later: "Midterm · 12 days later". Nil when there is none.
    private func nextExamText(for course: Course) -> String? {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let upcoming = course.sittings
            .compactMap { sitting -> (sitting: ExamSitting, date: Date)? in
                guard let date = sitting.date, calendar.startOfDay(for: date) >= today else { return nil }
                return (sitting, date)
            }
            .min { $0.date < $1.date }
        guard let upcoming else { return nil }
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

    /// The minutes until the class starts, only when that start is later today. Otherwise nil.
    private func minutesUntilStart(for slot: WeeklySlot) -> Int? {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: .now)
        let minutes = calendar.component(.hour, from: .now) * 60 + calendar.component(.minute, from: .now)
        guard slot.weekday == weekday, minutes < slot.startMinutes else { return nil }
        return slot.startMinutes - minutes
    }

    /// Days until the slot’s weekday. 0 is today, 1 is tomorrow.
    private func daysUntil(_ slot: WeeklySlot) -> Int {
        let weekday = Calendar.current.component(.weekday, from: .now)
        return (slot.weekday - weekday + 7) % 7
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

/// One fact on the quiet line under the large time: a system symbol and its words.
private struct HeroDetailItem: Equatable {
    var symbol: String
    var text: String
}

/// The quiet fact line under the time on the home hero.
/// One row of symbol and words. When that row is wider than the hero, it slides left in a loop.
/// A gap sits between one copy and the next, so the end does not meet the start.
/// A horizontal drag moves it. After the finger lifts and the slide settles, the loop waits, then continues
/// from the place where it was left. Reduce Motion leaves it still.
private struct HeroDetailLine: View {
    var items: [HeroDetailItem]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .footnote) private var lineHeight: CGFloat = 18

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var position = ScrollPosition(x: 0)
    @State private var running = false
    @State private var baseX: CGFloat = 0
    @State private var baseDate = Date()
    @State private var resume: Task<Void, Never>?
    /// True from the moment a finger takes the line until it has settled again.
    @State private var heldByFinger = false

    /// How far the line travels left each second.
    private static let speed: CGFloat = 32
    /// Room between one copy of the line and the next.
    private static let gap: CGFloat = 48
    /// Copies laid end to end, so a drag in either direction stays on the same words.
    private static let copies = 5
    /// Stillness after a drag before the loop starts again.
    private static let resumeDelay: Duration = .milliseconds(1500)

    /// The distance from the start of one copy to the start of the next.
    private var period: CGFloat { textWidth + Self.gap }

    private var overflows: Bool { containerWidth > 0 && textWidth > containerWidth + 1 }

    var body: some View {
        GeometryReader { geo in
            Group {
                if overflows {
                    scroller
                } else {
                    row
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .onAppear { containerWidth = geo.size.width }
            .onChange(of: geo.size.width) { _, width in
                containerWidth = width
            }
        }
        .frame(height: lineHeight)
        .clipped()
        // The measuring copy sits behind the row and does not change its height.
        .background(alignment: .leading) {
            row
                .fixedSize(horizontal: true, vertical: false)
                .hidden()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                    guard abs(width - textWidth) > 0.5 else { return }
                    textWidth = width
                }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: items.map(\.text).joined(separator: ", ")))
        .onChange(of: items) { _, _ in start() }
        .onChange(of: overflows) { _, now in
            if now {
                start()
            } else {
                running = false
                resume?.cancel()
                resume = nil
            }
        }
        .onDisappear {
            resume?.cancel()
            running = false
        }
    }

    /// Symbol and words for each fact, in one row.
    private var row: some View {
        HStack(spacing: 16) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 4) {
                    Image(systemName: item.symbol)
                        .accessibilityHidden(true)
                    Text(verbatim: item.text)
                        .lineLimit(1)
                }
            }
        }
        .appFont(.footnote)
        .foregroundStyle(.secondary)
    }

    private var scroller: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Self.gap) {
                ForEach(0..<Self.copies, id: \.self) { index in
                    row.accessibilityHidden(index != 0)
                }
            }
        }
        .scrollPosition($position)
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .onAppear { start() }
        .onScrollPhaseChange { _, phase, context in
            switch phase {
            case .tracking, .interacting, .decelerating:
                running = false
                resume?.cancel()
                resume = nil
                heldByFinger = true
            case .idle:
                guard heldByFinger else { return }
                heldByFinger = false
                let x = recenter(context.geometry.contentOffset.x)
                baseX = x
                jump(to: x)
                scheduleResume()
            case .animating:
                break
            }
        }
        .background {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !running)) { context in
                Color.clear
                    .onChange(of: context.date) { _, date in
                        advance(to: date)
                    }
            }
        }
    }

    /// Park the line at the middle copy and, when it does not fit, arm the loop.
    private func start() {
        running = false
        resume?.cancel()
        resume = nil
        heldByFinger = false
        guard overflows else { return }
        let parked = 2 * period
        baseX = parked
        jump(to: parked)
        scheduleResume()
    }

    private func scheduleResume() {
        resume?.cancel()
        guard overflows, !reduceMotion else { return }
        resume = Task {
            try? await Task.sleep(for: Self.resumeDelay)
            guard !Task.isCancelled else { return }
            baseDate = .now
            running = true
        }
    }

    /// Move the line left. Past the middle copy, jump back one period so the loop has no seam.
    private func advance(to date: Date) {
        guard running, period > 0 else { return }
        var x = baseX + Self.speed * date.timeIntervalSince(baseDate)
        if x >= 3 * period {
            x = 2 * period + positiveMod(x, period)
            baseX = x
            baseDate = date
        }
        jump(to: x)
    }

    /// The same words, shifted into the middle copy, so a jump does not change what is on screen.
    private func recenter(_ x: CGFloat) -> CGFloat {
        guard period > 0 else { return 0 }
        return 2 * period + positiveMod(x, period)
    }

    private func positiveMod(_ value: CGFloat, _ period: CGFloat) -> CGFloat {
        let remainder = value.truncatingRemainder(dividingBy: period)
        return remainder < 0 ? remainder + period : remainder
    }

    private func jump(to x: CGFloat) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            position.scrollTo(x: x)
        }
    }
}
