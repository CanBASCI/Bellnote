import AVFoundation
import FluidAudio
import Foundation
import OSLog

enum SpeakerPassError: Error {
    case noSpeech
}

enum SpeakerPass {
    private static let log = Logger(subsystem: "app.bellnote", category: "speakers")
    private static let store = DiarizerBox()

    /// True when offline diarizer assets are present on disk (download not required).
    static func modelsAreInstalled() -> Bool {
        store.cacheIsComplete()
    }

    /// Download and compile FluidAudio offline diarizer models, reporting [0, 1] progress.
    static func downloadModels(onProgress: @Sendable @escaping (Double) -> Void) async throws {
        log.info("FluidAudio download begin")
        try await store.downloadAndPrepare { progress in
            onProgress(progress.fractionCompleted)
        }
        log.info("FluidAudio download ok")
    }

    static func deleteModels() {
        log.info("FluidAudio delete begin")
        store.deleteCache()
        log.info("FluidAudio delete ok")
    }

    static func installedByteCount() -> Int64 {
        store.cacheByteCount()
    }

    static func runs(url: URL) async throws -> [SpeechRun] {
        log.info("Diarize begin path=\(url.lastPathComponent, privacy: .public)")
        let result = try await store.process(url)
        let runs = speechRuns(from: result.segments)
        let spans = runs.map { "\($0.cluster):\($0.start)-\($0.end)" }.joined(separator: " ")
        log.info("Diarize ok segments=\(result.segments.count) runs=\(runs.count) spans=\(spans, privacy: .public)")
        if runs.isEmpty {
            return try fallbackSingleNarrator(url: url)
        }
        return runs
    }

    static func narratorRanges(_ runs: [SpeechRun]) -> [ClosedRange<Int>] {
        guard let longest = RoleRules.longestCluster(runs) else { return [] }
        return runs.compactMap { run in
            let role = RoleRules.label(run, longestCluster: longest)
            guard role == .narrator || role == .question else { return nil }
            return run.start...max(run.start, run.end)
        }
    }

    private static func speechRuns(from segments: [TimedSpeakerSegment]) -> [SpeechRun] {
        let ids = Array(Set(segments.map(\.speakerId))).sorted()
        var clusterByID: [String: Int] = [:]
        for (index, id) in ids.enumerated() {
            clusterByID[id] = index + 1
        }

        var runs: [SpeechRun] = []
        for (index, segment) in segments.enumerated() {
            let start = max(0, Int(segment.startTimeSeconds.rounded(.down)))
            let end = max(start, Int(segment.endTimeSeconds.rounded(.up)))
            guard end > start else { continue }
            let cluster = clusterByID[segment.speakerId] ?? 1
            let overlap = segments.enumerated().contains { otherIndex, other in
                guard otherIndex != index, other.speakerId != segment.speakerId else { return false }
                return segment.startTimeSeconds < other.endTimeSeconds
                    && other.startTimeSeconds < segment.endTimeSeconds
            }
            runs.append(
                SpeechRun(
                    start: start,
                    end: end,
                    cluster: cluster,
                    overlap: overlap,
                    near: false,
                    addressedLecturer: false
                )
            )
        }
        return runs.sorted { $0.start < $1.start }
    }

    private static func fallbackSingleNarrator(url: URL) throws -> [SpeechRun] {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        guard rate > 0 else { throw SpeakerPassError.noSpeech }
        let seconds = Int(Double(file.length) / rate)
        guard seconds > 0 else { throw SpeakerPassError.noSpeech }
        log.info("Diarize empty; fallback single narrator seconds=\(seconds)")
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
}

/// FluidAudio's offline manager is not Sendable; serialize access in one box.
private final class DiarizerBox: @unchecked Sendable {
    private var diarizer: OfflineDiarizerManager
    private let lock = NSLock()
    private var prepared = false

    /// Keep voices the first pass already separated. The default mix weight
    /// collapses a short second and third speaker into the longest one.
    private static var lectureConfig: OfflineDiarizerConfig {
        var config = OfflineDiarizerConfig.default
        config.clustering.threshold = 0.45
        config.clustering.warmStartFa = 0.3
        config.clustering.warmStartFb = 0.5
        return config
    }

    init() {
        diarizer = OfflineDiarizerManager(config: DiarizerBox.lectureConfig)
    }

    private static func diarizerRepoPath() -> URL {
        OfflineDiarizerModels.defaultModelsDirectory()
            .appendingPathComponent(Repo.diarizer.folderName)
    }

    func cacheByteCount() -> Int64 {
        let repoPath = Self.diarizerRepoPath()
        guard FileManager.default.fileExists(atPath: repoPath.path) else { return 0 }
        guard
            let enumerator = FileManager.default.enumerator(
                at: repoPath,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            )
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            total += size
        }
        return total
    }

    func deleteCache() {
        ModelHub.clearCache(for: .diarizer, directory: OfflineDiarizerModels.defaultModelsDirectory())
        lock.withLock {
            prepared = false
            diarizer = OfflineDiarizerManager(config: Self.lectureConfig)
        }
    }

    func cacheIsComplete() -> Bool {
        let base = OfflineDiarizerModels.defaultModelsDirectory()
        let repoPath = base.appendingPathComponent(Repo.diarizer.folderName)
        let required = ModelNames.OfflineDiarizer.requiredModels
        let manager = FileManager.default
        for file in required {
            let path = repoPath.appendingPathComponent(file)
            if file.hasSuffix(".mlmodelc") {
                var isDirectory: ObjCBool = false
                guard manager.fileExists(atPath: path.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    return false
                }
            } else if !manager.fileExists(atPath: path.path) {
                return false
            }
        }
        return true
    }

    func downloadAndPrepare(progressHandler: ProgressHandler?) async throws {
        let loaded = try await OfflineDiarizerModels.load(progressHandler: progressHandler)
        diarizer.initialize(models: loaded)
        lock.withLock { prepared = true }
    }

    func process(_ url: URL) async throws -> DiarizationResult {
        let needsPrepare = lock.withLock { !prepared }
        if needsPrepare {
            try await diarizer.prepareModels()
            lock.withLock { prepared = true }
        }
        return try await diarizer.process(url)
    }
}
