import AVFoundation
import Combine
import OSLog
import SwiftData
import SwiftUI
import UIKit

struct ConsentSheet: View {
    var course: Course
    var onConfirm: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var allowed = false
    @State private var permitted = false

    /// Only the first recording of a course opens this sheet. Later ones use the confirm dialog in `ConsentFlow`.
    var body: some View {
        NavigationStack {
            Form {
                Toggle("I am allowed to record this class", isOn: $allowed)
                    .switchTrackTint()
                Toggle("The lecturer or school permitted recording", isOn: $permitted)
                    .switchTrackTint()
                Text("This is your confirmation, not proof that the lecturer consented.")
                    .appFont(.footnote)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("Recording")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") {
                        onConfirm(false)
                        dismiss()
                    }
                    .disabled(!ConsentGate(allowed: allowed, permitted: permitted).canStart)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

struct RecorderSheet: View {
    @Bindable var lecture: Lecture
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    private static let log = Logger(subsystem: "app.bellnote", category: "capture")
    @State private var capture = CaptureSession()
    @State private var elapsed = 0
    @State private var askStop = false
    @State private var askResume = false
    @State private var failed: String?
    @State private var ticker: Timer?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                VStack(spacing: 10) {
                    Label("On this device", systemImage: "lock.fill")
                        .appFont(.caption, weight: .semibold)
                        .foregroundStyle(.green)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.15), in: Capsule())
                    Text(MediaClock.full(elapsed))
                        .font(.system(size: 56, weight: .semibold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText())
                    Image(systemName: "waveform")
                        .font(.system(size: 44, weight: .medium))
                        .foregroundStyle(capture.isRunning ? Color.accentColor : Color.secondary)
                        .symbolEffect(.variableColor.iterative, isActive: capture.isRunning)
                        .accessibilityHidden(true)
                    Text(capture.isRunning ? "Recording" : "Paused")
                        .appFont(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 12)
                if let failed {
                    Text(failed)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                ScrollView {
                    if !lecture.flaggedSeconds.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("So far")
                                .appFont(.subheadline, weight: .semibold)
                                .foregroundStyle(.secondary)
                            ForEach(Array(lecture.flaggedSeconds.enumerated()), id: \.offset) { _, second in
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text(MediaClock.short(second))
                                        .appFont(.subheadline, digits: true)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 56, alignment: .leading)
                                    Text("I didn't get this")
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                GlassEffectContainer(spacing: 28) {
                    HStack(alignment: .top, spacing: 28) {
                        controlButton(
                            capture.isRunning ? "Pause" : "Resume",
                            systemImage: capture.isRunning ? "pause.fill" : "play.fill"
                        ) {
                            if capture.isRunning {
                                pause()
                            } else {
                                Task { await resume() }
                            }
                        }
                        controlButton("Stop", systemImage: "stop.fill", prominent: true) { askStop = true }
                        controlButton("I didn't get this", systemImage: "flag.fill") { flag() }
                    }
                }
                .padding(.bottom, 8)
            }
            .padding()
            .navigationTitle(lecture.course?.name ?? "")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(true)
        .task { await begin() }
        .onDisappear { ticker?.invalidate() }
        .onReceive(
            NotificationCenter.default.publisher(for: .recordingLivePause).receive(on: RunLoop.main)
        ) { _ in
            guard capture.isRunning else { return }
            pause()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .recordingLiveResume).receive(on: RunLoop.main)
        ) { _ in
            guard !capture.isRunning else { return }
            Task { await resume() }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .recordingLiveStop).receive(on: RunLoop.main)
        ) { _ in
            Task { await finish() }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .recordingLiveFlag).receive(on: RunLoop.main)
        ) { _ in
            flag()
        }
        .alert("End this lecture?", isPresented: $askStop) {
            Button("Yes", role: .destructive) { Task { await finish() } }
            Button("No", role: .cancel) { pause() }
        }
        .alert("Resume recording?", isPresented: $askResume) {
            Button("Resume") { Task { await resume() } }
            Button("Stay paused", role: .cancel) {}
        }
    }

