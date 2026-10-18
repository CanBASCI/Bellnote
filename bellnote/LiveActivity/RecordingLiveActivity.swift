import ActivityKit
import Foundation
import OSLog

/// Starts, updates and ends the recording Live Activity from the main app.
enum RecordingLiveActivity {
    private static let log = Logger(subsystem: "app.bellnote", category: "live-activity")
    /// ActivityKit's update/end are concurrent; keep the handle outside actor isolation.
    /// Callers await start/update/end in order from the recorder UI path.
    private nonisolated(unsafe) static var activity: Activity<RecordingAttributes>?

    /// Begins a Live Activity for this course. Safe to call when Live Activities are off: it logs and returns.
    static func start(courseName: String) async {
        await end()
        let info = ActivityAuthorizationInfo()
        guard info.areActivitiesEnabled else {
            log.info("Live Activity skipped, activities are off")
            return
        }
        let attributes = RecordingAttributes(courseName: courseName)
        let state = Self.state(elapsedSeconds: 0, isPaused: false, flagCount: 0)
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
            log.info("Live Activity started course=\(courseName, privacy: .public)")
        } catch {
            log.error("Live Activity start failed message=\(error.localizedDescription, privacy: .public)")
        }
    }

    /// Pushes pause/resume, elapsed, and flag count. Do not call every second while recording.
    static func update(elapsedSeconds: Int, isPaused: Bool, flagCount: Int? = nil) async {
        guard let activity else { return }
        let flags = flagCount ?? activity.content.state.flagCount
        let state = Self.state(elapsedSeconds: elapsedSeconds, isPaused: isPaused, flagCount: flags)
        await activity.update(ActivityContent(state: state, staleDate: nil))
    }

    /// Ends every recording Live Activity this process started.
    static func end() async {
        let running = activity
        activity = nil
        if let running {
            let final = running.content.state
            await running.end(
                ActivityContent(state: final, staleDate: nil),
                dismissalPolicy: .immediate
            )
            log.info("Live Activity ended")
        }
        for leftover in Activity<RecordingAttributes>.activities {
            await leftover.end(nil, dismissalPolicy: .immediate)
        }
    }

    private static func state(elapsedSeconds: Int, isPaused: Bool, flagCount: Int) -> RecordingAttributes.ContentState {
        let seconds = max(0, elapsedSeconds)
        return RecordingAttributes.ContentState(
            isPaused: isPaused,
            elapsedSeconds: seconds,
            timingAnchor: Date().addingTimeInterval(-TimeInterval(seconds)),
            flagCount: max(0, flagCount)
        )
    }
}
