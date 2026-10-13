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
    /// tokenizer files WhisperKit needs to read the text (about 0.65 GB in all). Then Core ML
    /// prepares the model for this chip, which takes minutes the first time. Doing it here means
    /// the first lecture does not wait for it. `onPreparing` is called when that last step starts.
    static func download(
        onProgress: (@Sendable (Double) -> Void)?,
        onPreparing: (@Sendable () -> Void)?
    ) async throws {
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
            onProgress?(progress.fractionCompleted)
        }
        _ = try await HubApiWrapper(downloadBase: base).snapshot(
            from: HubApiWrapper.Repo(id: ModelCatalog.whisperTokenizerRepo),
            matching: ["config.json", "tokenizer.json", "tokenizer_config.json"]
        )
        let after = snapshot()
        log.info("Whisper download finished bytes=\(after.bytes) coreML=\(after.coreMLCount) ready=\(after.isReady)")
        onProgress?(1)
        onPreparing?()
        await prepare()
    }

    private static func makeConfig() -> WhisperKitConfig {
        WhisperKitConfig(
            downloadBase: baseDirectory(),
            modelFolder: modelDirectory().path,
            tokenizerFolder: baseDirectory(),
            verbose: true,
            logLevel: .info,
            prewarm: false,
            load: false,
            download: false
        )
    }

    /// Lets Core ML compile the model for this chip. Apple keeps the result, so later loads are quick.
    /// A failure here is not fatal: the same work then happens on the first lecture.
    private static func prepare() async {
        let started = Date()
        log.info("Whisper prepare begin")
        do {
            let kit = try await WhisperKit(makeConfig())
            do {
                try await kit.prewarmModels()
            } catch {
                await kit.unloadModels()
                throw error
            }
            await kit.unloadModels()
            log.info("Whisper prepare done seconds=\(Int(Date().timeIntervalSince(started)))")
        } catch {
            log.error("Whisper prepare failed message=\(error.localizedDescription, privacy: .public)")
        }
    }

    static func transcribe(url: URL, locale: Locale, runs: [SpeechRun]) async throws -> [TranscriptLine] {
        guard isInstalled() else { throw TranscriptError.whisperMissing }
        let disk = snapshot()
        log.info(
            "Whisper files path=\(modelDirectory().path, privacy: .public) bytes=\(disk.bytes) coreML=\(disk.coreMLCount) tokenizer=\(tokenizerIsInstalled()) runs=\(runs.count) locale=\(locale.identifier, privacy: .public)"
        )
        await LocalModelRuntime.shared.unloadAll()
        log.info("Whisper load footprintMB=\(MemoryProbe.footprintMB())")
        let kit = try await WhisperKit(makeConfig())
        kit.modelStateCallback = { _, state in
            log.info("Whisper model state=\(state.description, privacy: .public)")
        }
        let started = Date()
        // A line every 10 s tells a slow Core ML preparation from a real hang.
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

    /// Whisper reads the whole recording in its own 30 s windows, so every sentence keeps its
    /// context. Each word then goes to the speaker whose run covers it. Without speaker runs the
    /// text is one narrator line per segment.
    private static func write(
        url: URL,
        locale: Locale,
        runs: [SpeechRun],
        kit: WhisperKit
    ) async throws -> [TranscriptLine] {
        let begun = Date()
        log.info("Whisper whole recording begin runs=\(runs.count)")
        let results: [TranscriptionResult]
        do {
            results = try await kit.transcribe(
                audioPath: url.path,
                decodeOptions: options(for: locale, words: !runs.isEmpty)
            )
        } catch {
            log.error("Whisper transcribe failed type=\(String(describing: type(of: error)), privacy: .public) message=\(error.localizedDescription, privacy: .public) detail=\(String(describing: error), privacy: .public)")
            throw error
        }
        let segments = results.flatMap(\.segments).filter { segment in
            if isRunaway(segment.text) {
                log.warning("Whisper dropped a repeating segment start=\(segment.start)")
                return false
            }
            return true
        }
        log.info(
            "Whisper transcribed seconds=\(String(format: "%.1f", Date().timeIntervalSince(begun))) results=\(results.count) segments=\(segments.count) language=\(results.first?.language ?? "", privacy: .public) footprintMB=\(MemoryProbe.footprintMB())"
        )
        for segment in segments {
            log.info(
                "Whisper segment start=\(String(format: "%.1f", segment.start)) end=\(String(format: "%.1f", segment.end)) noSpeech=\(String(format: "%.2f", segment.noSpeechProb)) words=\(segment.words?.count ?? 0) text=\(segment.text, privacy: .public)"
            )
        }

        var lines: [TranscriptLine]
        if runs.isEmpty {
            lines = segments.compactMap { segment in
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return TranscriptLine(second: max(0, Int(segment.start)), text: text, role: .narrator)
            }
        } else {
            let words = segments.flatMap { segment -> [LectureTranscriber.TimedWord] in
                if let timed = segment.words, !timed.isEmpty {
                    return timed.map {
                        LectureTranscriber.TimedWord(start: Double($0.start), end: Double($0.end), text: $0.word)
                    }
                }
                return [LectureTranscriber.TimedWord(start: Double(segment.start), end: Double(segment.end), text: segment.text)]
            }
            lines = LectureTranscriber.speakerLines(words: words, runs: runs)
        }
        for line in lines {
            log.info(
                "Whisper line speaker=\(line.speaker) role=\(line.role.rawValue, privacy: .public) start=\(line.second) words=\(line.text.split(whereSeparator: \.isWhitespace).count) text=\(line.text, privacy: .public)"
            )
        }
        log.info("Whisper lines=\(lines.count) speakers=\(Set(lines.map(\.speaker)).count)")
        guard !lines.isEmpty else { throw TranscriptError.qualityFailed }
        return lines
    }

    /// The course language is named, so the model never has to guess it. Greedy decoding keeps
    /// the text steady. The default thresholds drop silent windows and repeating answers.
    private static func options(for locale: Locale, words: Bool) -> DecodingOptions {
        let code = locale.language.languageCode?.identifier
        return DecodingOptions(
            task: .transcribe,
            language: code,
            temperature: 0,
            temperatureFallbackCount: 3,
            usePrefillPrompt: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            wordTimestamps: words,
            suppressBlank: true
        )
    }

    /// A segment can fall into a loop ("a a a a ..."). Such text is dropped and logged.
    static func isRunaway(_ text: String) -> Bool {
        var longest = 0
        var run = 0
        var previous: Substring?
        for word in text.split(whereSeparator: \.isWhitespace) {
            run = (word == previous) ? run + 1 : 1
            previous = word
            longest = max(longest, run)
        }
        return longest >= 6
    }
}
