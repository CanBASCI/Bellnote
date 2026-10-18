import ActivityKit
import Foundation

/// Static and live fields for the recording Live Activity (Lock Screen + Dynamic Island).
/// The extension defines the same shape under the same type name so both processes agree.
struct RecordingAttributes: ActivityAttributes {
    /// Course name shown while the microphone runs.
    var courseName: String

    struct ContentState: Codable, Hashable {
        /// True when the student paused capture.
        var isPaused: Bool
        /// Frozen elapsed seconds while paused.
        var elapsedSeconds: Int
        /// Wall clock such that `now - timingAnchor` equals elapsed while recording.
        var timingAnchor: Date
        /// How many “I didn't get this” flags so far (visible confirmation on the Live Activity).
        var flagCount: Int
    }
}
