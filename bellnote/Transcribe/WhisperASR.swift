import AVFoundation
import Foundation
import HuggingFace
import OSLog
import WhisperKit

/// Whisper large-v3 turbo writes the words. It was trained on a lot of noisy, far-field audio,
/// which suits a lecture hall. The student picks this engine in Settings once the model is
/// installed. Nothing is downloaded from here.
enum WhisperASR {
    private static let log = Logger(subsystem: "app.bellnote", category: "whisper-asr")
    /// Whisper reads 30 s at a time.
    private static let windowSeconds = 28

    /// WhisperKit keeps its files under `models/<owner>/<repo>` inside this folder.
    /// It sits next to the Hub cache the other models use.
    static func baseDirectory() -> URL {
        HubCache.default.cacheDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("whisperkit", isDirectory: true)
    }

    static func modelDirectory() -> URL {
        HubApiWrapper(downloadBase: baseDirectory())
            .localRepoLocation(HubApiWrapper.Repo(id: ModelCatalog.whisperRepo))
            .appendingPathComponent(ModelCatalog.whisperVariant, isDirectory: true)
    }

    static func tokenizerDirectory() -> URL {
        HubApiWrapper(downloadBase: baseDirectory())
            .localRepoLocation(HubApiWrapper.Repo(id: ModelCatalog.whisperTokenizerRepo))
    }

    static func tokenizerIsInstalled() -> Bool {
        let manager = FileManager.default
        let directory = tokenizerDirectory()
        return ["tokenizer.json", "tokenizer_config.json"].allSatisfy {
            manager.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    /// Ready only when the Core ML files and the tokenizer are both on disk.
    static func snapshot() -> HubWeights.Snapshot {
        var snapshot = HubWeights.snapshot(at: modelDirectory(), id: ModelCatalog.whisperRepo)
        if !tokenizerIsInstalled() { snapshot.hasConfig = false }
        return snapshot
    }

    static func isInstalled() -> Bool {
        snapshot().isReady
    }

    static func remove() throws {
        let base = baseDirectory()
        if FileManager.default.fileExists(atPath: base.path) {
            try FileManager.default.removeItem(at: base)
        }
    }

    /// Only called from the Download button. The Core ML files come first, then the three
    /// tokenizer files WhisperKit needs to read the text. About 0.65 GB in all.
    static func download(onProgress: (@Sendable (Double) -> Void)?) async throws {
        let base = baseDirectory()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var excluded = base
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
        log.info("Whisper download begin variant=\(ModelCatalog.whisperVariant, privacy: .public)")
        onProgress?(0)
        _ = try await WhisperKit.download(
            variant: ModelCatalog.whisperVariant,
            downloadBase: base,
            from: ModelCatalog.whisperRepo
        ) { progress in
            onProgress?(progress.fractionCompleted * 0.99)
        }
        _ = try await HubApiWrapper(downloadBase: base).snapshot(
            from: HubApiWrapper.Repo(id: ModelCatalog.whisperTokenizerRepo),
            matching: ["config.json", "tokenizer.json", "tokenizer_config.json"]
        )
        onProgress?(1)
        let after = snapshot()
        log.info("Whisper download finished bytes=\(after.bytes) coreML=\(after.coreMLCount) ready=\(after.isReady)")
    }

    static func transcribe(url: URL, locale: Locale, runs: [SpeechRun]) async throws -> [TranscriptLine] {
        guard isInstalled() else { throw TranscriptError.whisperMissing }
        let disk = snapshot()
        log.info(
            "Whisper files path=\(modelDirectory().path, privacy: .public) bytes=\(disk.bytes) coreML=\(disk.coreMLCount) tokenizer=\(tokenizerIsInstalled()) turns=\(LectureTranscriber.hasTurns(runs)) locale=\(locale.identifier, privacy: .public)"
        )
        await LocalModelRuntime.shared.unloadAll()
        log.info("Whisper load footprintMB=\(MemoryProbe.footprintMB())")
        // The first load on a device is slow: Core ML prepares the model for this chip, and that
        // can take minutes. The result is cached, so the next loads are quick.
        let config = WhisperKitConfig(
            downloadBase: baseDirectory(),
            modelFolder: modelDirectory().path,
            tokenizerFolder: baseDirectory(),
            verbose: true,
            logLevel: .info,
            prewarm: false,
            load: false,
            download: false
        )
        let kit = try await WhisperKit(config)
        kit.modelStateCallback = { _, state in
            log.info("Whisper model state=\(state.description, privacy: .public)")
        }
        let started = Date()
        // A line every 10 s tells a slow first-time Core ML preparation from a real hang.
        let heartbeat = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                log.info(
                    "Whisper still working seconds=\(Int(Date().timeIntervalSince(started))) footprintMB=\(MemoryProbe.footprintMB()) thermal=\(ProcessInfo.processInfo.thermalState.rawValue)"
                )
            }
        }
        defer { heartbeat.cancel() }
        do {
            log.info("Whisper prepare begin")
            try await kit.prewarmModels()
            log.info("Whisper prepare done seconds=\(Int(Date().timeIntervalSince(started)))")
            try await kit.loadModels()
            log.info("Whisper loaded seconds=\(Int(Date().timeIntervalSince(started))) footprintMB=\(MemoryProbe.footprintMB()) tokenizer=\(kit.tokenizer != nil)")
        } catch {
            log.error("Whisper load failed seconds=\(Int(Date().timeIntervalSince(started))) type=\(String(describing: type(of: error)), privacy: .public) message=\(error.localizedDescription, privacy: .public) detail=\(String(describing: error), privacy: .public)")
            throw error
        }
        let lines: [TranscriptLine]
        do {
            lines = try await write(url: url, locale: locale, runs: runs, kit: kit)
        } catch {
            await kit.unloadModels()
            log.info("Whisper unloaded footprintMB=\(MemoryProbe.footprintMB())")
            throw error
        }
        await kit.unloadModels()
        log.info("Whisper unloaded footprintMB=\(MemoryProbe.footprintMB())")
        return lines
    }

