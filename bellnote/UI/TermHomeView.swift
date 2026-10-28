import Observation
import OSLog
import SwiftData
import SwiftUI
import UIKit

private enum HomeTab: Hashable {
    case home
    case timetable
    case files
    case assistant
    case settings
}

struct TermHomeView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Term.createdAt) private var terms: [Term]
    @Query(sort: \Lecture.startedAt, order: .reverse) private var lectures: [Lecture]

    @State private var showTerm = false
    @State private var showSlot = false
    @State private var showPending = false
    @State private var openedByDate = false
    @State private var tab = HomeTab.home
    @State private var openModels = false
    /// One look per launch. A later launch asks again while a model is still missing.
    @State private var offeredModels = false

    private var term: Term? { terms.first { $0.isOpen } ?? terms.last }

    var body: some View {
        Group {
            if let term {
                TabView(selection: $tab) {
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
                    .tag(HomeTab.home)

                    NavigationStack {
                        ProgramPage(term: term)
                    }
                    .tabItem { Label("Timetable", systemImage: "calendar.day.timeline.left") }
                    .tag(HomeTab.timetable)
                    // Off while a recording is processed — keep focus on the run.
                    .disabled(PipelineActivity.shared.isBusy)

                    NavigationStack {
                        FilesPage(term: term)
                    }
                    .tabItem { Label("Files", systemImage: "folder") }
                    .tag(HomeTab.files)

                    NavigationStack {
                        AssistantPage()
                    }
                    .tabItem { Label("Assistant", systemImage: "waveform.and.mic") }
                    .tag(HomeTab.assistant)
                    // Off while a recording is processed — Talk and the pipeline share the text model and memory.
                    .disabled(PipelineActivity.shared.isBusy)

                    NavigationStack {
                        SettingsPage(openModels: $openModels)
                    }
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                    .tag(HomeTab.settings)
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
            await offerModelsIfNeeded()
        }
        .onChange(of: term?.persistentModelID) { _, _ in
            Task { await offerModelsIfNeeded() }
        }
        .onChange(of: scenePhase) { _, phase in
            // Leaving the app clears the one-look flag, so the next open checks the models again.
            if phase == .background { offeredModels = false }
            if phase == .active {
                Task { await offerModelsIfNeeded() }
            }
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

    /// Opens Models when a text model, Whisper, or the voice models are still unset. Download stays a tap on that page.
    private func offerModelsIfNeeded() async {
        guard term != nil else { return }
        guard !offeredModels else { return }
        guard !PipelineActivity.shared.isBusy else { return }
        offeredModels = true
        let guide = await ModelSetup.current(session: session)
        guard guide.shouldGuide else { return }
        // The Models page is inside the Settings tab. Select that tab first, or the push is dropped.
        // The push waits until that move has finished, and it does not animate, so two moves do not run on the same layer.
        tab = .settings
        do {
            try await Task.sleep(for: .milliseconds(500))
        } catch {
            return
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            openModels = true
        }
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

struct TodayPage: View {
    @Bindable var term: Term
    var terms: [Term]
    @Binding var showSlot: Bool
    @Binding var showTerm: Bool
    @Binding var showPending: Bool

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppSession.self) private var session
    /// Missed and cancelled marks for a meeting. A cancelled one is left out of the card’s bar.
    @Query(sort: \LectureGap.day) private var gaps: [LectureGap]
    @State private var recordCourse: Course?
    @State private var showConsent = false
    @State private var activeLecture: Lecture?
    @State private var pendingCourse: Course?
    @State private var pendingExam: ExamSitting?
    @State private var editingExam: ExamSitting?
    /// Which exam group the home list shows. Midterms open first. A missing group falls back to one that exists.
    @State private var examKind: ExamKind = .midterm
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
    /// The dragged course order. Scrolling rebuilds the list, so the order has to live here, not only in the drag preview.
    @State private var courseOrder: [UUID] = []
    @State private var deleteNotice: String?
    /// Left edge of the first course row’s content while that row is at rest. The hero glass uses the same edge.
    /// A swipe moves the row, so that jump is not copied onto the hero.
    @State private var courseCardLeading: CGFloat = 16
    /// The latest measured edge, including while the first row is swiped.
    @State private var measuredCardLeading: CGFloat = 16
    /// After the page width changes, the next resting edge may replace `courseCardLeading`.
    @State private var acceptNextCardLeading = true
    /// Used so a width change can be told apart from a swipe.
    @State private var homeWidth: CGFloat = 0
    /// Height of the glass band as it is laid out now, open or collapsed.
    @State private var heroBandHeight: CGFloat = 0
    /// Height of the glass band while the hero is fully open. The list keeps this top margin, so shrinking the band does not jump the cards.
    @State private var heroExpandedHeight: CGFloat = 0
    /// How far the course list has moved up from its resting position.
    /// A class, not view state: scrolling updates the hero without rebuilding the list.
    @State private var heroScroll = HeroScroll()
    /// The list’s scroll view, found from the first row. A custom scroll target is not applied by the list.
    @State private var heroSnapGate = HeroSnapGate()
    /// One request to finish an open or a close. The id changes each time the finger lifts in between.
    @State private var heroSnapCommand = HeroSnapCommand()

    var body: some View {
        ZStack(alignment: .top) {
            List {
            // One row per course, in a plain list. Swipe asks to delete or opens edit. Dragging reorders.
            if !orderedCourses.isEmpty {
                Section {
                    ForEach(orderedCourses) { course in
                        let token = course.token
                        Button {
                            openedCourse = course
                        } label: {
                            noteCard(course)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            // Same kind of swipe button as delete, so it grows with the swipe instead of staying a fixed picture.
                            Button { editingCourse = course } label: {
                                Image(systemName: "pencil")
                            }
                            // The tab bar tint is primary. Without its own tint this button uses that, so the
                            // symbol stays white on a white fill in dark mode.
                            .tint(Color(.systemGray))
                            .accessibilityLabel(Text("Edit course"))
                        }
                        // Full swipe still only asks. The course stays until the confirm says yes.
                        .askToDeleteSwipe { askDelete(course) }
                        .background {
                            Color.clear.onGeometryChange(for: CGFloat.self) { proxy in
                                proxy.frame(in: .named("home")).minX
                            } action: { leading in
                                guard token == courseOrder.first else { return }
                                measuredCardLeading = leading
                                let jump = abs(leading - courseCardLeading)
                                // A swipe pulls the first row sideways. Only a resting edge, or the one after a width change, is kept.
                                guard acceptNextCardLeading || jump <= 1 else { return }
                                acceptNextCardLeading = false
                                guard jump > 0.5 else { return }
                                courseCardLeading = leading
                            }
                        }
                        .background {
                            if token == orderedCourses.first?.token {
                                HeroScrollFinder(gate: heroSnapGate, command: heroSnapCommand)
                            }
                        }
                        .homeListRowWithoutSeparator()
                    }
                    .reorderable(collectionID: HomeCourseList.courses)
                    .listRowSeparator(.hidden, edges: .all)
                }
                .listRowSeparator(.hidden, edges: .all)
                .listSectionSeparator(.hidden, edges: .all)
            }
            if !examRows.isEmpty {
                Section {
                    if groupedExamRows.count > 1 {
                        Picker("Exams", selection: examKindSelection) {
                            ForEach(groupedExamRows, id: \.kind) { group in
                                Text(verbatim: group.kind.groupTitle).tag(group.kind)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                    ForEach(shownExamRows) { row in
                        examCard(row)
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button {
                                    editingExam = sitting(for: row)
                                } label: {
                                    Image(systemName: "pencil")
                                }
                                .tint(Color(.systemGray))
                                .accessibilityLabel(Text("Edit exam"))
                            }
                            .askToDeleteSwipe { pendingExam = sitting(for: row) }
                            .homeListRowWithoutSeparator()
                    }
                }
                .listSectionSeparator(.hidden, edges: .all)
            }
        }
        // A plain list, like This week on the course page: no rounded groups, rows run from edge to edge.
        // The list’s own plate is not the system page color, so the page uses that color itself.
        .reorderContainer(for: Course.self, in: HomeCourseList.self) { difference in
            applyCourseOrder(difference)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            // Not during this view update. A clean store does not touch the database.
            Task { saveCourseOrder() }
        }
        .onChange(of: term.courses.map { $0.token.uuidString }.sorted(), initial: true) { _, _ in
            reconcileCourseOrder()
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(.systemBackground).ignoresSafeArea())
        .scrollIndicators(.hidden)
        // The list fills the page. Its first row starts under the open glass band, then scrolls up behind it.
        // The margin stays at the open height, so the band can shrink without moving the cards.
        .contentMargins(.top, courseListTopMargin, for: .scrollContent)
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            max(0, geo.contentOffset.y + geo.contentInsets.top)
        } action: { _, distance in
            heroScroll.update(distance: distance)
        }
        .onScrollPhaseChange { old, new, context in
            finishHeroSnap(from: old, to: new, geometry: context.geometry)
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
        .sheet(item: $editingExam) { sitting in
            if let course = sitting.course {
                ExamEditor(term: term, course: course, editing: sitting)
            }
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
            Text("All recordings, notes, assignments, exams, files and stickies of this course will be deleted. This cannot be undone.")
        }
        .alert(
            "Delete this exam?",
            isPresented: Binding(
                get: { pendingExam != nil },
                set: { if !$0 { pendingExam = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let sitting = pendingExam { deleteExam(sitting) }
                pendingExam = nil
            }
            Button("Cancel", role: .cancel) { pendingExam = nil }
        } message: {
            Text("This exam will be deleted. This cannot be undone.")
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
                // The scroll distance is read here, not in the page, so the course list is not rebuilt while it moves.
                OpenHero(scroll: heroScroll, lowerSpan: heroLowerSpan) { collapse in
                    // Fixed over the list. Scrolling the courses up collapses this glass; scrolling back opens it.
                    hero(slot, collapse: collapse)
                        .foregroundStyle(.primary)
                        // 8 pt under the navigation bar, then the course row.
                        // The glass uses the same left edge as the course rows.
                        .padding(.horizontal, courseCardLeading)
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
                            // Only while open. During the collapse the live height is shorter on purpose.
                            guard collapse < 0.02 else { return }
                            if heroExpandedHeight == 0, abs(height - heroBandHeight) > 0.5 {
                                heroBandHeight = height
                            }
                            guard abs(height - heroExpandedHeight) > 0.5 else { return }
                            heroExpandedHeight = height
                        }
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            let firstReading = homeWidth == 0
            guard abs(width - homeWidth) > 0.5 else { return }
            homeWidth = width
            // The first reading is not a rotation. The row’s own measurement sets the edge.
            guard !firstReading else { return }
            acceptNextCardLeading = true
            let jump = abs(measuredCardLeading - courseCardLeading)
            guard jump > 0.5 else { return }
            courseCardLeading = measuredCardLeading
            acceptNextCardLeading = false
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
        let courses = term.courses
        guard !courseOrder.isEmpty else { return fallbackSorted(courses) }
        var byToken: [UUID: Course] = [:]
        for course in courses { byToken[course.token] = course }
        return courseOrder.compactMap { byToken[$0] }
    }

    /// Order before the student drags. A saved `homeOrder` wins. Courses that still share one number sort by the latest lecture, then by name.
    private func fallbackSorted(_ courses: [Course]) -> [Course] {
        courses.sorted { lhs, rhs in
            if lhs.homeOrder != rhs.homeOrder { return lhs.homeOrder < rhs.homeOrder }
            let left = lhs.lectures.map(\.startedAt).max() ?? .distantPast
            let right = rhs.lectures.map(\.startedAt).max() ?? .distantPast
            if left != right { return left > right }
            return lhs.name.localizedCompare(rhs.name) == .orderedAscending
        }
    }

    /// Keeps a new or deleted course in the dragged order without shuffling the rows the student already placed.
    private func reconcileCourseOrder() {
        let courses = term.courses
        let tokens = Set(courses.map(\.token))
        if courseOrder.isEmpty {
            let sorted = fallbackSorted(courses)
            courseOrder = sorted.map(\.token)
            logOrder("opened", sorted)
            return
        }
        var order = courseOrder.filter { tokens.contains($0) }
        let known = Set(order)
        order.append(contentsOf: fallbackSorted(courses.filter { !known.contains($0.token) }).map(\.token))
        if order != courseOrder { courseOrder = order }
    }

    /// Writes the dragged order into the list and onto each course, so a later scroll builds the same list.
    private func applyCourseOrder(_ difference: ReorderDifference<Course.ID, HomeCourseList>) {
        var rows = orderedCourses
        let moving = difference.sources.compactMap { id in rows.first { $0.id == id } }
        let destination: String
        switch difference.destination.position {
        case .end:
            destination = "end"
        case .before(let id):
            destination = "before \(rows.first { $0.id == id }?.name ?? "missing")"
        }
        let movingNames = moving.map(\.name).joined(separator: ", ")
        logOrder("drop sources=\(difference.sources.count) matched=\(moving.count) moving=\(movingNames) \(destination)", rows)
        guard moving.count == difference.sources.count, !moving.isEmpty else {
            logOrder("drop ignored", rows)
            return
        }
        let sourceIDs = Set(difference.sources)
        // The place is taken before the dragged rows leave. If the target is the dragged row, it is still here.
        // Removing it first made "before this row" miss, and the row was appended at the end.
        let destinationIndex: Int
        switch difference.destination.position {
        case .end:
            destinationIndex = rows.count
        case .before(let id):
            destinationIndex = rows.firstIndex { $0.id == id } ?? rows.count
        }
        let removedBefore = rows.prefix(destinationIndex).filter { sourceIDs.contains($0.id) }.count
        rows.removeAll { sourceIDs.contains($0.id) }
        let index = min(destinationIndex - removedBefore, rows.count)
        rows.insert(contentsOf: moving, at: index)
        commitCourseOrder(rows)
    }

    /// Keeps the new order in view state and on each course. The next launch reads `homeOrder`.
    private func commitCourseOrder(_ rows: [Course]) {
        courseOrder = rows.map(\.token)
        for (place, course) in rows.enumerated() {
            course.homeOrder = place
        }
        logOrder("write", rows)
        saveCourseOrder()
    }

    /// Writes the order when a row’s place actually changed. An unchanged list does not open the database.
    private func saveCourseOrder() {
        let rows = orderedCourses
        guard !rows.isEmpty else { return }
        for (place, course) in rows.enumerated() where course.homeOrder != place {
            course.homeOrder = place
        }
        guard modelContext.hasChanges else { return }
        do {
            try modelContext.save()
            logOrder("saved", rows)
        } catch {
            let detail = error.localizedDescription
            print("home order save failed: \(detail)")
            Logger(subsystem: "app.bellnote", category: "home-order").error("Save failed: \(detail, privacy: .public)")
        }
    }

    /// The list stops where the finger lifts. Move it the rest of the way once that stop is inside the hero.
    private func finishHeroSnap(from old: ScrollPhase, to new: ScrollPhase, geometry: ScrollGeometry) {
        let distance = max(0, geometry.contentOffset.y + geometry.contentInsets.top)
        let span = heroLowerSpan
        // Idle after the system’s own deceleration. Animating is the finish we just started, so it must not start another.
        guard new == .idle, old != .idle, old != .animating else { return }
        guard nextSlot != nil, span > 1, distance > 0.5, distance < span - 0.5 else { return }
        let delta = (heroScroll.closing ? span : 0) - distance
        heroSnapCommand = HeroSnapCommand(id: heroSnapCommand.id + 1, delta: delta)
    }

    /// Xcode console lines for a drag that does not survive a relaunch. `homeOrder` is what the next launch reads.
    private func logOrder(_ event: String, _ courses: [Course]) {
        let line = courses.map { "\($0.name)=\($0.homeOrder)" }.joined(separator: " | ")
        print("home order \(event): \(line)")
        Logger(subsystem: "app.bellnote", category: "home-order").notice("\(event, privacy: .public): \(line, privacy: .public)")
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
                    title: sitting.title,
                    date: sitting.date,
                    startMinutes: sitting.startMinutes,
                    endMinutes: sitting.endMinutes,
                    place: sitting.place,
                    score: sitting.scoreText
                )
            }
        }
    }

    /// Midterms, then finals, then any other kind. A kind with no sitting is left out.
    /// The nearest-first order stays inside each group, and an overlap can still cross groups.
    private var groupedExamRows: [(kind: ExamKind, rows: [ExamRow])] {
        let marked = ExamSort.markingOverlaps(examRows)
        return ExamKind.allCases.compactMap { kind in
            let rows = marked.filter { (ExamKind(rawValue: $0.kind) ?? .other) == kind }
            return rows.isEmpty ? nil : (kind, rows)
        }
    }

    /// The group on screen. A chosen kind that has no sitting falls back to the first group that does.
    private var shownExamRows: [ExamRow] {
        let groups = groupedExamRows
        let kind = groups.contains(where: { $0.kind == examKind }) ? examKind : (groups.first?.kind ?? .midterm)
        return groups.first { $0.kind == kind }?.rows ?? []
    }

    private var examKindSelection: Binding<ExamKind> {
        Binding(
            get: {
                let groups = groupedExamRows
                if groups.contains(where: { $0.kind == examKind }) { return examKind }
                return groups.first?.kind ?? .midterm
            },
            set: { examKind = $0 }
        )
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
        let band = heroExpandedHeight > 0 ? heroExpandedHeight : heroBandHeight
        return band + Self.heroToListGap
    }

    /// The fact line, including the gap above it. This part of the band closes with the scroll.
    private var heroFactSpan: CGFloat {
        heroDetailLineHeight + 16
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

    @ViewBuilder
    private func hero(_ slot: WeeklySlot, collapse: CGFloat) -> some View {
        let name = slot.course?.name ?? String(localized: "Course")
        let tint = slot.course?.color ?? CourseStyle.color(for: name)
        let lecturer = slot.course?.lecturer?.displayName ?? ""
        let nameSize = heroNameSize + (heroCollapsedSize - heroNameSize) * collapse
        VStack(alignment: .leading, spacing: 0) {
            // Open: badge, name, lecturer, and the large time on the bottom of that row.
            // Closed: the name and the time only, at the same size.
            HStack(alignment: .bottom, spacing: 10 * (1 - collapse)) {
                CourseBadge(name: name, color: tint, size: heroBadgeSize, outlined: true)
                    .frame(
                        width: heroBadgeSize * (1 - collapse),
                        height: heroOpenRow * (1 - collapse) + heroCollapsedLineHeight * collapse,
                        alignment: .bottom
                    )
                    .clipped()
                    // Size follows the whole collapse. The fade finishes in the first half,
                    // and the icon only returns in the last half of the opening.
                    .opacity(max(0, 1 - collapse * 2))
                    .accessibilityHidden(collapse > 0.5)
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
                .padding(.top, 16)
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
        let place = PlacePreset.displayName(for: slot.placeName)
        if !place.isEmpty {
            items.append(HeroDetailItem(symbol: "mappin.and.ellipse", text: place))
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

    /// The glass band. Square at the top of the screen. The bottom corners match the old hero card.
    private var heroBandShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            bottomLeadingRadius: 22,
            bottomTrailingRadius: 22,
            style: .continuous
        )
    }

    /// Inside the hero glass: the badge and the time sit on the glass edge.
    private static let heroContentSidePadding: CGFloat = 0
    /// Room under the course row, inside the glass.
    private static let heroVerticalPadding: CGFloat = 12
    /// Room above the course row, inside the glass. The gap under the navigation bar is 8 pt.
    private static let heroContentTopPadding: CGFloat = 8
    /// Extra room under the hero content, above the course cards. The top gap is separate and is 0.
    private static let heroTopInset: CGFloat = 4
    /// Room between the bottom edge of the hero glass and the first course title.
    private static let heroToListGap: CGFloat = 16
    /// The course icon on a list row, before it grows to the two slot lines.
    private static let courseBadgeSize: CGFloat = 34

    /// Height the icon, the name, and the lecturer grow to. It stays the two 15 pt slot lines,
    /// including the gap between them and the counts on the lower line. The dates themselves are smaller.
    private var datePairHeight: CGFloat {
        let slot = UIFont.preferredFont(forTextStyle: .subheadline).lineHeight
        let counts = UIFont.systemFont(ofSize: courseTotalSize).lineHeight
        return slot + 2 + max(slot, counts)
    }

    /// The icon, the name, and the lecturer before they grow.
    private var courseIdentityHeight: CGFloat {
        let namePoint = UIFont.preferredFont(forTextStyle: .subheadline).pointSize
        let lecturerPoint = UIFont.preferredFont(forTextStyle: .caption2).pointSize
        let name = UIFont.systemFont(ofSize: namePoint, weight: .semibold).lineHeight
        let lecturer = UIFont.systemFont(ofSize: lecturerPoint).lineHeight
        return max(Self.courseBadgeSize, name + lecturer)
    }

    /// One factor for the icon, the name, and the lecturer, so the group matches the two slot lines.
    private var courseIdentityScale: CGFloat {
        let natural = courseIdentityHeight
        guard natural > 1 else { return 1 }
        return datePairHeight / natural
    }

    /// Recordings, assignments, and exams on the course card. Footnote size, regular weight.
    @ScaledMetric(relativeTo: .footnote) private var courseTotalSize: CGFloat = 13

    /// One course as a list row. The three numbers are the totals of the whole course, not of one week.
    private func noteCard(_ course: Course) -> some View {
        let lecturer = course.lecturer?.displayName ?? ""
        let share = recordedShare(for: course)
        return VStack(alignment: .leading, spacing: 6) {
            // The icon, the name, and the lecturer stay as tall as two 15 pt date lines.
            // Dates sit to their right, on the bottom of that block. The three counts stay on the lower date, at the trailing corner.
            HStack(alignment: .bottom, spacing: 10) {
                HStack(alignment: .bottom, spacing: 10) {
                    CourseBadge(name: course.name, color: course.color, size: Self.courseBadgeSize * courseIdentityScale, outlined: true, borderColor: .secondary)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(course.name)
                            .appFont(size: UIFont.preferredFont(forTextStyle: .subheadline).pointSize * courseIdentityScale, weight: .semibold)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(verbatim: lecturer.isEmpty ? String(localized: "Lecturer") : lecturer)
                            .appFont(size: UIFont.preferredFont(forTextStyle: .caption2).pointSize * courseIdentityScale)
                            .foregroundStyle(lecturer.isEmpty ? Color.secondary : Color.primary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                scheduleAndCounts(course)
            }
            if let share {
                ProgressView(value: Double(share.recorded), total: Double(share.past))
                    .progressViewStyle(AttendanceGlassProgressStyle(tint: course.color))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(recordedAccessLabel(share))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Plain buttons only hit what is drawn. The empty part of the row, such as beside a short title, counts too.
        .contentShape(.rect)
    }

    /// Up to two slots, on the right of the name. The nearest sits above.
    /// The last slot shares its line with the three counts, which stay at the trailing corner.
    /// A course with fewer than two still keeps the height of two, so every row is the same length.
    private func scheduleAndCounts(_ course: Course) -> some View {
        let lines = scheduleLines(course)
        let earlier = Array(lines.dropLast())
        let lastIsNearest = earlier.isEmpty
        return VStack(alignment: .leading, spacing: 2) {
            if let first = earlier.first {
                scheduleLine(first, nearest: true)
            } else {
                reservedScheduleLine()
            }
            HStack(alignment: .center, spacing: 10) {
                if let last = lines.last {
                    scheduleLine(last, nearest: lastIsNearest)
                } else {
                    reservedScheduleLine()
                }
                total(course.lectures.count, "waveform", "Recordings")
                total(course.assignments.count, "checklist", "Assignments")
                total(course.sittings.count, "calendar", "Exams")
            }
        }
        .fixedSize(horizontal: true, vertical: true)
        .layoutPriority(1)
    }

    /// One weekly slot, with a list bullet in front. The nearest slot is primary. The rest are secondary.
    private func scheduleLine(_ line: String, nearest: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: "•")
                .accessibilityHidden(true)
            Text(verbatim: line)
                .lineLimit(1)
        }
        .appFont(.footnote)
        .foregroundStyle(nearest ? Color.primary : Color.secondary)
    }

    /// The height of one slot, with nothing to read. The width stays out of the row, so a short date column does not grow.
    private func reservedScheduleLine() -> some View {
        scheduleLine("00:00–00:00", nearest: false)
            .hidden()
            .accessibilityHidden(true)
            .fixedSize(horizontal: true, vertical: true)
            .frame(width: 0, alignment: .leading)
    }

    private func recordedAccessLabel(_ share: RecordedShare) -> Text {
        Text(verbatim: String(format: String(localized: "%1$lld of %2$lld recorded"), share.recorded, share.past))
    }

    /// Past meetings of one course, and how many of them have a recording.
    private struct RecordedShare {
        var recorded: Int
        var past: Int
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

    /// Count chip on a course row. Zero stays secondary. A real count, icon and number, is primary.
    private func total(_ count: Int, _ symbol: String, _ name: LocalizedStringKey) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            Text(count, format: .number)
        }
        .appFont(size: courseTotalSize)
        .foregroundStyle(count > 0 ? Color.primary : Color.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(name))
        .accessibilityValue(Text(count, format: .number))
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

    /// Up to two weekly slots, nearest upcoming first ("Mon 09:00–10:30").
    private func scheduleLines(_ course: Course) -> [String] {
        let symbols = Calendar.current.shortWeekdaySymbols
        let lines = term.slots
            .filter { $0.course?.token == course.token }
            .sorted { minutesUntilNextOccurrence($0) < minutesUntilNextOccurrence($1) }
            .compactMap { slot -> String? in
                guard symbols.indices.contains(slot.weekday - 1) else { return nil }
                let span = "\(ReminderScheduler.clock(slot.startMinutes))–\(ReminderScheduler.clock(slot.endMinutes))"
                return "\(symbols[slot.weekday - 1]) \(span)"
            }
        return Array(lines.prefix(2))
    }

    /// One sitting, in the same arrangement as a course row. The kind leads. The day and the time sit on the right.
    /// A typed score sits in the horizontal middle and on the bottom edge, with Gedik’s letter and result beside it.
    /// A past day strikes that day and time.
    private func examCard(_ row: ExamRow) -> some View {
        let tint = term.courses.first { $0.name == row.courseName }?.color ?? CourseStyle.color(for: row.courseName)
        let place = PlacePreset.displayName(for: row.place)
        let courseLine = place.isEmpty ? row.courseName : "\(row.courseName) · \(place)"
        let score = row.score.trimmingCharacters(in: .whitespacesAndNewlines)
        let past = examIsPast(row)
        let nameSize = UIFont.preferredFont(forTextStyle: .subheadline).pointSize * courseIdentityScale
        let detailSize = UIFont.preferredFont(forTextStyle: .caption2).pointSize * courseIdentityScale
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 10) {
                CourseBadge(
                    name: row.courseName,
                    color: tint,
                    size: Self.courseBadgeSize * courseIdentityScale,
                    outlined: true,
                    borderColor: .secondary
                )
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: examKindTitle(row))
                        .appFont(size: nameSize, weight: .semibold)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(verbatim: courseLine)
                        .appFont(size: detailSize)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let grade = ExamGrade.mark(for: score) {
                    let result = String(localized: String.LocalizationValue(grade.result.rawValue))
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(verbatim: score)
                            .appFont(.footnote, weight: .semibold, digits: true)
                            .foregroundStyle(CourseStyle.scoreTint(grade.result))
                        Text(verbatim: " · \(grade.letter) · \(result)")
                            .appFont(.footnote)
                            .foregroundStyle(.primary)
                    }
                    .lineLimit(1)
                    .fixedSize()
                    .accessibilityLabel(
                        Text(verbatim: "\(String(format: String(localized: "Score %@"), score)) \(grade.letter) \(result)")
                    )
                }
                VStack(alignment: .trailing, spacing: 2) {
                    Text(verbatim: examDay(row))
                        .appFont(.footnote, weight: .semibold)
                        .foregroundStyle(past ? Color.secondary : Color.primary)
                        .strikethrough(past)
                        .lineLimit(1)
                    Text(verbatim: examClock(row))
                        .appFont(.footnote)
                        .foregroundStyle(.secondary)
                        .strikethrough(past)
                        .lineLimit(1)
                }
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: score.isEmpty ? nil : .infinity, alignment: .trailing)
            }
            if let approach = examApproach(row) {
                ProgressView(value: approach)
                    .progressViewStyle(AttendanceGlassProgressStyle(tint: tint))
                    .accessibilityHidden(true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
            if row.overlaps {
                Text("Overlaps another sitting.")
                    .appFont(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    /// A sitting whose day is before today. Today stays open. No date is not past.
    private func examIsPast(_ row: ExamRow) -> Bool {
        guard let date = row.date else { return false }
        let calendar = Calendar.current
        return calendar.startOfDay(for: date) < calendar.startOfDay(for: .now)
    }

    /// How far the term has come toward this exam. 0 at the term’s start, 1 on the exam day and after.
    /// Nil when the sitting has no date.
    private func examApproach(_ row: ExamRow) -> Double? {
        guard let date = row.date else { return nil }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let exam = calendar.startOfDay(for: date)
        if today >= exam { return 1 }
        let start = calendar.startOfDay(for: term.startsOn)
        let span = calendar.dateComponents([.day], from: start, to: exam).day ?? 0
        guard span > 0 else { return 0 }
        let elapsed = calendar.dateComponents([.day], from: start, to: today).day ?? 0
        return min(1, max(0, Double(elapsed) / Double(span)))
    }

    /// Midterm, final, or the name typed for another exam.
    private func examKindTitle(_ row: ExamRow) -> String {
        let title = row.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if ExamKind(rawValue: row.kind) == .other, !title.isEmpty { return title }
        switch ExamKind(rawValue: row.kind) {
        case .midterm: return String(localized: "Midterm")
        case .final: return String(localized: "Final")
        case .other: return String(localized: "Other")
        case nil: return String(localized: "Exam")
        }
    }

    private func examDay(_ row: ExamRow) -> String {
        row.date?.formatted(.dateTime.day().month(.abbreviated).locale(session.locale))
            ?? String(localized: "Date not set")
    }

    private func examClock(_ row: ExamRow) -> String {
        guard let start = row.startMinutes else { return String(localized: "Time not set") }
        if let end = row.endMinutes, end > start {
            return "\(ReminderScheduler.clock(start))–\(ReminderScheduler.clock(end))"
        }
        return ReminderScheduler.clock(start)
    }

    private func askDelete(_ course: Course) {
        guard course.lectures.allSatisfy(LectureRemoval.canDelete) else {
            deleteNotice = String(localized: "Wait until the recordings of this course have been processed, then delete it.")
            return
        }
        pendingCourse = course
    }

    private func sitting(for row: ExamRow) -> ExamSitting? {
        term.courses.flatMap(\.sittings).first { $0.token == row.id }
    }

    /// Removes one sitting and its reminder. The course and its recordings stay.
    private func deleteExam(_ sitting: ExamSitting) {
        let name = sitting.course?.name ?? ""
        sitting.reminderKind = ReminderKind.none.rawValue
        ReminderScheduler.replaceExam(sitting, courseName: name)
        modelContext.delete(sitting)
        do {
            try modelContext.save()
        } catch {
            Logger(subsystem: "app.bellnote", category: "delete").error(
                "Exam delete failed: \(error.localizedDescription, privacy: .public)"
            )
        }
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

/// The home attendance bar. The track is the system progress track. The filled part is Liquid Glass
/// in the course color, because the system fill cannot be glass.
private struct AttendanceGlassProgressStyle: ProgressViewStyle {
    var tint: Color
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        let fraction = configuration.fractionCompleted ?? 0
        GeometryReader { geo in
            let width = max(0, geo.size.width * fraction)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                if width > 0 {
                    Capsule()
                        .fill(.clear)
                        .frame(width: width, height: geo.size.height)
                        .glassEffect(glass, in: .capsule)
                }
            }
        }
        .frame(height: 4)
    }

    private var glass: Glass {
        .regular.tint(tint.opacity(colorScheme == .dark ? 0.5 : 0.28))
    }
}

extension View {
    /// The plain list keeps the hairline between rows. Hiding it is not enough, so the line is also given no length. Row insets stay as they are.
    fileprivate func homeListRowWithoutSeparator() -> some View {
        listRowSeparator(.hidden, edges: .all)
            .alignmentGuide(.listRowSeparatorLeading) { $0[.trailing] }
            .alignmentGuide(.listRowSeparatorTrailing) { $0[.trailing] }
    }
}

/// The course rows are one reorderable collection. Exams in the same list are not part of it.
private enum HomeCourseList: Hashable, Sendable {
    case courses
}

/// How far the course list has moved. The hero reads `distance`. The list does not, so a scroll does not rebuild the rows.
@Observable
private final class HeroScroll {
    var distance: CGFloat = 0
    /// True when the last movement was upward, which closes the hero.
    @ObservationIgnored private(set) var closing = false
    @ObservationIgnored private var last: CGFloat = 0

    func update(distance: CGFloat) {
        guard abs(distance - last) > 0.5 else { return }
        closing = distance > last
        last = distance
        self.distance = distance
    }
}

/// One finish request. `id` changes when the finger lifts between open and closed.
private struct HeroSnapCommand: Equatable {
    var id = 0
    var delta: CGFloat = 0
}

/// Holds the list’s scroll view. The finder and the page share this, so a row refresh does not forget it.
@MainActor
private final class HeroSnapGate {
    var applied = 0
    weak var scrollView: UIScrollView?
}

/// Finds the list scroll view from the first course row and applies one finish.
private struct HeroScrollFinder: UIViewRepresentable {
    var gate: HeroSnapGate
    var command: HeroSnapCommand

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        if gate.scrollView == nil || gate.scrollView?.window == nil {
            gate.scrollView = Self.scrollView(from: view)
        }
        guard command.id != gate.applied else { return }
        guard let scroll = gate.scrollView else { return }
        gate.applied = command.id
        let delta = command.delta
        // The next turn, so this is not inside the scroll view’s own end callback, which ignores a new offset.
        DispatchQueue.main.async {
            var offset = scroll.contentOffset
            offset.y += delta
            scroll.setContentOffset(offset, animated: true)
        }
    }

    private static func scrollView(from view: UIView) -> UIScrollView? {
        var current: UIView? = view.superview
        while let next = current {
            if let scroll = next as? UIScrollView { return scroll }
            current = next.superview
        }
        // A row background is sometimes hosted beside the list, not inside it.
        guard let window = view.window else { return nil }
        let point = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: window)
        return collectionView(in: window, containing: point)
    }

    private static func collectionView(in view: UIView, containing point: CGPoint) -> UIScrollView? {
        if let collection = view as? UICollectionView, let window = collection.window {
            let local = window.convert(point, to: collection)
            if collection.bounds.contains(local) { return collection }
        }
        for child in view.subviews.reversed() {
            if let found = collectionView(in: child, containing: point) { return found }
        }
        return nil
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

/// Draws the open hero and collapses it from the list’s scroll distance.
private struct OpenHero<Content: View>: View {
    var scroll: HeroScroll
    var lowerSpan: CGFloat
    @ViewBuilder var content: (CGFloat) -> Content

    private var collapse: CGFloat {
        guard lowerSpan > 1 else { return 0 }
        return min(1, max(0, scroll.distance / lowerSpan))
    }

    var body: some View {
        content(collapse)
    }
}
