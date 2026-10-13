import AVFoundation
import Foundation
import OSLog
import Speech

struct TranscriptLine: Sendable, Equatable {
    var second: Int
    var text: String
    var role: SpeakerRole
}

enum TranscriptError: Error, Equatable {
    case assetMissing
    case qualityFailed
    case unreadable
}

enum LectureTranscriber {
    private static let log = Logger(subsystem: "app.bellnote", category: "speech")

    static func transcribe(
        url: URL,
        locale: Locale,
        keeping ranges: [ClosedRange<Int>]
    ) async throws -> [TranscriptLine] {
        let candidates = await localeCandidates(for: locale)
        log.info(
            "Locale requested=\(locale.identifier, privacy: .public) candidates=\(candidates.map(\.identifier).joined(separator: ","), privacy: .public)"
        )

        var lastError: Error?
        for candidate in candidates {
            if SpeechTranscriber.isAvailable {
                for preset in speechPresets {
                    do {
                        let lines = try await runSpeech(
                            url: url,
                            locale: candidate,
                            preset: preset,
                            keeping: ranges
                        )
                        log.info(
                            "Transcript ok speech locale=\(candidate.identifier, privacy: .public) preset=\(String(describing: preset), privacy: .public) lines=\(lines.count)"
                        )
                        return lines
                    } catch {
                        lastError = error
                        logAttemptFailure("Speech", locale: candidate, error: error)
                        if isUnsupportedConfiguration(error) { break }
                        if let transcriptError = error as? TranscriptError, transcriptError == .unreadable {
                            throw error
                        }
                    }
                }
            }

            for preset in dictationPresets {
                do {
                    let lines = try await runDictation(
                        url: url,
                        locale: candidate,
                        preset: preset,
                        keeping: ranges
                    )
                    log.info(
                        "Transcript ok dictation locale=\(candidate.identifier, privacy: .public) preset=\(String(describing: preset), privacy: .public) lines=\(lines.count)"
                    )
                    return lines
                } catch {
                    lastError = error
                    logAttemptFailure("Dictation", locale: candidate, error: error)
                    if isUnsupportedConfiguration(error) { break }
                    if let transcriptError = error as? TranscriptError, transcriptError == .unreadable {
                        throw error
                    }
                }
            }
        }

        if let lastError { throw lastError }
        throw TranscriptError.assetMissing
    }

    private static var speechPresets: [SpeechTranscriber.Preset] {
        [
            .timeIndexedTranscriptionWithAlternatives,
            .timeIndexedProgressiveTranscription,
            .transcriptionWithAlternatives,
            .transcription,
        ]
    }

    private static var dictationPresets: [DictationTranscriber.Preset] {
        [
            .timeIndexedLongDictation,
            .longDictation,
            .progressiveLongDictation,
        ]
    }

    private static func localeCandidates(for preferred: Locale) async -> [Locale] {
        var ordered: [Locale] = []
        func append(_ locale: Locale?) {
            guard let locale else { return }
            if ordered.contains(where: { $0.identifier == locale.identifier }) { return }
            ordered.append(locale)
        }

        append(await DictationTranscriber.supportedLocale(equivalentTo: preferred))
        append(await SpeechTranscriber.supportedLocale(equivalentTo: preferred))
        append(preferred)
        if let language = preferred.language.languageCode?.identifier {
            append(Locale(identifier: language))
            for installed in await DictationTranscriber.installedLocales
                where installed.language.languageCode?.identifier == language
            {
                append(installed)
            }
            for installed in await SpeechTranscriber.installedLocales
                where installed.language.languageCode?.identifier == language
            {
                append(installed)
            }
        }

        let dictationSupported = await DictationTranscriber.supportedLocales
        let dictationInstalled = await DictationTranscriber.installedLocales
        let speechInstalled = await SpeechTranscriber.installedLocales
        log.info(
            "Dictation supported count=\(dictationSupported.count) installed=\(dictationInstalled.count) speechInstalled=\(speechInstalled.count)"
        )
        return ordered
    }

    private static func runSpeech(
        url: URL,
        locale: Locale,
        preset: SpeechTranscriber.Preset,
        keeping ranges: [ClosedRange<Int>]
    ) async throws -> [TranscriptLine] {
        let transcriber = SpeechTranscriber(locale: locale, preset: preset)
        try await ensureAssets(for: [transcriber], locale: locale)
        return try await analyze(
            url: url,
            locale: locale,
            module: transcriber,
            keeping: ranges
        ) {
            try await collectResults(transcriber.results) { String($0.text.characters) }
        }
    }

