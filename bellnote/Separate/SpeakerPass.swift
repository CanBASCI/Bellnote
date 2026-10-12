import AVFoundation
import Foundation

// FluidAudio 0.17.7 does not resolve: its binary target returns an invalid archive.
// Until that package links, the file is one narrator run. Room stays out of the note.

enum SpeakerPassError: Error {
    case noSpeech
}

enum SpeakerPass {
    static func runs(url: URL) throws -> [SpeechRun] {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        guard rate > 0 else { throw SpeakerPassError.noSpeech }
        let seconds = Int(Double(file.length) / rate)
        guard seconds > 0 else { throw SpeakerPassError.noSpeech }
        return [
            SpeechRun(
                start: 0,
                end: seconds,
                cluster: 1,
                overlap: false,
                near: false,
                addressedLecturer: false
            )
        ]
    }

    static func narratorRanges(_ runs: [SpeechRun]) -> [ClosedRange<Int>] {
        guard let longest = RoleRules.longestCluster(runs) else { return [] }
        return runs.compactMap { run in
            let role = RoleRules.label(run, longestCluster: longest)
            guard role == .narrator || role == .question else { return nil }
            return run.start...max(run.start, run.end)
        }
    }
}