    /// A round system glass button with its name under it. Stop is the large red one.
    @ViewBuilder
    private func controlButton(
        _ title: LocalizedStringKey,
        systemImage: String,
        prominent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 6) {
            if prominent {
                Button(action: action) {
                    Image(systemName: systemImage)
                        .appFont(.title)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .tint(.red)
                .accessibilityLabel(Text(title))
            } else {
                Button(action: action) {
                    Image(systemName: systemImage)
                        .appFont(.title3)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .accessibilityLabel(Text(title))
            }
            Text(title)
                .appFont(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(width: 84)
        }
    }

    private func begin() async {
        Self.log.info("Recorder sheet appeared, starting")
        let permitted = await AVAudioApplication.requestRecordPermission()
        guard permitted else {
            Self.log.error("Recorder: microphone permission is off")
            failed = String(localized: "The microphone is off for Bellnote.")
            lecture.state = LectureState.failed.rawValue
            lecture.failureMessageKey = failed
            return
        }
        do {
            let folder = try Vault.courseDirectory(id: lecture.course?.token ?? UUID())
            let url = folder.appendingPathComponent("\(lecture.startedAt.timeIntervalSince1970).m4a")
            try await capture.start(url: url)
            if let root = try? Vault.documents() {
                lecture.audioRelativePath = url.path.replacingOccurrences(of: root.path + "/", with: "")
            }
            lecture.state = LectureState.recording.rawValue
            capture.onInterrupted = {
                Task { @MainActor in
                    elapsed = capture.elapsedSeconds()
                    lecture.recordedSeconds = elapsed
                    await RecordingLiveActivity.update(elapsedSeconds: elapsed, isPaused: true)
                }
            }
            capture.onInterruptionEnded = {
                Task { @MainActor in
                    askResume = true
                }
            }
            ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                Task { @MainActor in
                    elapsed = capture.elapsedSeconds()
                    lecture.recordedSeconds = elapsed
                }
            }
            await RecordingLiveActivity.start(courseName: lecture.course?.name ?? String(localized: "Course"))
        } catch {
            Self.log.error("Recorder: start failed: \(error.localizedDescription, privacy: .public)")
            failed = String(localized: "Recording did not start.")
            lecture.state = LectureState.failed.rawValue
            lecture.failureMessageKey = failed
            await RecordingLiveActivity.end()
        }
    }

    private func pause() {
        Self.tapFeedback()
        capture.pauseCapture()
        lecture.state = LectureState.paused.rawValue
        let segment = PauseSegment(startedAt: .now, lecture: lecture)
        modelContext.insert(segment)
        Task {
            await RecordingLiveActivity.update(
                elapsedSeconds: elapsed,
                isPaused: true,
                flagCount: lecture.flaggedSeconds.count
            )
        }
    }

    private func resume() async {
        Self.tapFeedback()
        do {
            try await capture.resumeCapture()
            lecture.state = LectureState.recording.rawValue
            await RecordingLiveActivity.update(
                elapsedSeconds: elapsed,
                isPaused: false,
                flagCount: lecture.flaggedSeconds.count
            )
        } catch {
            Self.log.error("Recorder: resume failed: \(error.localizedDescription, privacy: .public)")
            failed = String(localized: "Recording did not resume.")
        }
    }

    private func flag() {
        Self.tapFeedback()
        let second = capture.elapsedSeconds()
        lecture.flaggedSeconds.append(second)
        Self.log.info("Recorder: flagged second=\(second) count=\(lecture.flaggedSeconds.count)")
        Task {
            await RecordingLiveActivity.update(
                elapsedSeconds: second,
                isPaused: !capture.isRunning,
                flagCount: lecture.flaggedSeconds.count
            )
        }
    }

    private static func tapFeedback() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func finish() async {
        Self.tapFeedback()
        ticker?.invalidate()
        await RecordingLiveActivity.end()
        do {
            try await capture.stop()
            lecture.recordedSeconds = elapsed
            lecture.state = LectureState.paused.rawValue
            lecture.stage = PipelineStage.idle.rawValue
            try modelContext.save()
            dismiss()
        } catch {
            Self.log.error("Recorder: close failed: \(error.localizedDescription, privacy: .public)")
            failed = String(localized: "The recording could not be closed.")
            lecture.state = LectureState.failed.rawValue
            lecture.failureMessageKey = failed
        }
    }
}
