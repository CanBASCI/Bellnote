import AVFoundation
import Foundation
import Speech

struct TranscriptLine: Sendable, Equatable {
    var second: Int
    var text: String
    var role: SpeakerRole
}

enum TranscriptError: Error {
    case assetMissing
    case qualityFailed
    case unreadable
}

enum LectureTranscriber {
    static func transcribe(
        url: URL,
        locale: Locale,
        keeping ranges: [ClosedRange<Int>]
    ) async throws -> [TranscriptLine] {
        let transcriber = SpeechTranscriber(
            locale: locale,
            preset: .timeIndexedTranscriptionWithAlternatives
        )
        let status = await AssetInventory.status(forModules: [transcriber])
        if status != .installed {
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
                throw TranscriptError.assetMissing
            }
            try await request.downloadAndInstall()
        }
        let file = try AVAudioFile(forReading: url)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task { try await collect(transcriber) }
        try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
        let lines = try await collector.value
        let kept = lines.filter { line in
            ranges.isEmpty || ranges.contains { $0.contains(line.second) }
        }
        let joined = kept.map(\.text).joined(separator: " ")
        let seconds = max(kept.last?.second ?? 0, 1)
        guard QualityGate.passes(text: joined, expectedSeconds: seconds) else {
            throw TranscriptError.qualityFailed
        }
        return kept
    }

    private static func collect(_ transcriber: SpeechTranscriber) async throws -> [TranscriptLine] {
        var lines: [TranscriptLine] = []
        for try await result in transcriber.results where result.isFinal {
            let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let second = Int(result.range.start.seconds.rounded(.down))
            lines.append(TranscriptLine(second: max(0, second), text: text, role: .narrator))
        }
        return lines
    }
}
