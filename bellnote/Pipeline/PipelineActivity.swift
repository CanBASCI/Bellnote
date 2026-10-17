import Foundation
import Observation
import OSLog
import SwiftData
import UIKit

/// Which lectures are being processed right now, and at which stage. It lives outside the
/// screens, so a screen that opens while a lecture is running shows the same progress bar,
/// and a second run of the same lecture cannot start.
@MainActor
@Observable
final class PipelineActivity {
    static let shared = PipelineActivity()
    private static let log = Logger(subsystem: "app.bellnote", category: "pipeline")

    /// What the progress ring shows: a fraction from zero to one, a short name for the middle of
    /// the ring, and a longer explanation under it.
    struct Step: Equatable {
        var fraction: Double
        var title: String
        var info: String
    }

    private(set) var stages: [PersistentIdentifier: PipelineStage] = [:]
    private var details: [PersistentIdentifier: Step] = [:]
    private var tasks: [PersistentIdentifier: Task<Void, Never>] = [:]
    /// Lectures whose run was asked to stop and has not ended yet. The ring says so.
    private(set) var stopping: Set<PersistentIdentifier> = []

    func stage(for lecture: Lecture) -> PipelineStage? {
        stages[lecture.persistentModelID]
    }

    func isRunning(_ lecture: Lecture) -> Bool {
        stages[lecture.persistentModelID] != nil
    }

    /// A finer step inside the stage, such as Whisper getting ready. Falls back to the stage.
    func step(for lecture: Lecture) -> Step? {
        let id = lecture.persistentModelID
        if let detail = details[id] { return detail }
        return stages[id].map { Step(fraction: $0.fraction, title: $0.title, info: $0.info) }
    }

    func set(_ stage: PipelineStage, for lecture: Lecture) {
        stages[lecture.persistentModelID] = stage
        details[lecture.persistentModelID] = nil
        keepScreenAwake()
    }

    /// The AI model runs on the GPU, and iOS does not let an app use the GPU in the background.
    /// A locked screen would stop the work, so the screen stays on while any lecture is processed.
    private func keepScreenAwake() {
        UIApplication.shared.isIdleTimerDisabled = !stages.isEmpty
    }

    func setDetail(_ step: Step, for lecture: Lecture) {
        guard stages[lecture.persistentModelID] != nil else { return }
        details[lecture.persistentModelID] = step
    }

    /// The running work of a lecture, kept so the student can stop it.
    func register(_ task: Task<Void, Never>, for lecture: Lecture) {
        tasks[lecture.persistentModelID] = task
    }

    /// Asks the run to stop. A step that does not look at the cancel flag ends first, and the run
    /// stops right after it.
    func stop(_ lecture: Lecture) {
        let id = lecture.persistentModelID
        guard let stage = stages[id] else {
            Self.log.info("Stop ignored: the lecture is not running")
            return
        }
        stopping.insert(id)
        let hasTask = tasks[id] != nil
        Self.log.info("Stop requested stage=\(stage.rawValue, privacy: .public) hasTask=\(hasTask)")
        tasks[id]?.cancel()
    }

    func isStopping(_ lecture: Lecture) -> Bool {
        stopping.contains(lecture.persistentModelID)
    }

    func clear(for lecture: Lecture) {
        let id = lecture.persistentModelID
        stages[id] = nil
        details[id] = nil
        tasks[id] = nil
        stopping.remove(id)
        keepScreenAwake()
    }
}
