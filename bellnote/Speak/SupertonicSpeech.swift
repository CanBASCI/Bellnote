import Foundation
import OSLog
import SherpaOnnx
import SherpaOnnxC

enum SupertonicVoice {
    static let count = 10

    static func clamped(_ value: Int) -> Int {
        min(max(value, 0), count - 1)
    }

    /// voice.bin is filename-sorted, so ids 0...4 are F1...F5 and 5...9 are M1...M5.
    static func title(_ speaker: Int, locale: Locale) -> String {
        let speaker = clamped(speaker)
        if speaker < 5 {
            return String(format: String(localized: "Female %lld", locale: locale), speaker + 1)
        }
        return String(format: String(localized: "Male %lld", locale: locale), speaker - 4)
    }

    static func greeting(_ speaker: Int, locale: Locale) -> String {
        let name = title(speaker, locale: locale)
        return String(format: String(localized: "Hello, I am %@.", locale: locale), name)
    }
}

enum SupertonicError: Error {
    case notInstalled
    case failed
}

struct SupertonicClip: Sendable {
    var samples: [Float]
    var sampleRate: Int32
}

final class SupertonicCancel: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var stopped: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        set {
            lock.lock()
            value = newValue
            lock.unlock()
        }
    }
}

enum SupertonicSpeech {
    private static let log = Logger(subsystem: "app.bellnote", category: "listen")
    private static let queue = DispatchQueue(label: "app.bellnote.supertonic")
    private static let fileNames = [
        "duration_predictor.int8.onnx",
        "text_encoder.int8.onnx",
        "vector_estimator.int8.onnx",
        "vocoder.int8.onnx",
        "tts.json",
        "unicode_indexer.bin",
        "voice.bin"
    ]
    nonisolated(unsafe) private static var engine: SherpaOnnxOfflineTtsWrapper?

    static var isInstalled: Bool {
        let directory = HubWeights.directory(for: ModelCatalog.supertonicRepo)
        return fileNames.allSatisfy {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    static var hasPartial: Bool {
        let directory = HubWeights.directory(for: ModelCatalog.supertonicRepo)
        let any = fileNames.contains {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
        return any && !isInstalled
    }

    static func installedByteCount() -> Int64 {
        let directory = HubWeights.directory(for: ModelCatalog.supertonicRepo)
        return fileNames.reduce(0) { sum, name in
            let url = directory.appendingPathComponent(name)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return sum + Int64(size)
        }
    }

    static func download(onProgress: @Sendable @escaping (Double) -> Void) async throws {
        log.info("Supertonic download begin")
        let downloader = HubSnapshotDownloader()
        _ = try await downloader.download(
            id: ModelCatalog.supertonicRepo,
            revision: "main",
            matching: fileNames,
            useLatest: false
        ) { progress in
            onProgress(progress.fractionCompleted)
        }
        guard isInstalled else {
            log.error("Supertonic download missing files")
            throw SupertonicError.failed
        }
        log.info("Supertonic download ok")
    }

    static func delete() throws {
        queue.async { engine = nil }
        try HubWeights.remove(ModelCatalog.supertonicRepo)
        log.info("Supertonic delete ok")
    }

    static func clip(text: String, language: String, speaker voice: Int, cancel: SupertonicCancel) async throws -> SupertonicClip {
        let voice = SupertonicVoice.clamped(voice)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let clip = try render(text: text, language: language, voice: voice, cancel: cancel)
                    continuation.resume(returning: clip)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func render(text: String, language: String, voice: Int, cancel: SupertonicCancel) throws -> SupertonicClip {
        guard isInstalled else { throw SupertonicError.notInstalled }
        let tts = try loaded()
        let sid = voice
        var samples: [Float] = []
        var rate: Int32 = 44_100
        for piece in pieces(text) {
            if cancel.stopped { return SupertonicClip(samples: [], sampleRate: rate) }
            var generation = SherpaOnnxGenerationConfigSwift()
            generation.sid = sid
            generation.numSteps = 8
            generation.speed = 1
            generation.extra = ["lang": language]
            let callback: TtsProgressCallbackWithArg = { _, _, _, raw in
                guard let raw else { return 1 }
                let flag = Unmanaged<SupertonicCancel>.fromOpaque(raw).takeUnretainedValue()
                return flag.stopped ? 0 : 1
            }
            let token = Unmanaged.passUnretained(cancel).toOpaque()
            let audio = tts.generateWithConfig(text: piece, config: generation, callback: callback, arg: token)
            guard audio.audio != nil, audio.n > 0 else { throw SupertonicError.failed }
            rate = audio.sampleRate
            if !samples.isEmpty {
                samples.append(contentsOf: Array(repeating: 0, count: Int(Double(rate) * 0.12)))
            }
            samples.append(contentsOf: audio.samples)
        }
        if cancel.stopped { return SupertonicClip(samples: [], sampleRate: rate) }
        return SupertonicClip(samples: samples, sampleRate: rate)
    }

    private static func loaded() throws -> SherpaOnnxOfflineTtsWrapper {
        if let engine { return engine }
        let directory = HubWeights.directory(for: ModelCatalog.supertonicRepo)
        let pointers = fileNames.map { strdup(directory.appendingPathComponent($0).path)! }
        defer { pointers.forEach { free($0) } }
        var supertonic = sherpaOnnxOfflineTtsSupertonicModelConfig()
        supertonic.duration_predictor = UnsafePointer(pointers[0])
        supertonic.text_encoder = UnsafePointer(pointers[1])
        supertonic.vector_estimator = UnsafePointer(pointers[2])
        supertonic.vocoder = UnsafePointer(pointers[3])
        supertonic.tts_json = UnsafePointer(pointers[4])
        supertonic.unicode_indexer = UnsafePointer(pointers[5])
        supertonic.voice_style = UnsafePointer(pointers[6])
        let model = sherpaOnnxOfflineTtsModelConfig(numThreads: 2, supertonic: supertonic)
        var config = sherpaOnnxOfflineTtsConfig(model: model)
        let wrapper = SherpaOnnxOfflineTtsWrapper(config: &config)
        guard wrapper.tts != nil else {
            log.error("Supertonic load failed")
            throw SupertonicError.failed
        }
        log.info("Supertonic loaded rate=\(wrapper.sampleRate) speakers=\(wrapper.numSpeakers)")
        engine = wrapper
        return wrapper
    }

    private static func pieces(_ text: String) -> [String] {
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var chunks: [String] = []
        var current = ""
        for word in words {
            let next = current.isEmpty ? word : current + " " + word
            if next.count > 240, !current.isEmpty {
                chunks.append(current)
                current = word
            } else {
                current = next
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks.isEmpty ? [text] : chunks
    }
}
