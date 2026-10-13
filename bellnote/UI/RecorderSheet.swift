import AVFoundation
import SwiftData
import SwiftUI

struct ConsentSheet: View {
    var course: Course
    var onConfirm: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var allowed = false
    @State private var permitted = false

    private var later: Bool { course.lectures.contains { $0.attestation != nil } }

    var body: some View {
        NavigationStack {
            Form {
                if later {
                    Text("Record this class for \(course.name)?")
                } else {
                    Toggle("I am allowed to record this class", isOn: $allowed)
                    Toggle("The lecturer or school permitted recording", isOn: $permitted)
                    Text("This is your confirmation, not proof that the lecturer consented.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
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
                    .disabled(!later && !ConsentGate(allowed: allowed, permitted: permitted).canStart)
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
    @State private var capture = CaptureSession()
    @State private var elapsed = 0
    @State private var askStop = false
    @State private var askResume = false
    @State private var failed: String?
    @State private var ticker: Timer?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(capture.isRunning ? Color.pink : Color.secondary.opacity(0.45))
                        .frame(width: 16, height: 16)
                        .accessibilityLabel(Text("Recording"))
                    Text(capture.isRunning ? "Recording" : "Paused")
                        .foregroundStyle(.secondary)
                    Text(MediaClock.full(elapsed))
                        .font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
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
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(Array(lecture.flaggedSeconds.enumerated()), id: \.offset) { _, second in
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text(MediaClock.short(second))
                                        .font(.subheadline.monospacedDigit())
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
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        Button(capture.isRunning ? "Pause" : "Resume") {
                            capture.isRunning ? pause() : resume()
                        }
                        .buttonStyle(.glass)
                        Button("I didn't get this") { flag() }
                            .buttonStyle(.glass)
                    }
                    Button("Stop") { askStop = true }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                }
            }
            .padding()
            .navigationTitle(lecture.course?.name ?? "")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(true)
        .task { await begin() }
        .onDisappear { ticker?.invalidate() }
        .confirmationDialog("End this lecture?", isPresented: $askStop) {
            Button("Yes", role: .destructive) { Task { await finish() } }
            Button("No", role: .cancel) { pause() }
        }
        .confirmationDialog("Resume recording?", isPresented: $askResume) {
            Button("Resume") { resume() }
            Button("Stay paused", role: .cancel) {}
        }
    }

    private func begin() async {
        let permitted = await AVAudioApplication.requestRecordPermission()
        guard permitted else {
            failed = String(localized: "The microphone is off for Bellnote.")
            lecture.state = LectureState.failed.rawValue
            lecture.failureMessageKey = failed
            return
        }
        do {
            let folder = try Vault.courseDirectory(id: lecture.course?.token ?? UUID())
            let url = folder.appendingPathComponent("\(lecture.startedAt.timeIntervalSince1970).m4a")
            try capture.start(url: url)
            if let root = try? Vault.documents() {
                lecture.audioRelativePath = url.path.replacingOccurrences(of: root.path + "/", with: "")
            }
            lecture.state = LectureState.recording.rawValue
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
        } catch {
            failed = String(localized: "Recording did not start.")
            lecture.state = LectureState.failed.rawValue
            lecture.failureMessageKey = failed
        }
    }

    private func pause() {
        capture.pauseCapture()
        lecture.state = LectureState.paused.rawValue
        let segment = PauseSegment(startedAt: .now, lecture: lecture)
        modelContext.insert(segment)
    }

    private func resume() {
        do {
            try capture.resumeCapture()
            lecture.state = LectureState.recording.rawValue
        } catch {
            failed = String(localized: "Recording did not resume.")
        }
    }

    private func flag() {
        lecture.flaggedSeconds.append(capture.elapsedSeconds())
    }

    private func finish() async {
        ticker?.invalidate()
        do {
            try capture.stop()
            lecture.recordedSeconds = elapsed
            lecture.state = LectureState.paused.rawValue
            lecture.stage = PipelineStage.idle.rawValue
            try modelContext.save()
            dismiss()
        } catch {
            failed = String(localized: "The recording could not be closed.")
            lecture.state = LectureState.failed.rawValue
            lecture.failureMessageKey = failed
        }
    }
}
