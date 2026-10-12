import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct TermEditor: View {
    var terms: [Term]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var year = 1
    @State private var termNumber = 1
    @State private var name = ""
    @State private var start = Date()
    @State private var end = Calendar.current.date(byAdding: .month, value: 4, to: Date()) ?? Date()

    var body: some View {
        NavigationStack {
            Form {
                Stepper(value: $year, in: 1...12) {
                    Text("Year \(year)")
                }
                Stepper(value: $termNumber, in: 1...4) {
                    Text("Term \(termNumber)")
                }
                TextField("Name", text: $name)
                DatePicker("Starts", selection: $start, displayedComponents: .date)
                DatePicker("Ends", selection: $end, displayedComponents: .date)
            }
            .navigationTitle("Term")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        for term in terms { term.isOpen = false }
        let term = Term(
            yearOfStudy: year,
            termNumber: termNumber,
            customName: name,
            startsOn: start,
            endsOn: end,
            isOpen: true
        )
        modelContext.insert(term)
        dismiss()
    }
}

struct CourseEditor: View {
    var term: Term
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var locale = Locale.current.identifier

    var body: some View {
        NavigationStack {
            Form {
                TextField("Course", text: $name)
                TextField("Locale", text: $locale)
            }
            .navigationTitle("Course")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let course = Course(name: name, localeIdentifier: locale, term: term)
                        modelContext.insert(course)
                        term.courses.append(course)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

struct PendingSheet: View {
    var lectures: [Lecture]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var selection = Set<PersistentIdentifier>()

    var body: some View {
        NavigationStack {
            List(lectures, selection: $selection) { lecture in
                VStack(alignment: .leading) {
                    Text(lecture.course?.name ?? "")
                    Text(lecture.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                    Text(lecture.stage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Pending")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Process all") {
                        Task { await process() }
                    }
                    .disabled(selection.isEmpty)
                }
            }
        }
    }

    private func process() async {
        let chosen = lectures.filter { selection.contains($0.persistentModelID) }
        for lecture in chosen {
            await LecturePipeline.advance(
                lecture: lecture,
                context: modelContext,
                preferTaggerForPage: UserDefaults.standard.bool(forKey: AppPreferences.pagePrefersTaggerKey)
            )
        }
    }
}

struct AssignmentSheet: View {
    @Bindable var course: Course
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(course.assignments) { assignment in
                HStack {
                    VStack(alignment: .leading) {
                        Text(assignment.text)
                        if let due = assignment.due {
                            Text(due.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption)
                        } else {
                            Text("No date was spoken.")
                                .font(.caption)
                        }
                    }
                    Spacer()
                    Toggle("Done", isOn: Bindable(assignment).done)
                        .labelsHidden()
                }
            }
            .navigationTitle("Assignments")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct SettingsSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var choice: AppLanguage = .system

    var body: some View {
        NavigationStack {
            Form {
                Picker("Language", selection: $choice) {
                    Text("System").tag(AppLanguage.system)
                    Text("English").tag(AppLanguage.english)
                    Text("Turkish").tag(AppLanguage.turkish)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        session.setLanguage(choice)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

struct ModelsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var budget = DeviceBudget(freeDiskBytes: 0, physicalMemoryBytes: 0)
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                modelRow(.tagger, title: "2B", bytes: ModelCatalog.taggerBytes, locked: ModelLock.taggerLocked(budget))
                modelRow(.page, title: "4B", bytes: ModelCatalog.pageBytes, locked: ModelLock.pageLocked(budget))
            }
            .navigationTitle("Models")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .task { refreshBudget() }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func modelRow(_ role: ModelRole, title: String, bytes: Int64, locked: Bool) -> some View {
        VStack(alignment: .leading) {
            Text(title)
            Text(bytes.formatted(.byteCount(style: .file)))
                .font(.caption)
                .foregroundStyle(.secondary)
            if locked {
                Text(role == .tagger ? "Needs 2 GB free." : "Needs 4 GB free and 8 GB of memory.")
                    .font(.caption)
            } else {
                Button("Download") {
                    Task {
                        do {
                            try await LocalModelRuntime.shared.download(role)
                            message = String(localized: "Download finished.")
                        } catch {
                            message = String(localized: "A model is not available.")
                        }
                    }
                }
            }
            if let message {
                Text(message)
                    .font(.caption)
            }
        }
    }

    private func refreshBudget() {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let free = values?.volumeAvailableCapacityForImportantUsage ?? 0
        budget = DeviceBudget(freeDiskBytes: free, physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory)
    }
}

struct TimetableSheet: View {
    var term: Term
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var weekday = Calendar.current.component(.weekday, from: .now)
    @State private var start = Date()
    @State private var end = Date()
    @State private var courseToken: UUID?
    @State private var place = ""
    @State private var showImporter = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(term.slots) { slot in
                        Text("\(weekdayName(slot.weekday)) \(ReminderScheduler.clock(slot.startMinutes))")
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            modelContext.delete(term.slots[index])
                        }
                    }
                }
                Section("Add") {
                    Picker("Weekday", selection: $weekday) {
                        ForEach(1...7, id: \.self) { day in
                            Text(weekdayName(day)).tag(day)
                        }
                    }
                    DatePicker("Start", selection: $start, displayedComponents: .hourAndMinute)
                    DatePicker("End", selection: $end, displayedComponents: .hourAndMinute)
                    Picker("Course", selection: $courseToken) {
                        Text("None").tag(UUID?.none)
                        ForEach(term.courses) { course in
                            Text(course.name).tag(Optional(course.token))
                        }
                    }
                    TextField("Place", text: $place)
                    Button("Add slot") { addSlot() }
                }
                Section {
                    Button("Import schedule") { showImporter = true }
                }
                Section("Hours") {
                    let rows = HoursChart.weekly(slots: term.slots.map {
                        ($0.course?.name ?? "", $0.startMinutes, $0.endMinutes)
                    })
                    ForEach(rows, id: \.courseName) { row in
                        Text("\(row.courseName) \(row.weeklyMinutes) min")
                    }
                    let weekly = rows.reduce(0) { $0 + $1.weeklyMinutes }
                    let weeks = HoursChart.weekCount(start: term.startsOn, end: term.endsOn)
                    Text("Term \(HoursChart.termTotal(weeklyMinutes: weekly, weekCount: weeks, cancelledWeeks: term.cancelledWeeks.count)) min")
                        .font(.footnote)
                }
            }
            .navigationTitle("Timetable")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf, .image]) { result in
                if case let .success(url) = result {
                    _ = url
                } else if case let .failure(error) = result {
                    place = error.localizedDescription
                }
            }
        }
    }

    private func addSlot() {
        let course = term.courses.first { $0.token == courseToken }
        let slot = WeeklySlot(
            weekday: weekday,
            startMinutes: minutes(start),
            endMinutes: minutes(end),
            course: course,
            term: term,
            placeName: place
        )
        modelContext.insert(slot)
        term.slots.append(slot)
    }

    private func minutes(_ date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    private func weekdayName(_ day: Int) -> String {
        let symbols = Calendar.current.weekdaySymbols
        guard symbols.indices.contains(day - 1) else { return "" }
        return symbols[day - 1]
    }
}

struct StudySheet: View {
    var course: Course
    var mode: StudyMode
    @Environment(\.dismiss) private var dismiss
    @State private var prompt = ""
    @State private var answer = ""
    @State private var reader = SpeechReader()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField(mode == .ask ? "Ask" : "Quiz", text: $prompt)
                    Button("Run") { Task { await run() } }
                }
                if !answer.isEmpty {
                    Section {
                        Text(answer)
                        Button("Listen") {
                            reader.read(answer, locale: Locale(identifier: course.localeIdentifier))
                        }
                    }
                }
            }
            .navigationTitle(mode == .ask ? "Ask" : "Quiz")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func run() async {
        let blocks = course.lectures.flatMap { lecture in
            lecture.blocks.map { block in
                StudyBlock(
                    id: block.token,
                    at: lecture.startedAt,
                    second: block.second,
                    kind: BlockKind(tag: block.kind),
                    text: block.text,
                    topics: block.topics,
                    listItems: block.listItems,
                    numbers: block.numbers,
                    importance: block.importance,
                    missing: block.missing,
                    userFlag: block.userFlag,
                    examScope: block.kind == BlockKind.examScope.rawValue
                )
            }
        }
        let selected = StudySelection.select(blocks, filter: .wholeCourse)
        guard !selected.isEmpty else {
            answer = String(localized: "The lectures do not contain that.")
            return
        }
        let tags = selected.map {
            WindowTag(
                language: course.localeIdentifier,
                speakerRole: "narrator",
                kind: $0.kind.rawValue,
                topics: $0.topics,
                text: $0.text,
                listItems: $0.listItems,
                numbers: $0.numbers,
                importanceCue: $0.importance,
                missing: $0.missing
            )
        }
        do {
            answer = try await LocalModelRuntime.shared.compose(tags: tags, task: prompt)
        } catch {
            answer = String(localized: "A model is not available.")
        }
    }
}
