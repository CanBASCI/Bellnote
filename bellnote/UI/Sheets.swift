import OSLog
import SwiftData
import SwiftUI

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
    @State private var language = AppLanguage.deviceCourseDefault

    var body: some View {
        NavigationStack {
            Form {
                TextField("Course", text: $name)
                Picker("Language", selection: $language) {
                    ForEach(AppLanguage.courseChoices, id: \.self) { item in
                        Text(LocalizedStringKey(item.title)).tag(item)
                    }
                }
                .pickerStyle(.menu)
            }
            .navigationTitle("Course")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let course = Course(name: name, localeIdentifier: language.speechLocaleIdentifier, term: term)
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
    @State private var running = false
    @State private var workingStage: PipelineStage?
    @State private var fluidGate = FluidAudioGate()

    var body: some View {
        NavigationStack {
            List(lectures) { lecture in
                NavigationLink {
                    LecturePage(lecture: lecture)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(lecture.course?.name ?? String(localized: "Course"))
                        Text(lecture.startedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(LectureState(rawValue: lecture.state)?.title ?? lecture.state)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if let failure = lecture.failureMessageKey, !failure.isEmpty {
                            Text(String(localized: String.LocalizationValue(failure)))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let workingStage {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: workingStage.fraction)
                        Text(workingStage.title)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar)
                }
            }
            .navigationTitle("Pending")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Process") {
                        fluidGate.request { await process() }
                    }
                    .disabled(lectures.isEmpty || running)
                }
            }
        }
        .fluidAudioGate(fluidGate)
        .presentationDetents([.medium, .large])
    }

    private func process() async {
        running = true
        defer {
            running = false
            workingStage = nil
        }
        for lecture in lectures {
            workingStage = PipelineStage(rawValue: lecture.stage)?.next ?? .audio
            await LecturePipeline.advance(
                lecture: lecture,
                context: modelContext,
                preferTaggerForPage: UserDefaults.standard.bool(forKey: AppPreferences.pagePrefersTaggerKey)
            ) { stage in
                workingStage = stage
            }
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

struct SettingsPage: View {
    var terms: [Term]
    @Environment(AppSession.self) private var session
    @State private var choice: AppLanguage = {
        let stored = UserDefaults.standard.string(forKey: AppPreferences.languageKey) ?? AppLanguage.system.rawValue
        return AppLanguage(rawValue: stored) ?? .system
    }()
    @State private var appearance: AppAppearance = {
        let stored = UserDefaults.standard.string(forKey: AppPreferences.appearanceKey) ?? AppAppearance.system.rawValue
        return AppAppearance(rawValue: stored) ?? .system
    }()
    @State private var showTerm = false

    var body: some View {
        Form {
            Picker("Language", selection: $choice) {
                Text("System").tag(AppLanguage.system)
                Text("English").tag(AppLanguage.english)
                Text("Turkish").tag(AppLanguage.turkish)
            }
            .onChange(of: choice) { _, newValue in
                session.setLanguage(newValue)
            }
            Picker("Appearance", selection: $appearance) {
                Text("System").tag(AppAppearance.system)
                Text("Light").tag(AppAppearance.light)
                Text("Dark").tag(AppAppearance.dark)
            }
            .onChange(of: appearance) { _, newValue in
                session.setAppearance(newValue)
            }
            NavigationLink("Models") {
                ModelsPage()
            }
            Button("New term") { showTerm = true }
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $showTerm) { TermEditor(terms: terms) }
    }
}

private enum ModelsPageDeletePrompt: Equatable {
    case mlx(ModelRole)
    case fluidAudio
}

struct ModelsPage: View {
    private static let log = Logger(subsystem: "app.bellnote", category: "models-ui")
    @Environment(AppSession.self) private var session
    @State private var budget = DeviceBudget(freeDiskBytes: 0, physicalMemoryBytes: 0)
    @State private var downloading: ModelRole?
    @State private var downloadingFluid = false
    @State private var downloadProgress: Double = 0
    @State private var installed: [ModelRole: Bool] = [:]
    @State private var leftover: [ModelRole: Bool] = [:]
    @State private var fluidInstalled = false
    @State private var status: [ModelRole: String] = [:]
    @State private var fluidStatus: String?
    @State private var pendingDelete: ModelsPageDeletePrompt?

    var body: some View {
        List {
            modelRow(.tagger, title: "2B", bytes: ModelCatalog.taggerBytes, locked: ModelLock.taggerLocked(budget))
            modelRow(.page, title: "4B", bytes: ModelCatalog.pageBytes, locked: ModelLock.pageLocked(budget))
            modelRow(.asr, title: "Qwen ASR", bytes: ModelCatalog.asrBytes, locked: false)
            fluidAudioRow()
            Section {
                Picker("Transcript", selection: Binding(
                    get: { session.speechEngine },
                    set: { session.setSpeechEngine($0) }
                )) {
                    Text("Apple Dictation").tag(SpeechEngine.apple)
                    if installed[.asr] == true {
                        Text("Qwen ASR").tag(SpeechEngine.qwen)
                    }
                }
                .pickerStyle(.segmented)
                Text(session.speechEngine == .qwen
                    ? "Qwen ASR is saved. It does not write yet."
                    : "Apple Dictation writes the words.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if installed[.tagger] == true || installed[.page] == true {
                Section {
                    Picker("Page model", selection: Binding(
                        get: { session.preferTaggerForPage },
                        set: { session.setPreferTaggerForPage($0) }
                    )) {
                        if installed[.tagger] == true {
                            Text("2B").tag(true)
                        }
                        if installed[.page] == true {
                            Text("4B").tag(false)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text("Ask and the page use this downloaded model.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Models")
        .task {
            refreshBudget()
            await refreshInstalled()
        }
        .confirmationDialog(
            deletePromptTitle,
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let target = pendingDelete else { return }
                pendingDelete = nil
                switch target {
                case let .mlx(role):
                    Task { await delete(role) }
                case .fluidAudio:
                    Task { await deleteFluidAudio() }
                }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        }
    }

    private var deletePromptTitle: String {
        switch pendingDelete {
        case .mlx(.page):
            String(localized: "Delete 4B?")
        case .mlx(.asr):
            String(localized: "Delete Qwen ASR?")
        case .mlx:
            String(localized: "Delete 2B?")
        case .fluidAudio:
            String(localized: "Delete FluidAudio?")
        case nil:
            ""
        }
    }

    @ViewBuilder
    private func fluidAudioRow() -> some View {
        let bytes = fluidInstalled ? SpeakerPass.installedByteCount() : ModelCatalog.diarizerBytes
        let ready = fluidInstalled
        let anyDownload = downloading != nil || downloadingFluid
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("FluidAudio")
                    Text(bytes.formatted(.byteCount(style: .file)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(String(localized: "Separates speakers while processing a lecture."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if ready, !downloadingFluid {
                        Text("Installed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if downloadingFluid {
                    VStack(alignment: .trailing, spacing: 4) {
                        ProgressView(value: downloadProgress.clamped(to: 0...1))
                            .frame(width: 96)
                        Text(downloadProgress.clamped(to: 0...1), format: .percent.precision(.fractionLength(0)))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else if ready {
                    Button("Delete", role: .destructive) {
                        Self.log.info("UI delete tap fluidAudio")
                        pendingDelete = .fluidAudio
                    }
                    .buttonStyle(.borderless)
                    .disabled(anyDownload)
                } else {
                    Button("Download") {
                        Self.log.info("UI download tap fluidAudio")
                        downloadingFluid = true
                        downloadProgress = 0
                        fluidStatus = nil
                        Task {
                            do {
                                try await SpeakerPass.downloadModels { fraction in
                                    Task { @MainActor in
                                        downloadProgress = max(downloadProgress, min(max(fraction, 0), 1))
                                    }
                                }
                                fluidStatus = String(localized: "Download finished.")
                                Self.log.info("UI download ok fluidAudio")
                            } catch {
                                let nsError = error as NSError
                                fluidStatus = String(localized: "A model is not available.")
                                Self.log.error("UI download failed fluidAudio domain=\(nsError.domain, privacy: .public) code=\(nsError.code) message=\(error.localizedDescription, privacy: .public)")
                            }
                            downloadingFluid = false
                            downloadProgress = 0
                            await refreshInstalled()
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(anyDownload)
                }
            }
            if let fluidStatus {
                Text(fluidStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func deleteFluidAudio() async {
        SpeakerPass.deleteModels()
        fluidStatus = nil
        Self.log.info("UI delete ok fluidAudio")
        await refreshInstalled()
    }

    @ViewBuilder
    private func modelRow(_ role: ModelRole, title: String, bytes: Int64, locked: Bool) -> some View {
        let ready = installed[role] == true
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                    Text(bytes.formatted(.byteCount(style: .file)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if leftover[role] == true, !ready {
                        Text("Incompletely installed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if locked, !ready {
                        Text(role == .tagger ? "Needs 2 GB free." : "Needs 4 GB free and 8 GB of memory.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if ready, downloading != role {
                        Text("Installed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if downloading == role {
                    VStack(alignment: .trailing, spacing: 4) {
                        ProgressView(value: downloadProgress.clamped(to: 0...1))
                            .frame(width: 96)
                        Text(downloadProgress.clamped(to: 0...1), format: .percent.precision(.fractionLength(0)))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else if ready || leftover[role] == true {
                    Button("Delete", role: .destructive) {
                        Self.log.info("UI delete tap role=\(role.rawValue, privacy: .public) title=\(title, privacy: .public)")
                        pendingDelete = .mlx(role)
                    }
                    .buttonStyle(.borderless)
                    .disabled(downloading != nil || downloadingFluid)
                } else if !locked {
                    Button("Download") {
                        Self.log.info("UI download tap role=\(role.rawValue, privacy: .public) title=\(title, privacy: .public)")
                        downloading = role
                        downloadProgress = 0
                        status[role] = nil
                        Task {
                            do {
                                try await LocalModelRuntime.shared.download(role) { fraction in
                                    Task { @MainActor in
                                        downloadProgress = max(downloadProgress, min(max(fraction, 0), 1))
                                    }
                                }
                                status[role] = String(localized: "Download finished.")
                                Self.log.info("UI download ok role=\(role.rawValue, privacy: .public)")
                            } catch {
                                let nsError = error as NSError
                                status[role] = String(localized: "A model is not available.")
                                Self.log.error("UI download failed role=\(role.rawValue, privacy: .public) domain=\(nsError.domain, privacy: .public) code=\(nsError.code) message=\(error.localizedDescription, privacy: .public)")
                            }
                            downloading = nil
                            downloadProgress = 0
                            await refreshInstalled()
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(downloading != nil || downloadingFluid)
                }
            }
            if let status = status[role] {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func delete(_ role: ModelRole) async {
        do {
            try await LocalModelRuntime.shared.delete(role)
            status[role] = nil
            if role == .page, !session.preferTaggerForPage {
                session.setPreferTaggerForPage(true)
            }
            if role == .tagger, session.preferTaggerForPage {
                session.setPreferTaggerForPage(false)
            }
            if role == .asr, session.speechEngine == .qwen {
                session.setSpeechEngine(.apple)
            }
            Self.log.info("UI delete ok role=\(role.rawValue, privacy: .public)")
        } catch {
            let nsError = error as NSError
            status[role] = String(localized: "A model is not available.")
            Self.log.error("UI delete failed role=\(role.rawValue, privacy: .public) domain=\(nsError.domain, privacy: .public) code=\(nsError.code) message=\(error.localizedDescription, privacy: .public)")
        }
        await refreshInstalled()
    }

    private func refreshBudget() {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let free = values?.volumeAvailableCapacityForImportantUsage ?? 0
        budget = DeviceBudget(freeDiskBytes: free, physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory)
        Self.log.info("Budget freeDisk=\(free) physicalMemory=\(ProcessInfo.processInfo.physicalMemory) taggerLocked=\(ModelLock.taggerLocked(budget)) pageLocked=\(ModelLock.pageLocked(budget))")
    }

    private func refreshInstalled() async {
        Self.log.info("Models page open")
        let tagger = await LocalModelRuntime.shared.probe(.tagger)
        let page = await LocalModelRuntime.shared.probe(.page)
        let asr = await LocalModelRuntime.shared.probe(.asr)
        installed[.tagger] = tagger.isReady
        installed[.page] = page.isReady
        installed[.asr] = asr.isReady
        leftover[.tagger] = tagger.directoryExists && !tagger.isReady
        leftover[.page] = page.directoryExists && !page.isReady
        leftover[.asr] = asr.directoryExists && !asr.isReady
        fluidInstalled = SpeakerPass.modelsAreInstalled()
        if session.speechEngine == .qwen, !asr.isReady {
            session.setSpeechEngine(.apple)
        }
        if tagger.isReady, !page.isReady {
            session.setPreferTaggerForPage(true)
        } else if page.isReady, !tagger.isReady {
            session.setPreferTaggerForPage(false)
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

private struct CalendarMark: Identifiable {
    var id: String
    var name: String
    var startMinutes: Int
    var endMinutes: Int
    var detail: String
    var recorded: Bool
    var lecture: Lecture?
}

struct CalendarPage: View {
    @Bindable var term: Term
    @State private var month = Calendar.current.dateInterval(of: .month, for: .now)?.start ?? .now
    @State private var selected = Calendar.current.startOfDay(for: .now)

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                weekdayHeader
                monthGrid
                Text(selected.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.headline)
                dayList
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(month.formatted(.dateTime.month(.wide).year()))
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Previous", systemImage: "chevron.left") { shiftMonth(-1) }
                    .labelStyle(.iconOnly)
                Button("Next", systemImage: "chevron.right") { shiftMonth(1) }
                    .labelStyle(.iconOnly)
            }
        }
    }

    private var weekdayHeader: some View {
        let symbols = Calendar.current.veryShortWeekdaySymbols
        let start = Calendar.current.firstWeekday - 1
        let ordered = Array(symbols[start...] + symbols[..<start])
        return HStack(spacing: 0) {
            ForEach(Array(ordered.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var monthGrid: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(Array(monthCells.enumerated()), id: \.offset) { _, date in
                if let date {
                    dayCell(date)
                } else {
                    Color.clear.frame(height: 44)
                }
            }
        }
    }

    private func dayCell(_ date: Date) -> some View {
        let recorded = hasLecture(on: date)
        let scheduled = hasSlot(on: date)
        let isSelected = Calendar.current.isDate(date, inSameDayAs: selected)
        let isToday = Calendar.current.isDateInToday(date)
        return Button {
            selected = Calendar.current.startOfDay(for: date)
        } label: {
            VStack(spacing: 4) {
                Text("\(Calendar.current.component(.day, from: date))")
                    .font(.body.weight(isSelected || isToday ? .semibold : .regular))
                    .frame(width: 32, height: 32)
                    .background {
                        if isSelected {
                            Circle().fill(.tertiary)
                        }
                        if isToday {
                            Circle().stroke(Color.pink, lineWidth: 1.5)
                        }
                    }
                Circle()
                    .fill(recorded ? Color.green : Color.clear)
                    .overlay {
                        if scheduled && !recorded {
                            Circle().stroke(Color.green, lineWidth: 1)
                        }
                    }
                    .frame(width: 5, height: 5)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    private var dayList: some View {
        let marks = marks(on: selected)
        return VStack(spacing: 10) {
            if marks.isEmpty {
                Text("No class")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            }
            ForEach(marks) { mark in
                markRow(mark)
            }
        }
    }

    private func markRow(_ mark: CalendarMark) -> some View {
        let row = HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(mark.recorded ? Color.green : Color.secondary.opacity(0.45))
                .frame(width: 3)
                .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 4) {
                Text(mark.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(mark.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if mark.lecture != nil {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

        return Group {
            if let lecture = mark.lecture {
                NavigationLink {
                    LecturePage(lecture: lecture)
                } label: {
                    row
                }
                .buttonStyle(.plain)
            } else {
                row
            }
        }
    }

    private var monthCells: [Date?] {
        let calendar = Calendar.current
        guard let interval = calendar.dateInterval(of: .month, for: month) else { return [] }
        let weekday = calendar.component(.weekday, from: interval.start)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        let count = calendar.range(of: .day, in: .month, for: month)?.count ?? 30
        var cells: [Date?] = Array(repeating: nil, count: leading)
        for offset in 0..<count {
            cells.append(calendar.date(byAdding: .day, value: offset, to: interval.start))
        }
        while cells.count % 7 != 0 { cells.append(nil) }
        return cells
    }

    private func shiftMonth(_ value: Int) {
        let calendar = Calendar.current
        guard let next = calendar.date(byAdding: .month, value: value, to: month) else { return }
        month = calendar.dateInterval(of: .month, for: next)?.start ?? next
        if calendar.isDate(Date.now, equalTo: month, toGranularity: .month) {
            selected = calendar.startOfDay(for: .now)
        } else {
            selected = month
        }
    }

    private func lectures(on date: Date) -> [Lecture] {
        term.courses
            .flatMap(\.lectures)
            .filter { Calendar.current.isDate($0.startedAt, inSameDayAs: date) }
            .sorted { $0.startedAt < $1.startedAt }
    }

    private func hasLecture(on date: Date) -> Bool {
        !lectures(on: date).isEmpty
    }

    private func hasSlot(on date: Date) -> Bool {
        guard termIncludes(date) else { return false }
        let weekday = Calendar.current.component(.weekday, from: date)
        return term.slots.contains { $0.weekday == weekday }
    }

    private func termIncludes(_ date: Date) -> Bool {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: date)
        let start = calendar.startOfDay(for: term.startsOn)
        let end = calendar.startOfDay(for: term.endsOn)
        return day >= start && day <= end
    }

    private func marks(on date: Date) -> [CalendarMark] {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: date)
        let dayLectures = lectures(on: date)
        var matched = Set<PersistentIdentifier>()
        var marks: [CalendarMark] = []
        if termIncludes(date) {
            for slot in term.slots.filter({ $0.weekday == weekday }).sorted(by: { $0.startMinutes < $1.startMinutes }) {
                if let lecture = dayLectures.first(where: { $0.course?.token == slot.course?.token && !matched.contains($0.persistentModelID) }) {
                    matched.insert(lecture.persistentModelID)
                    marks.append(mark(for: lecture, place: slot.placeName))
                } else {
                    marks.append(
                        CalendarMark(
                            id: "\(slot.token.uuidString).\(calendar.startOfDay(for: date).timeIntervalSince1970)",
                            name: slot.course?.name ?? String(localized: "Course"),
                            startMinutes: slot.startMinutes,
                            endMinutes: max(slot.endMinutes, slot.startMinutes + 30),
                            detail: slotDetail(slot),
                            recorded: false,
                            lecture: nil
                        )
                    )
                }
            }
        }
        for lecture in dayLectures where !matched.contains(lecture.persistentModelID) {
            marks.append(mark(for: lecture, place: ""))
        }
        return marks.sorted { $0.startMinutes < $1.startMinutes }
    }

    private func mark(for lecture: Lecture, place: String) -> CalendarMark {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: lecture.startedAt)
        let start = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        let clock = ReminderScheduler.clock(start)
        let state = LectureState(rawValue: lecture.state)?.title
        var partsDetail: [String] = [clock]
        if lecture.recordedSeconds >= 60 {
            partsDetail.append(String(format: String(localized: "%lld min"), lecture.recordedSeconds / 60))
        }
        if let state {
            partsDetail.append(state)
        }
        if !place.isEmpty {
            partsDetail.append(place)
        }
        return CalendarMark(
            id: "\(lecture.course?.token.uuidString ?? "lecture").\(lecture.startedAt.timeIntervalSince1970)",
            name: lecture.course?.name ?? String(localized: "Course"),
            startMinutes: start,
            endMinutes: start + max(30, lecture.recordedSeconds / 60),
            detail: partsDetail.joined(separator: " · "),
            recorded: true,
            lecture: lecture
        )
    }

    private func slotDetail(_ slot: WeeklySlot) -> String {
        let span = "\(ReminderScheduler.clock(slot.startMinutes))–\(ReminderScheduler.clock(slot.endMinutes))"
        guard !slot.placeName.isEmpty else { return span }
        return "\(span) · \(slot.placeName)"
    }

}

struct ProgramPage: View {
    @Bindable var term: Term
    @Environment(\.modelContext) private var modelContext
    @State private var showEditor = false
    @State private var day = Calendar.current.component(.weekday, from: .now)

    private let hourHeight: CGFloat = 56

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                weekStrip
                timeline
                if !hourRows.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(hourRows, id: \.courseName) { row in
                            Text("\(row.courseName) · \(String(format: String(localized: "%lld min"), row.weeklyMinutes))")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(weekdayName(day))
        .navigationSubtitle(date(for: day).formatted(date: .abbreviated, time: .omitted))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add slot", systemImage: "plus") { showEditor = true }
                    .labelStyle(.titleAndIcon)
            }
        }
        .onAppear {
            if !visibleDays.contains(day) { day = visibleDays[0] }
        }
        .sheet(isPresented: $showEditor) {
            SlotEditor(term: term, weekday: day)
        }
    }

    private var weekStrip: some View {
        HStack(spacing: 6) {
            ForEach(visibleDays, id: \.self) { value in
                Button {
                    day = value
                } label: {
                    Text(shortName(value))
                        .font(.subheadline.weight(value == day ? .semibold : .regular))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .foregroundStyle(value == day ? Color.primary : Color.secondary)
                        .background {
                            if value == day {
                                Capsule().fill(.tertiary)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var timeline: some View {
        let slots = slots(on: day)
        let start = startHour(slots)
        let end = endHour(slots)
        return VStack(spacing: 0) {
            ForEach(start..<end, id: \.self) { hour in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(hour)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 24, alignment: .leading)
                    Rectangle()
                        .fill(.quaternary)
                        .frame(height: 0.5)
                        .padding(.top, 7)
                }
                .frame(height: hourHeight, alignment: .top)
            }
        }
        .overlay(alignment: .topLeading) {
            ForEach(slots) { slot in
                slotBlock(slot, startHour: start)
                    .padding(.leading, 36)
                    .offset(y: yOffset(slot, startHour: start))
            }
        }
        .overlay(alignment: .topLeading) {
            if isToday, nowMinutes >= start * 60, nowMinutes < end * 60 {
                Capsule()
                    .fill(Color.pink)
                    .frame(height: 2)
                    .padding(.leading, 28)
                    .offset(y: CGFloat(nowMinutes - start * 60) / 60 * hourHeight)
                    .accessibilityLabel(Text("Now"))
                    .allowsHitTesting(false)
            }
        }
    }

    private func slotBlock(_ slot: WeeklySlot, startHour: Int) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.green)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(slot.course?.name ?? String(localized: "Course"))
                    .font(.subheadline.weight(.semibold))
                Text(slotDetail(slot))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: blockHeight(slot), alignment: .top)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contextMenu {
            Button("Delete", role: .destructive) { modelContext.delete(slot) }
        }
    }

    private var visibleDays: [Int] {
        var days = [2, 3, 4, 5, 6]
        if term.slots.contains(where: { $0.weekday == 7 }) { days.append(7) }
        if term.slots.contains(where: { $0.weekday == 1 }) { days.append(1) }
        return days
    }

    private var hourRows: [SlotHours] {
        HoursChart.weekly(slots: term.slots.map {
            ($0.course?.name ?? "", $0.startMinutes, $0.endMinutes)
        })
    }

    private var isToday: Bool {
        Calendar.current.component(.weekday, from: .now) == day
    }

    private var nowMinutes: Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: .now)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    private func slots(on day: Int) -> [WeeklySlot] {
        term.slots.filter { $0.weekday == day }.sorted { $0.startMinutes < $1.startMinutes }
    }

    private func startHour(_ slots: [WeeklySlot]) -> Int {
        guard let first = slots.map(\.startMinutes).min() else { return 8 }
        return max(7, first / 60 - 1)
    }

    private func endHour(_ slots: [WeeklySlot]) -> Int {
        guard let last = slots.map(\.endMinutes).max() else { return 19 }
        return min(23, max(startHour(slots) + 4, (last + 59) / 60 + 1))
    }

    private func blockHeight(_ slot: WeeklySlot) -> CGFloat {
        max(32, CGFloat(slot.endMinutes - slot.startMinutes) / 60 * hourHeight - 8)
    }

    private func yOffset(_ slot: WeeklySlot, startHour: Int) -> CGFloat {
        CGFloat(slot.startMinutes - startHour * 60) / 60 * hourHeight + 2
    }

    private func slotDetail(_ slot: WeeklySlot) -> String {
        let span = "\(ReminderScheduler.clock(slot.startMinutes))–\(ReminderScheduler.clock(slot.endMinutes))"
        guard !slot.placeName.isEmpty else { return span }
        return "\(span) · \(slot.placeName)"
    }

    private func weekdayName(_ day: Int) -> String {
        let symbols = Calendar.current.weekdaySymbols
        guard symbols.indices.contains(day - 1) else { return "" }
        return symbols[day - 1]
    }

    private func shortName(_ day: Int) -> String {
        let symbols = Calendar.current.shortWeekdaySymbols
        guard symbols.indices.contains(day - 1) else { return "" }
        return symbols[day - 1]
    }

    private func date(for weekday: Int) -> Date {
        let calendar = Calendar.current
        let today = calendar.component(.weekday, from: .now)
        let delta = mondayIndex(weekday) - mondayIndex(today)
        return calendar.date(byAdding: .day, value: delta, to: calendar.startOfDay(for: .now)) ?? .now
    }

    private func mondayIndex(_ weekday: Int) -> Int {
        (weekday + 5) % 7
    }
}

struct SlotEditor: View {
    @Bindable var term: Term
    var weekday: Int
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var day: Int
    @State private var start = Date()
    @State private var end = Date()
    @State private var courseToken: UUID?
    @State private var place = ""

    init(term: Term, weekday: Int) {
        self.term = term
        self.weekday = weekday
        _day = State(initialValue: weekday)
        let onlyCourse = term.courses.count == 1 ? term.courses.first?.token : nil
        _courseToken = State(initialValue: onlyCourse)
        let hour = Calendar.current.dateInterval(of: .hour, for: .now)?.end ?? .now
        _start = State(initialValue: hour)
        _end = State(initialValue: hour.addingTimeInterval(90 * 60))
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Course", selection: $courseToken) {
                    Text("None").tag(UUID?.none)
                    ForEach(term.courses) { course in
                        Text(course.name).tag(Optional(course.token))
                    }
                }
                Picker("Weekday", selection: $day) {
                    ForEach(1...7, id: \.self) { value in
                        Text(weekdayName(value)).tag(value)
                    }
                }
                DatePicker("Start", selection: $start, displayedComponents: .hourAndMinute)
                DatePicker("End", selection: $end, displayedComponents: .hourAndMinute)
                TextField("Place", text: $place)
            }
            .navigationTitle("Add slot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(courseToken == nil || minutes(end) <= minutes(start))
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        let course = term.courses.first { $0.token == courseToken }
        let slot = WeeklySlot(
            weekday: day,
            startMinutes: minutes(start),
            endMinutes: minutes(end),
            course: course,
            term: term,
            placeName: place
        )
        modelContext.insert(slot)
        term.slots.append(slot)
        dismiss()
    }

    private func minutes(_ date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    private func weekdayName(_ value: Int) -> String {
        let symbols = Calendar.current.weekdaySymbols
        guard symbols.indices.contains(value - 1) else { return "" }
        return symbols[value - 1]
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
