import Foundation
import Observation
import SwiftData

/// Which lectures are being processed right now, and at which stage. It lives outside the
/// screens, so a screen that opens while a lecture is running shows the same progress bar,
/// and a second run of the same lecture cannot start.
@MainActor
@Observable
final class PipelineActivity {
    static let shared = PipelineActivity()

    /// What the progress ring shows: a fraction from zero to one, a short name for the middle of
    /// the ring, and a longer explanation under it.
    struct Step: Equatable {
        var fraction: Double
        var title: String
        var info: String
    }

    private(set) var stages: [PersistentIdentifier: PipelineStage] = [:]
    private var details: [PersistentIdentifier: Step] = [:]

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
    }

    func setDetail(_ step: Step, for lecture: Lecture) {
        guard stages[lecture.persistentModelID] != nil else { return }
        details[lecture.persistentModelID] = step
    }

    func clear(for lecture: Lecture) {
        stages[lecture.persistentModelID] = nil
        details[lecture.persistentModelID] = nil
    }
}
