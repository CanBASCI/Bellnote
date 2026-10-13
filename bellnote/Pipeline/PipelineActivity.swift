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

    private(set) var stages: [PersistentIdentifier: PipelineStage] = [:]

    func stage(for lecture: Lecture) -> PipelineStage? {
        stages[lecture.persistentModelID]
    }

    func isRunning(_ lecture: Lecture) -> Bool {
        stages[lecture.persistentModelID] != nil
    }

    func set(_ stage: PipelineStage, for lecture: Lecture) {
        stages[lecture.persistentModelID] = stage
    }

    func clear(for lecture: Lecture) {
        stages[lecture.persistentModelID] = nil
    }
}
