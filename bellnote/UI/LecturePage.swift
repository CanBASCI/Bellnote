import AVFoundation
import OSLog
import SwiftData
import SwiftUI

struct LecturePage: View {
    @Bindable var lecture: Lecture
    /// Plays from this second once the recording is loaded.
    var startSecond: Int?

    var body: some View {
        LectureNote(lecture: lecture, showsDate: false, startSecond: startSecond)
            .navigationTitle(lecture.startedAt.formatted(date: .abbreviated, time: .shortened))
            .navigationSubtitle(subtitle)
    }

    private var subtitle: String {
        guard lecture.recordedSeconds >= 60 else { return "" }
        return String(format: String(localized: "%lld min"), lecture.recordedSeconds / 60)
    }
}

private enum LectureTab: Hashable {
    case correction
    case raw
    case assignments
}

struct LectureNote: View {
    @Bindable var lecture: Lecture
    var showsDate: Bool
    var startSecond: Int?

    @State private var audio = LectureAudio()
    @State private var reader = SpeechReader()
    @State private var showStudy = false
    @State private var studyMode: StudyMode = .ask
    @State private var fluidGate = FluidAudioGate()
    private var workingStage: PipelineStage? { PipelineActivity.shared.stage(for: lecture) }
    private var workingStep: PipelineActivity.Step? { PipelineActivity.shared.step(for: lecture) }
    @State private var askReprocess = false
    @State private var askNoModel = false
    @State private var namingSpeaker: Int?
    @State private var choosingSpeaker = false
    @State private var typingSpeaker = false
    @State private var typedSpeakerName = ""
    @State private var tab: LectureTab = .correction
    /// Speakers chosen in the Raw tab. Empty means everyone.
    @State private var chosenSpeakers: Set<Int> = []
    @State private var pendingAssignment: Assignment?

