import OSLog
import SwiftData
import SwiftUI

struct TermHomeView: View {
    @Environment(AppSession.self) private var session
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

                    // A placeholder. The content comes later.
                    NavigationStack {
                        Color.clear
                            .navigationTitle(Text(verbatim: "Test"))
                    }
                    .tabItem { Label { Text(verbatim: "Test") } icon: { Image(systemName: "square.dashed") } }

                    NavigationStack {
                        SettingsPage()
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
        .task { openCurrentTermOnLaunch() }
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
            return lecture.state == LectureState.processing.rawValue
                || lecture.state == LectureState.failed.rawValue
                || (lecture.state == LectureState.paused.rawValue && lecture.audioRelativePath != nil && lecture.stage == PipelineStage.idle.rawValue)
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
    @State private var openedCourse: Course?
    @State private var deleteNotice: String?

    var body: some View {
        List {
            if let slot = nextSlot {
                Section {
                    hero(slot)
                }
            }
            // Two glass cards per row. They sit in the section header, like the stat tiles of a course:
            // a list row would clip the glass shadow and draw a grey band under the cards.
            // The delete of a course is in the menu icon at the end of the name row of its card.
            if !orderedCourses.isEmpty {
                Section {
                    EmptyView()
                } header: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Courses")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
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
                                        .padding(Self.cardPadding)
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
        return name.isEmpty ? yearAndTerm(term) : Text("\(Text(verbatim: name)) · \(yearAndTerm(term))")
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
                .consentFlow(course: recordCourse, isPresented: $showConsent) { course, faceID in
                    activeLecture = LectureStarter.make(course: course, faceID: faceID, context: modelContext)
                }
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 6)
        // Glass fills the whole list card; the system already insets that card from the edges.
        .listRowBackground(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(.clear)
                .glassEffect(.regular, in: .rect(cornerRadius: 26))
        )
    }

    private static let noteColumns = [
        GridItem(.flexible(), spacing: noteSpacing),
        GridItem(.flexible(), spacing: noteSpacing),
    ]
    private static let noteSpacing: CGFloat = 10
    private static let cardPadding: CGFloat = 12
    /// The same height as the course badge, so the icon is centred on the name row.
    private static let menuSize: CGFloat = 34

    /// The menu icon at the far end of the name row of a card. The favourite and the delete of the course are in it.
    private func courseMenu(_ course: Course) -> some View {
        Menu {
            Button(
                course.isFavorite ? "Remove from favorites" : "Add to favorites",
                systemImage: course.isFavorite ? "star.slash" : "star"
            ) {
                course.isFavorite.toggle()
            }
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
            HStack(spacing: 8) {
                CourseBadge(name: course.name, size: 34)
                Text(course.name)
                    .font(.headline)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // Room for the menu icon, which sits above the card at the far end of this row.
                Color.clear.frame(width: Self.menuSize, height: Self.menuSize)
            }
            // Extra height of a taller neighbour goes here, between the name and the rest, so the lecturer,
            // the totals and the times keep the same distance in every card.
            Spacer(minLength: 4)
            if let lecturer = course.lecturer?.displayName, !lecturer.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "person.crop.circle")
                    Text(verbatim: lecturer)
                        .lineLimit(1)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            // The days and times of the course in the timetable, one line each.
            VStack(alignment: .leading, spacing: 2) {
                ForEach(scheduleLines(course), id: \.self) { line in
                    Text(verbatim: line)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            HStack(spacing: 10) {
                total(course.lectures.count, "waveform", "Recordings")
                total(course.assignments.count, "checklist", "Assignments")
                total(course.sittings.count, "calendar", "Exams")
                Spacer(minLength: 0)
                // A favourite course has a star at the far end of the totals.
                if course.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
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

    private func total(_ count: Int, _ symbol: String, _ name: LocalizedStringKey) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            Text(count, format: .number)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
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

    private func slotDetail(_ slot: WeeklySlot) -> String {
        let span = "\(ReminderScheduler.clock(slot.startMinutes))–\(ReminderScheduler.clock(slot.endMinutes))"
        guard !slot.placeName.isEmpty else { return span }
        return "\(span) · \(slot.placeName)"
    }

    /// One line per weekly slot of the course, in the order of the week: "Mon 09:00–10:30".
    private func scheduleLines(_ course: Course) -> [String] {
        let calendar = Calendar.current
        let symbols = calendar.shortWeekdaySymbols
        func position(_ slot: WeeklySlot) -> Int { (slot.weekday - calendar.firstWeekday + 7) % 7 }
        return term.slots
            .filter { $0.course?.token == course.token }
            .sorted { lhs, rhs in
                if position(lhs) != position(rhs) { return position(lhs) < position(rhs) }
                return lhs.startMinutes < rhs.startMinutes
            }
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
