import AVFoundation
import Foundation
import Gemma4Swift
import MLX
import MLXLMCommon
import OSLog

/// Gemma 4 writes the words itself through its audio tower. The student picks this engine
/// in Settings once a Gemma model is installed. Nothing is downloaded from here.
enum GemmaASR {
    private static let log = Logger(subsystem: "app.bellnote", category: "gemma-asr")
    /// The audio tower takes at most 30 s of speech per request.
    private static let windowSeconds = 28
    private static let maxTokens = 400

    /// Names the course language. Without it the model sometimes answers in English.
    /// The prompt carries no example text: a short clip made the model repeat the example.
    private static func prompt(for locale: Locale) -> String {
        let code = locale.language.languageCode?.identifier ?? locale.identifier
        guard let language = Locale(identifier: "en").localizedString(forLanguageCode: code) else {
            return "Transcribe the following speech segment in its original language. Only output the transcription, with no newlines."
        }
        return "Transcribe the following speech segment in \(language) into \(language) text. Only output the transcription, with no newlines."
    }

    /// A clip of a few seconds can send the model into a loop ("a a a a ..."). Such text is dropped and logged.
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

    /// The installed Gemma model that writes the transcript. The small one wins.
    static func installedRole() -> ModelRole? {
        [ModelRole.gemmaSmall, .gemmaLarge].first {
            HubWeights.snapshot(for: ModelCatalog.repo(for: $0)).isReady
        }
    }

    static func transcribe(url: URL, locale: Locale, runs: [SpeechRun]) async throws -> [TranscriptLine] {
        guard let role = installedRole() else { throw TranscriptError.gemmaMissing }
        await LocalModelRuntime.shared.unloadAll()
        Memory.cacheLimit = 256 * 1_024 * 1_024
        let directory = HubWeights.directory(for: ModelCatalog.repo(for: role))
        log.info("Gemma ASR load role=\(role.rawValue, privacy: .public) footprintMB=\(MemoryProbe.footprintMB())")
        let container = try await Gemma4Registration.loadContainer(
            from: directory,
            multimodal: true,
            audio: true
        )
        defer { Memory.clearCache() }
        log.info("Gemma ASR loaded footprintMB=\(MemoryProbe.footprintMB())")

        if LectureTranscriber.hasTurns(runs) {
            return try await LectureTranscriber.transcribeTurns(
                url: url,
                runs: runs,
                windowSeconds: windowSeconds,
                engine: "Gemma ASR"
            ) { clip in
                try await write(clip: clip, locale: locale, container: container)
            }
        }
        return try await transcribeWhole(url: url, locale: locale, container: container)
    }

    /// No speaker turns: write the whole recording in consecutive windows.
    private static func transcribeWhole(url: URL, locale: Locale, container: ModelContainer) async throws -> [TranscriptLine] {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        guard rate > 0 else { throw TranscriptError.unreadable }
        let total = max(1, Int(Double(file.length) / rate))
        var lines: [TranscriptLine] = []
        var start = 0
        while start < total {
            let end = min(start + windowSeconds, total)
            defer { start = end }
            guard end - start >= 1 else { continue }
            let clip = try LectureTranscriber.clipAudio(url, from: start, through: end)
            defer { try? FileManager.default.removeItem(at: clip) }
            do {
                let text = try await write(clip: clip, locale: locale, container: container)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                log.info("Gemma ASR whole window from=\(start) to=\(end) words=\(text.split(whereSeparator: \.isWhitespace).count)")
                if !text.isEmpty {
                    lines.append(TranscriptLine(second: start, text: text, role: .narrator))
                }
            } catch {
                log.error("Gemma ASR whole window failed from=\(start) message=\(error.localizedDescription, privacy: .public)")
            }
        }
        guard !lines.isEmpty else { throw TranscriptError.qualityFailed }
        return lines
    }

    /// Writes one clip of at most 30 s.
    private static func write(clip: URL, locale: Locale, container: ModelContainer) async throws -> String {
        let audio = try await Gemma4AudioProcessor.processAudio(url: clip)
        guard audio.numTokens > 0 else { return "" }
        let audioTokens = audio.numTokens
        nonisolated(unsafe) let features = audio.features
        nonisolated(unsafe) let mask = audio.mask
        let messages: [[String: String]] = [["role": "user", "content": "<|audio|>\n\(prompt(for: locale))"]]
        // About 12 tokens per second is more than speech needs. It stops a loop early on short clips.
        let maxTokens = min(Self.maxTokens, Int(audio.durationSeconds * 12) + 24)

        let text: String = try await container.perform { context in
            guard let model = context.model as? Gemma4MultimodalLLMModel else {
                throw TranscriptError.gemmaNotWriting
            }
            let template = try context.tokenizer.applyChatTemplate(messages: messages)
            let audioId = Int(Gemma4Processor.audioTokenId)
            var ids: [Int] = []
            ids.reserveCapacity(template.count + audioTokens + 2)
            for id in template {
                if id == audioId {
                    ids.append(Int(Gemma4Processor.boaTokenId))
                    ids.append(contentsOf: repeatElement(audioId, count: audioTokens))
                    ids.append(Int(Gemma4Processor.eoaTokenId))
                } else {
                    ids.append(id)
                }
            }
            model.pendingAudioFeatures = features
            model.pendingAudioMask = mask

            let input = LMInput(tokens: MLXArray(ids.map { Int32($0) }))
            let parameters = GenerateParameters(maxTokens: maxTokens, temperature: 0)
            let iterator = try TokenIterator(input: input, model: context.model, cache: nil, parameters: parameters)
            let (events, _) = MLXLMCommon.generateTokenTask(
                promptTokenCount: input.text.tokens.size,
                modelConfiguration: context.configuration,
                tokenizer: context.tokenizer,
                iterator: iterator
            )
            var detokenizer = Gemma4StreamingDetokenizer(tokenizer: context.tokenizer)
            var text = ""
            for await event in events {
                if case let .token(id) = event, let piece = detokenizer.append(token: id) {
                    text += piece
                }
            }
            return text
        }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isRunaway(cleaned) {
            log.warning("Gemma ASR dropped a repeating answer seconds=\(audio.durationSeconds) tokens=\(maxTokens)")
            return ""
        }
        return cleaned
    }
}