    var body: some View {
        List {
            if showsDate {
                Section {
                    Text(lecture.startedAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.title2.weight(.semibold))
                }
            }
            if lecture.isRecordedOnly && workingStage == nil {
                // Nothing to show in any tab until the recording is processed.
                Section {
                    NotProcessedView { start() }
                        .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    Picker("", selection: $tab) {
                        Text("AI correction").tag(LectureTab.correction)
                        Text("Raw").tag(LectureTab.raw)
                        Text("Assignments").tag(LectureTab.assignments)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                }
                switch tab {
                case .correction:
                    correctionSections
                case .raw:
                    rawSections
                case .assignments:
                    assignmentSections
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            // While the lecture is processed, the ring takes the screen. The notes come back when it ends.
            if let workingStep {
                ProcessingCircle(step: workingStep)
            }
        }
        .toolbar {
            // A recording that was never processed has its own Process button in the middle.
            if lecture.audioRelativePath != nil, !(lecture.isRecordedOnly && workingStage == nil) {
                ToolbarItem(placement: .primaryAction) {
                    let again = lecture.state == LectureState.ready.rawValue
                    Button(
                        again ? "Process again" : "Process",
                        systemImage: again ? "arrow.clockwise" : "waveform.badge.magnifyingglass"
                    ) {
                        if again {
                            askReprocess = true
                        } else {
                            start()
                        }
                    }
                    .labelStyle(.iconOnly)
                    .disabled(workingStage != nil)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Pinned like the player, so the buttons stay put while the page scrolls.
            VStack(spacing: 8) {
                if tab == .correction, hasCorrection, let course = lecture.course {
                    studyBar(course)
                }
                if audio.duration > 0 {
                    playback
                }
            }
        }
        .task(id: lecture.persistentModelID) {
            await audio.load(lecture)
            if let startSecond, audio.duration > 0 {
                audio.seek(to: startSecond, play: true)
            }
        }
        .onDisappear { audio.stop() }
        .task(id: audio.isPlaying) {
            while !Task.isCancelled, audio.isPlaying {
                try? await Task.sleep(for: .milliseconds(400))
                await audio.sync()
            }
        }
        .sheet(isPresented: $showStudy) {
            if let course = lecture.course {
                StudySheet(course: course, mode: studyMode)
            }
        }
        .fluidAudioGate(fluidGate)
        .noModelNotice(isPresented: $askNoModel) {
            fluidGate.request { await process() }
        }
        .confirmAssignmentDelete($pendingAssignment)
        .confirmationDialog("Who is this?", isPresented: $choosingSpeaker, titleVisibility: .visible) {
            if let name = lecturerName {
                Button {
                    assignSpeaker(name)
                } label: {
                    Text(verbatim: name)
                }
            }
            Button("Other") {
                typedSpeakerName = ""
                typingSpeaker = true
            }
            Button("Cancel", role: .cancel) { namingSpeaker = nil }
        }
        .alert("Who is this?", isPresented: $typingSpeaker) {
            TextField("Name", text: $typedSpeakerName)
            Button("Save") { assignSpeaker(typedSpeakerName) }
            Button("Cancel", role: .cancel) { namingSpeaker = nil }
        }
        .confirmationDialog("Process again?", isPresented: $askReprocess, titleVisibility: .visible) {
            Button("Process again", role: .destructive) {
                start()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The written notes will be deleted. The recording stays.")
        }
    }

    @ViewBuilder
    private var correctionSections: some View {
        // No correction yet: nothing to read, ask about or listen to. A running lecture shows only
        // the bar. A stopped one with no correction says so.
        if hasCorrection || workingStage == nil {
            Section {
                Text(CorrectionText.attributed(bodyText))
                    .font(.body)
                    .lineSpacing(4)
                    .textSelection(.enabled)
            }
        }
    }

    /// Exactly what Apple dictation returned, one block per speaker turn.
    @ViewBuilder
    private var rawSections: some View {
        let filter = activeSpeakers
        let blocks = lecture.blocks
            .filter { !$0.text.isEmpty }
            .filter { filter.isEmpty || filter.contains($0.speaker) }
            .sorted { $0.second < $1.second }
        if lecture.blocks.isEmpty && lecture.flaggedSeconds.isEmpty {
            Section {
                Text("No lectures yet.")
                    .foregroundStyle(.secondary)
            }
        } else {
            if speakerClusters.count > 1 {
                Section { speakerTags }
            }
            Section {
                ForEach(blocks) { block in
                    chapterLabel(block)
                }
                ForEach(Array((filter.isEmpty ? orphanFlags : []).enumerated()), id: \.offset) { _, second in
                    Button {
                        audio.seek(to: second, play: true)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(MediaClock.short(second))
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 52, alignment: .leading)
                            Text("I didn't get this")
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var assignmentSections: some View {
        let own = lectureAssignments
        Section {
            if own.isEmpty {
                Text("No assignments yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(own) { assignment in
                AssignmentRow(assignment: assignment) { second in
                    audio.seek(to: second, play: true)
                }
            }
            .onDelete { offsets in
                pendingAssignment = offsets.first.map { own[$0] }
            }
        }
    }

    /// Homework that came from this lecture's own text.
    private var lectureAssignments: [Assignment] {
        guard let course = lecture.course else { return [] }
        let ids = Set(lecture.blocks.map(\.token))
        return course.assignments.filter { ids.contains($0.sourceBlockID) }
    }

    /// Ask, Quiz and Listen, pinned just above the player.
    private func studyBar(_ course: Course) -> some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                Button("Ask", systemImage: "sparkles") {
                    studyMode = .ask
                    showStudy = true
                }
                Button(quizTitle(course), systemImage: "checklist") {
                    studyMode = .quiz
                    showStudy = true
                }
                Button(reader.isSpeaking ? "Stop" : "Listen", systemImage: reader.isSpeaking ? "stop.fill" : "speaker.wave.2.fill") {
                    if reader.isSpeaking {
                        reader.stop()
                    } else {
                        listen(course)
                    }
                }
            }
            .buttonStyle(.glass)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.bottom, audio.duration > 0 ? 0 : 8)
    }

    private var playback: some View {
        HStack(spacing: 12) {
            Button(audio.isPlaying ? "Pause" : "Play", systemImage: audio.isPlaying ? "pause.fill" : "play.fill") {
                audio.toggle()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.glass)
            Text(MediaClock.short(audio.currentSecond))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Slider(
                value: Binding(
                    get: { Double(audio.currentSecond) },
                    set: { audio.seek(to: Int($0), play: audio.isPlaying) }
                ),
                in: 0...Double(max(audio.duration, 1))
            )
            Text(MediaClock.short(audio.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var hasCorrection: Bool {
        !lecture.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var bodyText: String {
        let summary = lecture.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty { return summary }
        if let failure = lecture.failureMessageKey, !failure.isEmpty {
            return String(localized: String.LocalizationValue(failure))
        }
        return String(localized: "No AI correction yet.")
    }

    private var chapters: [Block] {
        lecture.blocks
            .filter { $0.role != SpeakerRole.room.rawValue && !$0.text.isEmpty }
            .sorted { $0.second < $1.second }
    }

    private var orphanFlags: [Int] {
        lecture.flaggedSeconds.filter { second in
            !chapters.contains { abs($0.second - second) <= 3 }
        }
    }

    private func chapterLabel(_ block: Block) -> some View {
        let current = isCurrent(block)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if block.speaker > 0 {
                    Button {
                        beginNaming(block.speaker)
                    } label: {
                        Text(speakerTitle(block.speaker))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    audio.seek(to: block.second, play: true)
                } label: {
                    Text(MediaClock.short(block.second))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(current ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
            }
            Button {
                audio.seek(to: block.second, play: true)
            } label: {
                Text(verbatim: block.text)
                    .foregroundStyle(.primary)
                    .fontWeight(current ? .semibold : .regular)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            if block.missing || block.userFlag {
                Text("Missing")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    /// The speakers of this recording, in the order the numbers were given.
    private var speakerClusters: [Int] {
        Array(Set(lecture.blocks.filter { !$0.text.isEmpty && $0.speaker > 0 }.map(\.speaker))).sorted()
    }

    /// The chosen speakers that this recording still has. After a new run an old choice can vanish.
    private var activeSpeakers: Set<Int> {
        chosenSpeakers.intersection(speakerClusters)
    }

    /// One tag per speaker above the list. A tag shows the name the student gave. No tag chosen
    /// shows every speaker.
    private var speakerTags: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(speakerClusters, id: \.self) { cluster in
                        let chosen = chosenSpeakers.contains(cluster)
                        Button {
                            if chosen {
                                chosenSpeakers.remove(cluster)
                            } else {
                                chosenSpeakers.insert(cluster)
                            }
                        } label: {
                            Text(verbatim: speakerTitle(cluster))
                                .lineLimit(1)
                        }
                        .buttonStyle(.glass)
                        .tint(chosen ? Color.accentColor : nil)
                        .accessibilityAddTraits(chosen ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
    }

    private var lecturerName: String? {
        let name = lecture.course?.lecturer?.displayName ?? ""
        return name.isEmpty ? nil : name
    }

    private func speakerTitle(_ cluster: Int) -> String {
        if let name = lecture.speakerName(for: cluster) { return name }
        return String(format: String(localized: "Speaker %lld"), cluster)
    }

    private func beginNaming(_ cluster: Int) {
        namingSpeaker = cluster
        typedSpeakerName = ""
        if lecturerName == nil {
            typingSpeaker = true
        } else {
            choosingSpeaker = true
        }
    }

    private func assignSpeaker(_ name: String) {
        guard let cluster = namingSpeaker else { return }
        lecture.setSpeakerName(name, cluster: cluster)
        do {
            try lecture.modelContext?.save()
        } catch {
            Logger(subsystem: "app.bellnote", category: "speaker").error("Speaker name save failed: \(error.localizedDescription, privacy: .public)")
        }
        namingSpeaker = nil
    }

    private func isCurrent(_ block: Block) -> Bool {
        guard audio.currentSecond > 0 else { return false }
        guard let index = chapters.firstIndex(where: { $0.token == block.token }) else { return false }
        let end = chapters.indices.contains(index + 1) ? chapters[index + 1].second : Int.max
        return audio.currentSecond >= block.second && audio.currentSecond < end
    }

    private func quizTitle(_ course: Course) -> String {
        guard let attempt = course.quizAttempts.max(by: { $0.at < $1.at }) else {
            return String(localized: "Quiz")
        }
        let total = attempt.correct + attempt.partial + attempt.wrong
        guard total > 0 else { return String(localized: "Quiz") }
        return String(format: String(localized: "Quiz %1$lld/%2$lld"), attempt.correct, total)
    }

    private func openCount(_ course: Course) -> Int {
        course.assignments.filter { !$0.done && !$0.cancelled }.count
    }

    private func listen(_ course: Course) {
        let text = lecture.summary.isEmpty
            ? chapters.map(\.text).joined(separator: "\n")
            : CorrectionText.plain(lecture.summary)
        Logger(subsystem: "app.bellnote", category: "listen").info(
            "Listen tap characters=\(text.count) locale=\(course.localeIdentifier, privacy: .public) speaking=\(reader.isSpeaking)"
        )
        reader.read(text, locale: Locale(identifier: course.localeIdentifier))
    }

    /// Warns first when no text model is installed, so minutes of transcript work are not a surprise.
    private func start() {
        Task {
            if await LocalModelRuntime.shared.hasTextModel() {
                fluidGate.request { await process() }
            } else {
                askNoModel = true
            }
        }
    }

    private func process() async {
        guard let context = lecture.modelContext else { return }
        let restart = lecture.state == LectureState.ready.rawValue
        if restart {
            LecturePipeline.discardProcessedNotes(lecture, context: context)
        }
        await LecturePipeline.advance(
            lecture: lecture,
            context: context,
            pageModel: AppPreferences.pageModel()
        )
    }
}

enum MediaClock {
    static func full(_ seconds: Int) -> String {
        let seconds = max(0, seconds)
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }

    static func short(_ seconds: Int) -> String {
        let seconds = max(0, seconds)
        if seconds >= 3600 { return full(seconds) }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let end = trimmed.firstIndex(where: { $0 == "." || $0 == "?" || $0 == "!" })
        let sentence = end.map { String(trimmed[...$0]) } ?? trimmed
        if sentence.count <= 110 { return sentence }
        return String(sentence.prefix(110)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

@MainActor
@Observable
final class LectureAudio {
    private(set) var isPlaying = false
    private(set) var currentSecond = 0
    private(set) var duration = 0
    private let engine = LecturePlaybackEngine()

    func load(_ lecture: Lecture) async {
        await engine.reset()
        isPlaying = false
        duration = 0
        currentSecond = 0
        guard let relative = lecture.audioRelativePath else { return }
        guard let root = try? Vault.documents() else { return }
        let url = root.appendingPathComponent(relative)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let seconds = await engine.load(url)
        guard seconds > 0 else { return }
        duration = seconds
    }

    func toggle() {
        Task { await togglePlayback() }
    }

    func seek(to second: Int, play: Bool) {
        Task { await seekPlayback(to: second, play: play) }
    }

    func sync() async {
        let snapshot = await engine.snapshot()
        currentSecond = snapshot.timeSeconds
        if !snapshot.isPlaying { isPlaying = false }
    }

    func stop() {
        Task {
            await engine.stop()
            isPlaying = false
        }
    }

    private func togglePlayback() async {
        if await engine.isPlaying() {
            await engine.pause()
            isPlaying = false
            return
        }
        isPlaying = await engine.play()
    }

    private func seekPlayback(to second: Int, play: Bool) async {
        let clamped = min(max(0, second), max(duration, 0))
        if play {
            isPlaying = await engine.play(from: TimeInterval(clamped))
        } else {
            await engine.setCurrentTime(TimeInterval(clamped))
        }
        currentSecond = clamped
    }
}

/// `AVAudioPlayer.play` calls synchronous `setActive`. Keep that off the main thread.
private final class LecturePlaybackEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.bellnote.lecture-playback", qos: .userInitiated)
    private var player: AVAudioPlayer?
    private var sessionReady = false

    struct Snapshot: Sendable {
        var timeSeconds: Int
        var isPlaying: Bool
    }

    func reset() async {
        await onQueue { [self] in
            player?.stop()
            player = nil
            sessionReady = false
        }
        await deactivateSession()
    }

    func load(_ url: URL) async -> Int {
        let data = await Task.detached(priority: .userInitiated) {
            try? Data(contentsOf: url)
        }.value
        guard let data else { return 0 }
        return await onQueue { [self] in
            guard let player = try? AVAudioPlayer(data: data) else { return 0 }
            self.player = player
            return Int(player.duration.rounded())
        }
    }

    func isPlaying() async -> Bool {
        await onQueue { [self] in player?.isPlaying ?? false }
    }

    func pause() async {
        await onQueue { [self] in player?.pause() }
    }

    func stop() async {
        await onQueue { [self] in
            player?.stop()
            sessionReady = false
        }
        await deactivateSession()
    }

    func setCurrentTime(_ time: TimeInterval) async {
        await onQueue { [self] in player?.currentTime = time }
    }

    func play(from time: TimeInterval? = nil) async -> Bool {
        guard await ensureSession() else { return false }
        return await onQueue { [self] in
            guard let player else { return false }
            if let time { player.currentTime = time }
            player.prepareToPlay()
            return player.play()
        }
    }

    func snapshot() async -> Snapshot {
        await onQueue { [self] in
            Snapshot(
                timeSeconds: Int(player?.currentTime ?? 0),
                isPlaying: player?.isPlaying ?? false
            )
        }
    }

    private func ensureSession() async -> Bool {
        if await onQueue({ [self] in sessionReady }) { return true }
        let ready = await activateSession()
        await onQueue { [self] in sessionReady = ready }
        return ready
    }

    private func onQueue<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: body())
            }
        }
    }

    private func activateSession() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                let session = AVAudioSession.sharedInstance()
                do {
                    try session.setCategory(.playback, mode: .spokenAudio)
                } catch {
                    continuation.resume(returning: false)
                    return
                }
                session.activate(options: []) { activated, _ in
                    continuation.resume(returning: activated)
                }
            }
        }
    }

    private func deactivateSession() async {
        await withCheckedContinuation { continuation in
            queue.async {
                AVAudioSession.sharedInstance().deactivate(options: [.notifyOthersOnDeactivation]) { _, _ in
                    continuation.resume()
                }
            }
        }
    }
}