    private static func write(
        url: URL,
        locale: Locale,
        runs: [SpeechRun],
        kit: WhisperKit
    ) async throws -> [TranscriptLine] {
        if LectureTranscriber.hasTurns(runs) {
            return try await LectureTranscriber.transcribeTurns(
                url: url,
                runs: runs,
                windowSeconds: windowSeconds,
                engine: "Whisper"
            ) { clip in
                let begun = Date()
                do {
                    let results = try await kit.transcribe(
                        audioPath: clip.path,
                        decodeOptions: options(for: locale, timestamps: false)
                    )
                    let text = results.map(\.text).joined(separator: " ")
                    let segments = results.flatMap(\.segments)
                    let silent = segments.map { String(format: "%.2f", $0.noSpeechProb) }.joined(separator: ",")
                    log.info(
                        "Whisper clip seconds=\(String(format: "%.1f", Date().timeIntervalSince(begun))) results=\(results.count) segments=\(segments.count) noSpeech=\(silent, privacy: .public) language=\(results.first?.language ?? "", privacy: .public) footprintMB=\(MemoryProbe.footprintMB()) raw=\(text, privacy: .public)"
                    )
                    return clean(text)
                } catch {
                    log.error("Whisper clip failed type=\(String(describing: type(of: error)), privacy: .public) message=\(error.localizedDescription, privacy: .public) detail=\(String(describing: error), privacy: .public)")
                    throw error
                }
            }
        }
        // No speaker turns: Whisper reads the whole recording itself.
        log.info("Whisper whole recording begin")
        let results = try await kit.transcribe(
            audioPath: url.path,
            decodeOptions: options(for: locale, timestamps: true)
        )
        var lines: [TranscriptLine] = []
        for segment in results.flatMap(\.segments) {
            let text = clean(segment.text)
            guard !text.isEmpty else { continue }
            lines.append(TranscriptLine(second: max(0, Int(segment.start)), text: text, role: .narrator))
        }
        log.info("Whisper whole recording lines=\(lines.count)")
        guard !lines.isEmpty else { throw TranscriptError.qualityFailed }
        return lines
    }

    /// The course language is named, so the model never has to guess it. Greedy decoding keeps
    /// the text steady. The default thresholds drop silent windows and repeating answers.
    private static func options(for locale: Locale, timestamps: Bool) -> DecodingOptions {
        let code = locale.language.languageCode?.identifier
        return DecodingOptions(
            task: .transcribe,
            language: code,
            temperature: 0,
            temperatureFallbackCount: 3,
            usePrefillPrompt: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: !timestamps,
            suppressBlank: true
        )
    }

    private static func clean(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if GemmaASR.isRunaway(trimmed) {
            log.warning("Whisper dropped a repeating answer")
            return ""
        }
        return trimmed
    }
}
