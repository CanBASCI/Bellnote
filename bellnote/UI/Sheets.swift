import OSLog
import SwiftData
import SwiftUI

struct TermEditor: View {
    var terms: [Term]
    /// The term being changed. With none, the form makes a new term.
    var editing: Term?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var year: Int
    @State private var termNumber: Int
    @State private var name = ""
    @State private var start: Date
    @State private var end: Date

    /// Starts on the term that comes after the latest one, so the first screen is not already a duplicate.
    /// The dates start after the last term that has not ended yet, so they do not overlap it either.
    /// With a term to edit, the fields start with what the term has now.
    init(terms: [Term], editing: Term? = nil) {
        self.terms = terms
        self.editing = editing
        if let editing {
            _year = State(initialValue: editing.yearOfStudy)
            _termNumber = State(initialValue: editing.termNumber)
            _name = State(initialValue: editing.customName)
            _start = State(initialValue: editing.startsOn)
            _end = State(initialValue: editing.endsOn)
            return
        }
        let calendar = Calendar.current
        var first = calendar.startOfDay(for: .now)
        if let lastEnd = terms.map(\.endsOn).max(),
           let dayAfter = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: lastEnd)),
           dayAfter > first {
            first = dayAfter
        }
        _start = State(initialValue: first)
        _end = State(initialValue: calendar.date(byAdding: .month, value: 4, to: first) ?? first)
        let latest = terms.max { ($0.yearOfStudy, $0.termNumber) < ($1.yearOfStudy, $1.termNumber) }
        if let latest {
            let next = latest.termNumber < 2
                ? (year: latest.yearOfStudy, number: latest.termNumber + 1)
                : (year: min(latest.yearOfStudy + 1, 12), number: 1)
            _year = State(initialValue: next.year)
            _termNumber = State(initialValue: next.number)
        } else {
            _year = State(initialValue: 1)
            _termNumber = State(initialValue: 1)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Stepper(value: $year, in: 1...12) {
                    Text("Year \(year)")
                }
                // A year of study has at most two terms.
                Stepper(value: $termNumber, in: 1...2) {
                    Text("Term \(termNumber)")
                }
                if alreadyExists {
                    Text("This year and term already exist.")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                LabeledContent("Name") {
                    TextField("Name", text: $name, prompt: Text("Optional"))
                        .multilineTextAlignment(.trailing)
                }
                DatePicker("Starts", selection: $start, displayedComponents: .date)
                DatePicker("Ends", selection: $end, displayedComponents: .date)
                if endsBeforeStart {
                    Text("The end cannot be before the start.")
                        .font(.footnote)
                        .foregroundStyle(.red)
                } else if overlapsAnotherTerm {
                    Text("These dates overlap another term.")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle("Term")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// The other terms. A term being edited does not count against itself.
    private var others: [Term] {
        guard let editing else { return terms }
        return terms.filter { $0.persistentModelID != editing.persistentModelID }
    }

    /// Two terms with the same year and number would look the same in the term menu.
    private var alreadyExists: Bool {
        others.contains { $0.yearOfStudy == year && $0.termNumber == termNumber }
    }

    private var endsBeforeStart: Bool {
        Calendar.current.startOfDay(for: end) < Calendar.current.startOfDay(for: start)
    }

    /// The app opens the term whose dates include today, so two terms cannot share a day.
    /// Both ends count: a term that ends on a day and one that starts on that day overlap.
    private var overlapsAnotherTerm: Bool {
        let calendar = Calendar.current
        let newStart = calendar.startOfDay(for: start)
        let newEnd = calendar.startOfDay(for: end)
        return others.contains { item in
            newStart <= calendar.startOfDay(for: item.endsOn) && calendar.startOfDay(for: item.startsOn) <= newEnd
        }
    }

    private var canSave: Bool {
        !alreadyExists && !endsBeforeStart && !overlapsAnotherTerm
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        guard canSave else { return }
        if let editing {
            editing.yearOfStudy = year
            editing.termNumber = termNumber
            editing.customName = trimmedName
            editing.startsOn = start
            editing.endsOn = end
            dismiss()
            return
        }
        for term in terms { term.isOpen = false }
        let term = Term(
            yearOfStudy: year,
            termNumber: termNumber,
            customName: trimmedName,
            startsOn: start,
            endsOn: end,
            isOpen: true
        )
        modelContext.insert(term)
        dismiss()
    }
}

struct PendingSheet: View {
    var lectures: [Lecture]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var running = false
    @State private var askNoModel = false
    @State private var fluidGate = FluidAudioGate()

    /// The stage of the lecture that runs now, from anywhere in the app.
    private var workingStage: PipelineActivity.Step? {
        lectures.compactMap { PipelineActivity.shared.step(for: $0) }.first
    }

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
                        Text(lecture.statusTitle)
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
                        Task {
                            if await LocalModelRuntime.shared.hasTextModel() {
                                fluidGate.request { await process() }
                            } else {
                                askNoModel = true
                            }
                        }
                    }
                    .disabled(lectures.isEmpty || running || workingStage != nil)
                }
            }
        }
        .fluidAudioGate(fluidGate)
        .noModelNotice(isPresented: $askNoModel) {
            fluidGate.request { await process() }
        }
        .presentationDetents([.medium, .large])
    }

    private func process() async {
        running = true
        defer { running = false }
        for lecture in lectures {
            await LecturePipeline.advance(
                lecture: lecture,
                context: modelContext,
                pageModel: AppPreferences.pageModel()
            )
        }
    }
}