    private static func runDictation(
        url: URL,
        locale: Locale,
        preset: DictationTranscriber.Preset,
        keeping ranges: [ClosedRange<Int>]
    ) async throws -> [TranscriptLine] {
        let resolved = await DictationTranscriber.supportedLocale(equivalentTo: locale) ?? locale
        log.info(
            "Dictation locale requested=\(locale.identifier, privacy: .public) resolved=\(resolved.identifier, privacy: .public) preset=\(String(describing: preset), privacy: .public)"
        )
        let transcriber = DictationTranscriber(locale: resolved, preset: preset)
        try await ensureAssets(for: [transcriber], locale: resolved)
        return try await analyze(
            url: url,
            locale: resolved,
            module: transcriber,
            keeping: ranges
        ) {
            try await collectResults(transcriber.results) { String($0.text.characters) }
        }
    }

    private static func ensureAssets(for modules: [any SpeechModule], locale: Locale) async throws {
        _ = try await AssetInventory.reserve(locale: locale)
        do {
            let status = await AssetInventory.status(forModules: modules)
            log.info("Asset status=\(String(describing: status), privacy: .public) locale=\(locale.identifier, privacy: .public)")
            switch status {
            case .unsupported:
                log.error("Module unsupported for locale=\(locale.identifier, privacy: .public)")
                throw NSError(
                    domain: SFSpeechErrorDomain,
                    code: 4,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Some modules are configured with an unsupported configuration."
                    ]
                )
            case .installed:
                break
            case .supported, .downloading:
                if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                    log.info("Downloading speech asset locale=\(locale.identifier, privacy: .public)")
                    try await request.downloadAndInstall()
                    let after = await AssetInventory.status(forModules: modules)
                    log.info(
                        "Speech asset install finished locale=\(locale.identifier, privacy: .public) status=\(String(describing: after), privacy: .public)"
                    )
                } else {
                    // Apple: nil means nothing more to install for this configuration.
                    log.info(
                        "Speech asset install not required locale=\(locale.identifier, privacy: .public) status=\(String(describing: status), privacy: .public)"
                    )
                }
            @unknown default:
                break
            }
        } catch {
            _ = await AssetInventory.release(reservedLocale: locale)
            throw error
        }
    }

    private static func analyze(
        url: URL,
        locale: Locale,
        module: any SpeechModule,
        keeping ranges: [ClosedRange<Int>],
        collect: @escaping @Sendable () async throws -> [TranscriptLine]
    ) async throws -> [TranscriptLine] {
        defer {
            Task { _ = await AssetInventory.release(reservedLocale: locale) }
        }
        let source = try AVAudioFile(forReading: url)
        let sourceFormat = source.processingFormat
        let audioSeconds = max(Int((Double(source.length) / max(sourceFormat.sampleRate, 1)).rounded(.down)), 1)
        log.info(
            "Source audio format=\(formatSummary(sourceFormat), privacy: .public) frames=\(source.length) seconds=\(audioSeconds)"
        )

        let moduleFormats = await module.availableCompatibleAudioFormats
        let preferred = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [module],
            considering: sourceFormat
        )
        var compatible = moduleFormats
        if let preferred {
            compatible.insert(preferred, at: 0)
            log.info("Preferred format=\(formatSummary(preferred), privacy: .public)")
        }
        log.info("Compatible formats count=\(compatible.count)")

        let analysisURL = try preparedAudio(from: source, url: url, compatible: compatible)
        defer {
            if analysisURL != url {
                try? FileManager.default.removeItem(at: analysisURL)
            }
        }
        let analysisFile = try AVAudioFile(forReading: analysisURL)
        log.info(
            "Analysis audio format=\(formatSummary(analysisFile.processingFormat), privacy: .public) frames=\(analysisFile.length)"
        )

        let analyzer = SpeechAnalyzer(modules: [module])
        let collector = Task { try await collect() }
        do {
            let lastSample = try await feed(analyzer, file: analysisFile, modules: [module])
            if let lastSample {
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            }
        } catch {
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
        let lines = try await collector.value
        let rangeText = ranges.map { "\($0.lowerBound)...\($0.upperBound)" }.joined(separator: ",")
        let lineText = lines.map { "\($0.second):\($0.text)" }.joined(separator: " | ")
        log.info(
            "Transcript raw lines=\(lines.count) ranges=\(rangeText, privacy: .public) body=\(String(lineText.prefix(180)), privacy: .public)"
        )
        let kept = lines.filter { line in
            ranges.isEmpty || ranges.contains { range in
                let padded = (range.lowerBound - 2)...(range.upperBound + 2)
                return padded.contains(line.second)
            }
        }
        let selected = kept.isEmpty ? lines : kept
        let joined = selected.map(\.text).joined(separator: " ")
        let words = joined.split(whereSeparator: \.isWhitespace).count
        log.info(
            "Transcript collected lines=\(lines.count) kept=\(selected.count) words=\(words) preview=\(String(joined.prefix(120)), privacy: .public)"
        )
        guard !selected.isEmpty else {
            throw TranscriptError.qualityFailed
        }
        let speechSeconds = ranges.isEmpty
            ? audioSeconds
            : max(ranges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }, 1)
        guard QualityGate.passes(text: joined, expectedSeconds: speechSeconds) else {
            log.error("Quality gate failed words=\(words) speechSeconds=\(speechSeconds)")
            throw TranscriptError.qualityFailed
        }
        return selected
    }

    private static func feed(
        _ analyzer: SpeechAnalyzer,
        file: AVAudioFile,
        modules: [any SpeechModule]
    ) async throws -> CMTime? {
        let converter = try await AnalyzerInputConverter.converter(compatibleWith: modules)
        let format = file.processingFormat
        let capacity: AVAudioFrameCount = 16_000
        var inputs: [AnalyzerInput] = []
        var sampleTime: AVAudioFramePosition = 0
        file.framePosition = 0
        while file.framePosition < file.length {
            let frames = AVAudioFrameCount(min(AVAudioFramePosition(capacity), file.length - file.framePosition))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
                throw TranscriptError.unreadable
            }
            try file.read(into: buffer, frameCount: frames)
            if buffer.frameLength == 0 { break }
            let time = AVAudioTime(sampleTime: sampleTime, atRate: format.sampleRate)
            inputs.append(contentsOf: try converter.convert(buffer, at: time))
            sampleTime += AVAudioFramePosition(buffer.frameLength)
        }
        inputs.append(contentsOf: try converter.flush())
        log.info("Analyzer inputs=\(inputs.count)")
        return try await analyzer.analyzeSequence(InputList(inputs: inputs))
    }

    private struct InputList: AsyncSequence, Sendable {
        typealias Element = AnalyzerInput
        let inputs: [AnalyzerInput]

        struct Iterator: AsyncIteratorProtocol {
            var inputs: [AnalyzerInput]
            var index = 0
            mutating func next() async -> AnalyzerInput? {
                guard index < inputs.count else { return nil }
                defer { index += 1 }
                return inputs[index]
            }
        }

        func makeAsyncIterator() -> Iterator {
            Iterator(inputs: inputs)
        }
    }

    private static func preparedAudio(
        from source: AVAudioFile,
        url: URL,
        compatible: [AVAudioFormat]
    ) throws -> URL {
        if compatible.isEmpty {
            log.info("No compatible format list; using source audio")
            return url
        }
        let sourceFormat = source.processingFormat
        log.info(
            "Compatible formats=\(compatible.map { formatSummary($0) }.joined(separator: " | "), privacy: .public)"
        )
        if compatible.contains(where: { formatsMatch($0, sourceFormat) }) {
            return url
        }
        guard let target = bestCompatibleFormat(in: compatible, matching: sourceFormat) else {
            return url
        }
        log.info(
            "Converting audio from=\(formatSummary(sourceFormat), privacy: .public) to=\(formatSummary(target), privacy: .public)"
        )
        do {
            return try convertAudio(from: source, url: url, to: target)
        } catch {
            log.error(
                "Audio convert failed message=\(error.localizedDescription, privacy: .public); using source"
            )
            return url
        }
    }

    private static func bestCompatibleFormat(
        in compatible: [AVAudioFormat],
        matching source: AVAudioFormat
    ) -> AVAudioFormat? {
        let monoOrAny = compatible.filter { $0.channelCount >= 1 }
        let pool = monoOrAny.isEmpty ? compatible : monoOrAny
        return pool.max { lhs, rhs in
            formatScore(lhs, matching: source) < formatScore(rhs, matching: source)
        }
    }

    private static func formatScore(_ format: AVAudioFormat, matching source: AVAudioFormat) -> Double {
        var score = 0.0
        let rateDelta = abs(format.sampleRate - source.sampleRate)
        score += max(0, 100_000 - rateDelta)
        if abs(format.sampleRate - 16_000) < 0.5 { score += 50_000 }
        if format.sampleRate >= source.sampleRate { score += 10_000 }
        if format.commonFormat == source.commonFormat { score += 5_000 }
        if format.channelCount == source.channelCount { score += 1_000 }
        score += format.sampleRate
        return score
    }

    private static func convertAudio(from source: AVAudioFile, url: URL, to target: AVAudioFormat) throws -> URL {
        let converted = FileManager.default.temporaryDirectory
            .appendingPathComponent("bellnote-speech-\(UUID().uuidString).caf")
        let output = try AVAudioFile(
            forWriting: converted,
            settings: target.settings,
            commonFormat: target.commonFormat,
            interleaved: target.isInterleaved
        )
        let writeFormat = output.processingFormat
        log.info("Write format=\(formatSummary(writeFormat), privacy: .public)")
        guard let converter = AVAudioConverter(from: source.processingFormat, to: writeFormat) else {
            throw TranscriptError.unreadable
        }
        source.framePosition = 0
        let inputCapacity: AVAudioFrameCount = 4096
        while source.framePosition < source.length {
            let remaining = AVAudioFrameCount(source.length - source.framePosition)
            let frameCount = min(remaining, inputCapacity)
            guard
                let inputBuffer = AVAudioPCMBuffer(
                    pcmFormat: source.processingFormat,
                    frameCapacity: frameCount
                )
            else {
                throw TranscriptError.unreadable
            }
            try source.read(into: inputBuffer, frameCount: frameCount)
            if inputBuffer.frameLength == 0 { break }

            let ratio = max(writeFormat.sampleRate / source.processingFormat.sampleRate, 0.01)
            let capacity = max(AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 64, 1)
            guard
                let outputBuffer = AVAudioPCMBuffer(
                    pcmFormat: writeFormat,
                    frameCapacity: capacity
                )
            else {
                throw TranscriptError.unreadable
            }

            var error: NSError?
            var consumed = false
            let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return inputBuffer
            }
            if let error { throw error }
            if status == .error { throw TranscriptError.unreadable }
            if outputBuffer.frameLength > 0 {
                try output.write(from: outputBuffer)
            }
        }
        return converted
    }

    private static func formatsMatch(_ left: AVAudioFormat, _ right: AVAudioFormat) -> Bool {
        left.commonFormat == right.commonFormat
            && abs(left.sampleRate - right.sampleRate) < 0.5
            && left.channelCount == right.channelCount
            && left.isInterleaved == right.isInterleaved
    }

    private static func formatSummary(_ format: AVAudioFormat) -> String {
        "\(format.channelCount)ch \(Int(format.sampleRate))Hz \(format.commonFormat.rawValue)"
    }

    private static func collectResults<S: AsyncSequence>(
        _ results: S,
        text: (S.Element) -> String
    ) async throws -> [TranscriptLine] where S.Element: SpeechModuleResult {
        var finals: [TranscriptLine] = []
        var volatileBySecond: [Int: String] = [:]
        for try await result in results {
            let value = text(result).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            let second = max(0, Int(result.range.start.seconds.rounded(.down)))
            if result.isFinal {
                finals.append(TranscriptLine(second: second, text: value, role: .narrator))
                volatileBySecond.removeValue(forKey: second)
            } else {
                volatileBySecond[second] = value
            }
        }
        if !finals.isEmpty { return finals }
        return volatileBySecond.keys.sorted().compactMap { second in
            guard let value = volatileBySecond[second] else { return nil }
            return TranscriptLine(second: second, text: value, role: .narrator)
        }
    }

    private static func isUnsupportedConfiguration(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == SFSpeechErrorDomain && nsError.code == 4
    }

    private static func logAttemptFailure(_ kind: String, locale: Locale, error: Error) {
        let nsError = error as NSError
        log.error(
            "\(kind, privacy: .public) attempt failed locale=\(locale.identifier, privacy: .public) domain=\(nsError.domain, privacy: .public) code=\(nsError.code) message=\(error.localizedDescription, privacy: .public)"
        )
    }
}
