import AppIntents
import Foundation

extension Notification.Name {
    static let recordingLivePause = Notification.Name("app.bellnote.recording.live.pause")
    static let recordingLiveResume = Notification.Name("app.bellnote.recording.live.resume")
    static let recordingLiveStop = Notification.Name("app.bellnote.recording.live.stop")
    static let recordingLiveFlag = Notification.Name("app.bellnote.recording.live.flag")
}

/// Pause capture from the Lock Screen or expanded Dynamic Island.
struct PauseRecordingIntent: LiveActivityIntent {
    static var title: LocalizedStringResource { "Pause" }
    static var description: IntentDescription {
        IntentDescription("Pause the lecture recording")
    }

    func perform() async throws -> some IntentResult {
        await postOnMain(.recordingLivePause)
        return .result()
    }
}

/// Resume capture from the Lock Screen or expanded Dynamic Island.
struct ResumeRecordingIntent: LiveActivityIntent {
    static var title: LocalizedStringResource { "Resume" }
    static var description: IntentDescription {
        IntentDescription("Resume the lecture recording")
    }

    func perform() async throws -> some IntentResult {
        await postOnMain(.recordingLiveResume)
        return .result()
    }
}

/// End the lecture from the Lock Screen (same as confirming stop in the app).
struct StopRecordingIntent: LiveActivityIntent {
    static var title: LocalizedStringResource { "Stop" }
    static var description: IntentDescription {
        IntentDescription("End the lecture recording")
    }

    func perform() async throws -> some IntentResult {
        await postOnMain(.recordingLiveStop)
        return .result()
    }
}

/// Mark the current second as “I didn't get this”.
struct FlagRecordingIntent: LiveActivityIntent {
    static var title: LocalizedStringResource { "I didn't get this" }
    static var description: IntentDescription {
        IntentDescription("Flag this second of the lecture")
    }

    func perform() async throws -> some IntentResult {
        await postOnMain(.recordingLiveFlag)
        return .result()
    }
}

private func postOnMain(_ name: Notification.Name) async {
    await MainActor.run {
        NotificationCenter.default.post(name: name, object: nil)
    }
}