struct SettingsPage: View {
    @Environment(AppSession.self) private var session
    @State private var choice: AppLanguage = {
        let stored = UserDefaults.standard.string(forKey: AppPreferences.languageKey) ?? AppLanguage.system.rawValue
        return AppLanguage(rawValue: stored) ?? .system
    }()
    @State private var appearance: AppAppearance = {
        let stored = UserDefaults.standard.string(forKey: AppPreferences.appearanceKey) ?? AppAppearance.system.rawValue
        return AppAppearance(rawValue: stored) ?? .system
    }()

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
        }
        .navigationTitle("Settings")
    }
}

private enum ModelsPageDeletePrompt: Equatable {
    case mlx(ModelRole)
    case fluidAudio
    case supertonic
}

struct ModelsPage: View {
    private static let log = Logger(subsystem: "app.bellnote", category: "models-ui")
    @Environment(AppSession.self) private var session
    @State private var budget = DeviceBudget(freeDiskBytes: 0, physicalMemoryBytes: 0)
    @State private var downloading: ModelRole?
    @State private var downloadingFluid = false
    @State private var downloadingSupertonic = false
    @State private var downloadProgress: Double = 0
    @State private var installed: [ModelRole: Bool] = [:]
    @State private var leftover: [ModelRole: Bool] = [:]
    @State private var fluidInstalled = false
    @State private var supertonicInstalled = false
    @State private var supertonicPartial = false
    @State private var status: [ModelRole: String] = [:]
    @State private var preparing: ModelRole?
    @State private var fluidStatus: String?
    @State private var supertonicStatus: String?
    @State private var pendingDelete: ModelsPageDeletePrompt?
    @State private var voicePreview = SpeechReader()

