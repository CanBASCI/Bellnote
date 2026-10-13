import AVFoundation
import SwiftData
import SwiftUI

struct LecturePage: View {
    @Bindable var lecture: Lecture

    var body: some View {
        LectureNote(lecture: lecture, showsDate: false)
            .navigationTitle(lecture.startedAt.formatted(date: .abbreviated, time: .shortened))
    }
}

struct LectureNote: View {
    @Bindable var lecture: Lecture
    var showsDate: Bool

    @State private var audio = LectureAudio()
    @State private var reader = SpeechReader()
    @State private var showStudy = false
    @State private var studyMode: StudyMode = .ask
    @State private var showAssignments = false

    var body: some View {
        List {
            if lecture.state != LectureState.ready.rawValue && lecture.audioRelativePath != nil {
                Section {
                    Button("Process") {
                        Task { await process() }
                    }
                }
            }
            Section {
                if showsDate {
                    Text(lecture.startedAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.title2.weight(.semibold))
                }
                if lecture.recordedSeconds >= 60 {
                    Text(String(format: String(localized: "%lld min"), lecture.recordedSeconds / 60))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text(bodyText)
                if let course = lecture.course {
                    HStack(spacing: 8) {
                        Button("Ask") {
                            studyMode = .ask
                            showStudy = true
                        }
                        .buttonStyle(.bordered)
                        Button(quizTitle(course)) {
                            studyMode = .quiz
                            showStudy = true
                        }
                        .buttonStyle(.bordered)
                        Button("Listen") { listen(course) }
                            .buttonStyle(.bordered)
                    }
                    .padding(.top, 4)
                }
            }
            if !chapters.isEmpty || !lecture.flaggedSeconds.isEmpty {
                Section("Chapters") {
                    ForEach(chapters) { block in
                        Button {
                            audio.seek(to: block.second, play: true)
                        } label: {
                            chapterLabel(block)
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(Array(orphanFlags.enumerated()), id: \.offset) { _, second in
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
            if let course = lecture.course, !course.assignments.isEmpty {
                Section {
                    Button {
                        showAssignments = true
                    } label: {
                        if openCount(course) == 0 {
                            Text("Assignments")
                        } else {
                            LabeledContent("Assignments", value: String(format: String(localized: "%lld open"), openCount(course)))
                        }
                    }
                }
            }
            if !lecture.blocks.isEmpty {
                Section {
                    DisclosureGroup("Raw") {
                        ForEach(lecture.blocks.sorted { $0.second < $1.second }) { block in
                            Text(block.text)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if audio.duration > 0 {
                playback
            }
        }
        .task(id: lecture.persistentModelID) {
            await audio.load(lecture)
        }
        .onDisappear { audio.stop() }
        .task(id: audio.isPlaying) {
            while !Task.isCancelled, audio.isPlaying {
                try? await Task.sleep(for: .milliseconds(400))
                audio.sync()
            }
        }
        .sheet(isPresented: $showStudy) {
            if let course = lecture.course {
                StudySheet(course: course, mode: studyMode)
            }
        }
        .sheet(isPresented: $showAssignments) {
            if let course = lecture.course {
                AssignmentSheet(course: course)
            }
        }
    }

    private var playback: some View {
        HStack(spacing: 12) {
            Button(audio.isPlaying ? "Pause" : "Play", systemImage: audio.isPlaying ? "pause.fill" : "play.fill") {
                audio.toggle()
            }
            .labelStyle(.iconOnly)
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
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var bodyText: String {
        let summary = lecture.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty { return summary }
        if let failure = lecture.failureMessageKey, !failure.isEmpty { return failure }
        return String(localized: "No summary yet.")
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
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(MediaClock.short(block.second))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(current ? Color.accentColor : Color.secondary)
                    .frame(width: 52, alignment: .leading)
                Text(MediaClock.sentence(block.text))
                    .foregroundStyle(.primary)
                    .fontWeight(current ? .semibold : .regular)
                    .multilineTextAlignment(.leading)
            }
            if block.missing || block.userFlag {
                Text("Missing")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 64)
            }
        }
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
        course.assignments.filter { !$0.done }.count
    }

    private func listen(_ course: Course) {
        let text = lecture.summary.isEmpty ? chapters.map(\.text).joined(separator: "\n") : lecture.summary
        reader.read(text, locale: Locale(identifier: course.localeIdentifier))
    }

    private func process() async {
        guard let context = lecture.modelContext else { return }
        await LecturePipeline.advance(
            lecture: lecture,
            context: context,
            preferTaggerForPage: UserDefaults.standard.bool(forKey: AppPreferences.pagePrefersTaggerKey)
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
    private var player: AVAudioPlayer?
    private var sessionReady = false

    func load(_ lecture: Lecture) async {
        guard player == nil, let relative = lecture.audioRelativePath else { return }
        guard let root = try? Vault.documents() else { return }
        let url = root.appendingPathComponent(relative)
        let path = url.path
        guard FileManager.default.fileExists(atPath: path) else { return }
        let data = await Task.detached(priority: .userInitiated) {
            try? Data(contentsOf: url)
        }.value
        guard let data, let player = try? AVAudioPlayer(data: data) else { return }
        self.player = player
        duration = Int(player.duration.rounded())
        currentSecond = 0
    }

    func toggle() {
        Task { await togglePlayback() }
    }

    func seek(to second: Int, play: Bool) {
        Task { await seekPlayback(to: second, play: play) }
    }

    func sync() {
        guard let player else { return }
        currentSecond = Int(player.currentTime)
        if !player.isPlaying { isPlaying = false }
    }

    func stop() {
        player?.stop()
        isPlaying = false
        sessionReady = false
        Task { await deactivateSession() }
    }

    private func togglePlayback() async {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            return
        }
        guard await activateSession() else { return }
        player.play()
        isPlaying = true
    }

    private func seekPlayback(to second: Int, play: Bool) async {
        guard let player else { return }
        let clamped = min(max(0, second), max(duration, 0))
        player.currentTime = TimeInterval(clamped)
        currentSecond = clamped
        guard play else { return }
        guard await activateSession() else { return }
        player.play()
        isPlaying = true
    }

    private func activateSession() async -> Bool {
        if sessionReady { return true }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio)
        } catch {
            return false
        }
        let activated = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            session.activate(options: []) { activated, _ in
                continuation.resume(returning: activated)
            }
        }
        sessionReady = activated
        return activated
    }

    private func deactivateSession() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            AVAudioSession.sharedInstance().deactivate(options: [.notifyOthersOnDeactivation]) { _, _ in
                continuation.resume()
            }
        }
    }
}