    var body: some View {
        List {
            Section("AI models") {
                modelRow(.tagger, title: Self.modelTitle(.tagger), bytes: ModelCatalog.taggerBytes, locked: ModelLock.taggerLocked(budget))
                modelRow(.page, title: Self.modelTitle(.page), bytes: ModelCatalog.pageBytes, locked: ModelLock.pageLocked(budget))
                if !installedTextModels.isEmpty {
                    Picker("AI model", selection: Binding(
                        get: { session.pageModel },
                        set: { session.setPageModel($0) }
                    )) {
                        ForEach(installedTextModels, id: \.self) { role in
                            Text(Self.modelTitle(role)).tag(role)
                        }
                    }
                    .pickerStyle(.menu)
                    Text("Tags, AI correction and Ask use this model.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Speech to text") {
                modelRow(.whisper, title: Self.modelTitle(.whisper), bytes: ModelCatalog.whisperBytes, locked: ModelLock.whisperLocked(budget))
                Picker("Transcript", selection: Binding(
                    get: { session.speechEngine },
                    set: { session.setSpeechEngine($0) }
                )) {
                    Text("Apple Dictation").tag(SpeechEngine.apple)
                    if installed[.whisper] == true {
                        Text("Whisper").tag(SpeechEngine.whisper)
                    }
                }
                .pickerStyle(.menu)
                Text(transcriptHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Audio") {
                fluidAudioRow()
                supertonicRow()
                Picker("Read aloud", selection: Binding(
                    get: { session.readAloud },
                    set: { session.setReadAloud($0) }
                )) {
                    Text("Apple Dictation").tag(ReadAloud.apple)
                    if supertonicInstalled {
                        Text("Supertonic").tag(ReadAloud.supertonic)
                    }
                }
                .pickerStyle(.menu)
                Text(session.readAloud == .supertonic
                    ? "Supertonic reads the notes."
                    : "Apple Dictation reads the notes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if session.readAloud == .supertonic, supertonicInstalled {
                    Picker("Voice", selection: Binding(
                        get: { session.supertonicVoice },
                        set: { voice in
                            session.setSupertonicVoice(voice)
                            voicePreview.preview(
                                SupertonicVoice.greeting(voice, locale: session.locale),
                                locale: session.locale
                            )
                        }
                    )) {
                        ForEach(0..<5, id: \.self) { index in
                            Text(verbatim: String(format: String(localized: "Male %lld"), index + 1))
                                .tag(index + 5)
                        }
                        ForEach(0..<5, id: \.self) { index in
                            Text(verbatim: String(format: String(localized: "Female %lld"), index + 1))
                                .tag(index)
                        }
                    }
                }
            }
        }
        .navigationTitle("Models")
        .onDisappear { voicePreview.stop() }
        .onChange(of: session.readAloud) { _, engine in
            if engine != .supertonic { voicePreview.stop() }
        }
        .task {
            refreshBudget()
            await refreshInstalled()
        }
        .alert(
            deletePromptTitle,
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                guard let target = pendingDelete else { return }
                pendingDelete = nil
                switch target {
                case let .mlx(role):
                    Task { await delete(role) }
                case .fluidAudio:
                    Task { await deleteFluidAudio() }
                case .supertonic:
                    Task { await deleteSupertonic() }
                }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        }
    }

    private var deletePromptTitle: String {
        switch pendingDelete {
        case .mlx(.page):
            String(localized: "Delete Qwen 3.5 4B?")
        case .mlx(.whisper):
            String(localized: "Delete Whisper?")
        case .mlx:
            String(localized: "Delete Qwen 3.5 2B?")
        case .fluidAudio:
            String(localized: "Delete FluidAudio?")
        case .supertonic:
            String(localized: "Delete Supertonic?")
        case nil:
            ""
        }
    }

    @ViewBuilder
    private func fluidAudioRow() -> some View {
        let bytes = fluidInstalled ? SpeakerPass.installedByteCount() : ModelCatalog.diarizerBytes
        let ready = fluidInstalled
        let anyDownload = downloading != nil || downloadingFluid || downloadingSupertonic
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                rowIcon("person.2.wave.2")
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

    @ViewBuilder
    private func supertonicRow() -> some View {
        let bytes = supertonicInstalled ? SupertonicSpeech.installedByteCount() : ModelCatalog.supertonicBytes
        let ready = supertonicInstalled
        let anyDownload = downloading != nil || downloadingFluid || downloadingSupertonic
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                rowIcon("speaker.wave.2.fill")
                VStack(alignment: .leading, spacing: 4) {
                    Text("Supertonic")
                    Text(bytes.formatted(.byteCount(style: .file)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Reads notes aloud in Turkish and English.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if supertonicPartial, !ready {
                        Text("Incompletely installed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if ready, !downloadingSupertonic {
                        Text("Installed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if downloadingSupertonic {
                    VStack(alignment: .trailing, spacing: 4) {
                        ProgressView(value: downloadProgress.clamped(to: 0...1))
                            .frame(width: 96)
                        Text(downloadProgress.clamped(to: 0...1), format: .percent.precision(.fractionLength(0)))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else if ready || supertonicPartial {
                    Button("Delete", role: .destructive) {
                        Self.log.info("UI delete tap supertonic")
                        pendingDelete = .supertonic
                    }
                    .buttonStyle(.borderless)
                    .disabled(anyDownload)
                } else {
                    Button("Download") {
                        Self.log.info("UI download tap supertonic")
                        downloadingSupertonic = true
                        downloadProgress = 0
                        supertonicStatus = nil
                        Task {
                            do {
                                try await SupertonicSpeech.download { fraction in
                                    Task { @MainActor in
                                        downloadProgress = max(downloadProgress, min(max(fraction, 0), 1))
                                    }
                                }
                                supertonicStatus = String(localized: "Download finished.")
                                Self.log.info("UI download ok supertonic")
                            } catch {
                                let nsError = error as NSError
                                supertonicStatus = String(localized: "A model is not available.")
                                Self.log.error("UI download failed supertonic domain=\(nsError.domain, privacy: .public) code=\(nsError.code) message=\(error.localizedDescription, privacy: .public)")
                            }
                            downloadingSupertonic = false
                            downloadProgress = 0
                            await refreshInstalled()
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(anyDownload)
                }
            }
            if let supertonicStatus {
                Text(supertonicStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func deleteSupertonic() async {
        do {
            try SupertonicSpeech.delete()
            supertonicStatus = nil
            if session.readAloud == .supertonic {
                session.setReadAloud(.apple)
            }
            Self.log.info("UI delete ok supertonic")
        } catch {
            let nsError = error as NSError
            supertonicStatus = String(localized: "A model is not available.")
            Self.log.error("UI delete failed supertonic domain=\(nsError.domain, privacy: .public) code=\(nsError.code) message=\(error.localizedDescription, privacy: .public)")
        }
        await refreshInstalled()
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
                rowIcon(Self.symbol(role))
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
                        Text(Self.lockedHint(role))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if ready, downloading != role {
                        Text("Installed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if downloading == role, preparing == role {
                    VStack(alignment: .trailing, spacing: 4) {
                        ProgressView()
                        Text("Preparing…")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else if downloading == role {
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
                    .disabled(downloading != nil || downloadingFluid || downloadingSupertonic)
                } else if !locked {
                    Button("Download") {
                        Self.log.info("UI download tap role=\(role.rawValue, privacy: .public) title=\(title, privacy: .public)")
                        downloading = role
                        downloadProgress = 0
                        status[role] = nil
                        Task {
                            do {
                                try await LocalModelRuntime.shared.download(role, onProgress: { fraction in
                                    Task { @MainActor in
                                        downloadProgress = max(downloadProgress, min(max(fraction, 0), 1))
                                    }
                                }, onPreparing: {
                                    Task { @MainActor in preparing = role }
                                })
                                status[role] = String(localized: "Download finished.")
                                Self.log.info("UI download ok role=\(role.rawValue, privacy: .public)")
                            } catch {
                                let nsError = error as NSError
                                status[role] = String(localized: "A model is not available.")
                                Self.log.error("UI download failed role=\(role.rawValue, privacy: .public) domain=\(nsError.domain, privacy: .public) code=\(nsError.code) message=\(error.localizedDescription, privacy: .public)")
                            }
                            downloading = nil
                            preparing = nil
                            downloadProgress = 0
                            await refreshInstalled()
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(downloading != nil || downloadingFluid || downloadingSupertonic)
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
        let whisper = await LocalModelRuntime.shared.probe(.whisper)
        installed[.whisper] = whisper.isReady
        leftover[.whisper] = whisper.directoryExists && !whisper.isReady
        installed[.tagger] = tagger.isReady
        installed[.page] = page.isReady
        leftover[.tagger] = tagger.directoryExists && !tagger.isReady
        leftover[.page] = page.directoryExists && !page.isReady
        fluidInstalled = SpeakerPass.modelsAreInstalled()
        supertonicInstalled = SupertonicSpeech.isInstalled
        supertonicPartial = SupertonicSpeech.hasPartial
        if session.readAloud == .supertonic, !supertonicInstalled {
            session.setReadAloud(.apple)
        }
        if session.speechEngine == .whisper, !whisper.isReady {
            session.setSpeechEngine(.apple)
        }
        if installed[session.pageModel] != true, let first = installedTextModels.first {
            session.setPageModel(first)
        }
    }

    private var transcriptHint: LocalizedStringKey {
        switch session.speechEngine {
        case .apple: "Apple Dictation writes the words."
        case .whisper: "Whisper writes the words."
        }
    }

    private static let textModelOrder: [ModelRole] = [.page, .tagger]

    private var installedTextModels: [ModelRole] {
        Self.textModelOrder.filter { installed[$0] == true }
    }

    /// Text models write the AI correction, answer Ask and find homework. Speech models hear audio.
    private static func symbol(_ role: ModelRole) -> String {
        switch role {
        case .tagger, .page: "sparkles"
        case .whisper: "mic.fill"
        }
    }

    private func rowIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.title3)
            .foregroundStyle(.tint)
            .frame(width: 28)
            .accessibilityHidden(true)
    }

    private static func modelTitle(_ role: ModelRole) -> String {
        switch role {
        case .tagger: "Qwen 3.5 2B"
        case .page: "Qwen 3.5 4B"
        case .whisper: "Whisper"
        }
    }

    private static func lockedHint(_ role: ModelRole) -> String {
        switch role {
        case .tagger: String(localized: "Needs 2 GB free.")
        case .page: String(localized: "Needs 4 GB free and 8 GB of memory.")
        case .whisper: String(localized: "Needs 2 GB free.")
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
        let state: String? = lecture.statusTitle
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
    @State private var showCalendar = false
    @State private var day = Calendar.current.component(.weekday, from: .now)
    @State private var pendingSlot: WeeklySlot?

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
        .navigationDestination(isPresented: $showCalendar) {
            CalendarPage(term: term)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Calendar", systemImage: "calendar") { showCalendar = true }
                    .labelStyle(.iconOnly)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Add slot", systemImage: "plus") { showEditor = true }
                    .labelStyle(.iconOnly)
            }
        }
        .onAppear {
            if !visibleDays.contains(day) { day = visibleDays[0] }
        }
        .sheet(isPresented: $showEditor) {
            SlotEditor(term: term, weekday: day)
        }
        .alert(
            "Delete this time from the timetable?",
            isPresented: Binding(
                get: { pendingSlot != nil },
                set: { if !$0 { pendingSlot = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let slot = pendingSlot { modelContext.delete(slot) }
                pendingSlot = nil
            }
            Button("Cancel", role: .cancel) { pendingSlot = nil }
        } message: {
            Text("The recordings of this course stay.")
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
        let name = slot.course?.name ?? String(localized: "Course")
        let detail = slotDetail(slot)
        // A short slot is a short block. It does not have room for two lines, so the name and the
        // time share one line.
        let isShort = blockHeight(slot) < 52
        return HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.green)
                .frame(width: 3)
            ViewThatFits(in: .vertical) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .layoutPriority(1)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, isShort ? 4 : 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: blockHeight(slot), alignment: .top)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contextMenu {
            Button("Delete", role: .destructive) { pendingSlot = slot }
        }
    }

    private var visibleDays: [Int] {
        var days = [2, 3, 4, 5, 6]
        if term.slots.contains(where: { $0.weekday == 7 }) { days.append(7) }
        if term.slots.contains(where: { $0.weekday == 1 }) { days.append(1) }
        return days
    }

    private var hourRows: [SlotHours] {
        HoursChart.weekly(slots: slots(on: day).map {
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

private enum SlotCourseChoice: Hashable {
    case none
    case existing(UUID)
    case new
}

struct SlotEditor: View {
    @Bindable var term: Term
    var weekday: Int
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var day: Int
    @State private var start = Date()
    @State private var end = Date()
    @State private var choice: SlotCourseChoice
    @State private var newName = ""
    @State private var language = AppLanguage.deviceCourseDefault
    @State private var place = ""
    /// Set when the sheet changes a time that is already in the timetable. Then the course cannot change.
    private let editing: WeeklySlot?
    /// Set when the sheet adds one more time to a given course. Then the course is fixed and not asked.
    private let lockedCourse: Course?

    /// - Parameters:
    ///   - course: Adds a time to this course. The course picker is hidden.
    ///   - editing: Changes this time. The sheet opens with its day, hours and place.
    init(term: Term, weekday: Int, course: Course? = nil, editing: WeeklySlot? = nil) {
        self.term = term
        self.weekday = weekday
        self.editing = editing
        self.lockedCourse = editing?.course ?? course
        _day = State(initialValue: editing?.weekday ?? weekday)
        if let locked = editing?.course ?? course {
            _choice = State(initialValue: .existing(locked.token))
        } else if term.courses.count == 1, let token = term.courses.first?.token {
            _choice = State(initialValue: .existing(token))
        } else if term.courses.isEmpty {
            // The term has no course yet, so the first thing to do is to make one.
            _choice = State(initialValue: .new)
        } else {
            _choice = State(initialValue: .none)
        }
        let hour = Calendar.current.dateInterval(of: .hour, for: .now)?.end ?? .now
        if let editing {
            _start = State(initialValue: Self.date(atMinutes: editing.startMinutes, fallback: hour))
            _end = State(initialValue: Self.date(atMinutes: editing.endMinutes, fallback: hour.addingTimeInterval(90 * 60)))
            _place = State(initialValue: editing.placeName)
        } else {
            _start = State(initialValue: hour)
            _end = State(initialValue: hour.addingTimeInterval(90 * 60))
        }
    }

    /// Today at the given minutes of the day. The date part does not matter, only the hour and the minute are used.
    private static func date(atMinutes minutes: Int, fallback: Date) -> Date {
        Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: .now) ?? fallback
    }

    private var title: LocalizedStringKey {
        if editing != nil { return "Edit slot" }
        return lockedCourse != nil ? "Add time" : "Add slot"
    }

    var body: some View {
        NavigationStack {
            Form {
                if lockedCourse == nil {
                    Picker("Course", selection: $choice) {
                        Text("None").tag(SlotCourseChoice.none)
                        Text("New course").tag(SlotCourseChoice.new)
                        ForEach(term.courses) { course in
                            Text(course.name).tag(SlotCourseChoice.existing(course.token))
                        }
                    }
                    if choice == .new {
                        TextField("Course", text: $newName)
                        Picker("Language", selection: $language) {
                            ForEach(AppLanguage.courseChoices, id: \.self) { item in
                                Text(LocalizedStringKey(item.title)).tag(item)
                            }
                        }
                        .pickerStyle(.menu)
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
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var canSave: Bool {
        guard minutes(end) > minutes(start) else { return false }
        // A time that is changed, or one added to a given course, already has its course.
        if editing != nil || lockedCourse != nil { return true }
        switch choice {
        case .none:
            return false
        case .existing:
            return true
        case .new:
            return !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func save() {
        if let editing {
            editing.weekday = day
            editing.startMinutes = minutes(start)
            editing.endMinutes = minutes(end)
            editing.placeName = place
            // The reminder of this time follows the new day and hour.
            ReminderScheduler.replaceSlot(editing, courseName: editing.course?.name ?? "")
            dismiss()
            return
        }
        let course = lockedCourse ?? courseForSlot()
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

    private func courseForSlot() -> Course? {
        switch choice {
        case .none:
            return nil
        case let .existing(token):
            return term.courses.first { $0.token == token }
        case .new:
            let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            let course = Course(name: name, localeIdentifier: language.speechLocaleIdentifier, term: term)
            modelContext.insert(course)
            term.courses.append(course)
            return course
        }
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
    /// Set when the sheet is opened from a recording. Then only that recording is used. Without it, the
    /// whole course is used.
    var lecture: Lecture?
    @Environment(\.dismiss) private var dismiss
    @State private var prompt = ""
    @State private var asked = ""
    @State private var answer = ""
    @State private var busy = false
    @State private var reader = SpeechReader()
    private static let log = Logger(subsystem: "app.bellnote", category: "study")

    private var suggestions: [String] {
        [
            String(localized: "What are the assignments?"),
            String(localized: "What is on the exam?"),
        ]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !asked.isEmpty {
                        Text(asked)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .foregroundStyle(.white)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    if busy {
                        ProgressView()
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                    }
                    if !answer.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(answer)
                                .textSelection(.enabled)
                            Button(reader.isSpeaking ? "Stop" : "Listen", systemImage: reader.isSpeaking ? "stop.fill" : "speaker.wave.2.fill") {
                                if reader.isSpeaking {
                                    reader.stop()
                                } else {
                                    reader.read(answer, locale: Locale(identifier: course.localeIdentifier))
                                }
                            }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if asked.isEmpty {
                        Text("Answers come only from your lectures.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 10) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(suggestions, id: \.self) { suggestion in
                                Button(suggestion) {
                                    prompt = suggestion
                                    Task { await run() }
                                }
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.capsule)
                                .controlSize(.small)
                            }
                        }
                    }
                    .scrollClipDisabled()
                    HStack(spacing: 8) {
                        TextField("Ask a question", text: $prompt)
                            .textFieldStyle(.plain)
                            .submitLabel(.send)
                            .onSubmit { Task { await run() } }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .glassEffect(.regular, in: .capsule)
                        Button("Run", systemImage: "arrow.up") { Task { await run() } }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.glassProminent)
                            .buttonBorderShape(.circle)
                            .controlSize(.large)
                            .disabled(busy || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            .navigationTitle("Ask")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func run() async {
        let question = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !busy else { return }
        asked = question
        answer = ""
        busy = true
        prompt = ""
        defer { busy = false }
        await ask(question)
    }

    private func ask(_ question: String) async {
        // From the course page only the recordings that are finished count. A failed, paused or still running one
        // does not.
        let lectures = lecture.map { [$0] } ?? course.lectures.filter { $0.state == LectureState.ready.rawValue }
        Self.log.info("Study run tapped lectures=\(lectures.count) ofOneRecording=\(lecture != nil) question=\(question, privacy: .public)")
        let blocks = lectures.flatMap { lecture in
            lecture.blocks.map { block in
                StudyBlock(
                    id: block.token,
                    at: lecture.startedAt,
                    second: block.second,
                    kind: BlockKind(tag: block.kind),
                    text: block.text,
                    topics: block.topics,
                    importance: block.importance,
                    missing: block.missing,
                    userFlag: block.userFlag,
                    examScope: block.kind == BlockKind.examScope.rawValue
                )
            }
        }
        let everything = StudySelection.select(blocks, filter: .wholeCourse)
        let selected = StudySelection.relevant(everything, to: question, locale: Locale(identifier: course.localeIdentifier))
        Self.log.info("Study blocks total=\(blocks.count) selected=\(selected.count) characters=\(selected.reduce(0) { $0 + $1.text.count }) of=\(everything.reduce(0) { $0 + $1.text.count })")
        for block in selected {
            Self.log.info("Study picked second=\(block.second) characters=\(block.text.count) head=\(String(block.text.prefix(80)), privacy: .public)")
        }
        guard !selected.isEmpty else {
            Self.log.info("Study no blocks selected")
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
                importanceCue: $0.importance,
                missing: $0.missing
            )
        }
        do {
            let reply = try await LocalModelRuntime.shared.answer(question: question, tags: tags)
            let missing = reply.contains("NOT_IN_NOTES") || reply.isEmpty
            Self.log.info("Study answer shown notInNotes=\(missing) characters=\(reply.count)")
            answer = missing ? String(localized: "The lectures do not contain that.") : reply
        } catch {
            Self.log.error("Study answer failed: \(error.localizedDescription, privacy: .public)")
            answer = String(localized: "A model is not available.")
        }
    }
}
