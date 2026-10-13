import AVFoundation
import Foundation
import OSLog
import Speech

struct TranscriptLine: Sendable, Equatable {
    var second: Int
    var text: String
    var role: SpeakerRole
    var speaker: Int = 0
}

enum TranscriptError: Error, Equatable {
    case assetMissing
    case qualityFailed
    case unreadable
    case whisperMissing
    case whisperNotWriting
}

enum LectureTranscriber {
    private static let log = Logger(subsystem: "app.bellnote", category: "speech")
    private static let windowSeconds = 10

    static func transcribe(
        url: URL,
        locale: Locale,
        runs: [SpeechRun]
    ) async throws -> [TranscriptLine] {
        let turns = appleTurns(runs)
        if turns.isEmpty {
            let spoken = try await transcribeFile(url: url, locale: locale, keeping: [])
            log.info("Apple dictation lines=\(spoken.count) speakers=0")
            return spoken
        }
        return try await transcribeTurns(
            url: url,
            runs: runs,
            windowSeconds: windowSeconds,
            engine: "Apple dictation"
        ) { clip in
            let spoken = try await transcribeFile(url: clip, locale: locale, keeping: [])
            return spoken.map(\.text).joined(separator: " ")
        }
    }

    /// True when speaker separation found at least one turn worth transcribing.
    static func hasTurns(_ runs: [SpeechRun]) -> Bool {
        !appleTurns(runs).isEmpty
    }

    /// Cuts every speaker turn into short windows, writes each window with `write`,
    /// and joins the pieces back into one line per turn. Speakers are numbered by order
    /// of appearance, only counting those who have text.
    /// Apple dictation silently drops most of a long clip (57 s returned 12 s of text),
    /// so every turn is sent in short windows.
    static func transcribeTurns(
        url: URL,
        runs: [SpeechRun],
        windowSeconds: Int,
        engine: String,
        write: (URL) async throws -> String
    ) async throws -> [TranscriptLine] {
        let turns = appleTurns(runs)
        let longest = RoleRules.longestCluster(runs) ?? 1
        log.info("\(engine, privacy: .public) turns=\(turns.count) speakers=\(Set(turns.map(\.cluster)).count)")
        var lines: [TranscriptLine] = []
        for turn in turns {
            var pieces: [String] = []
            var windowStart = turn.start
            while windowStart < turn.end {
                let windowEnd = min(windowStart + windowSeconds, turn.end)
                defer { windowStart = windowEnd }
                guard windowEnd - windowStart >= 1 else { continue }
                do {
                    let clip = try clipAudio(url, from: windowStart, through: windowEnd)
                    defer { try? FileManager.default.removeItem(at: clip) }
                    let piece = try await write(clip)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    log.info(
                        "\(engine, privacy: .public) window speaker=\(turn.cluster) from=\(windowStart) to=\(windowEnd) words=\(piece.split(whereSeparator: \.isWhitespace).count)"
                    )
                    if !piece.isEmpty { pieces.append(piece) }
                } catch {
                    log.error(
                        "\(engine, privacy: .public) window failed speaker=\(turn.cluster) from=\(windowStart) message=\(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            let text = pieces.joined(separator: " ")
            let words = text.split(whereSeparator: \.isWhitespace).count
            log.info(
                "\(engine, privacy: .public) speaker=\(turn.cluster) start=\(turn.start) seconds=\(turn.end - turn.start) words=\(words) text=\(text, privacy: .public)"
            )
            guard !text.isEmpty else { continue }
            lines.append(TranscriptLine(
                second: turn.start,
                text: text,
                role: appleRole(turn, longestCluster: longest),
                speaker: turn.cluster
            ))
        }
        guard !lines.isEmpty else { throw TranscriptError.qualityFailed }
        let numbered = renumbered(lines)
        log.info("\(engine, privacy: .public) lines=\(numbered.count) speakers=\(Set(numbered.map(\.speaker)).count)")
        return numbered
    }

    /// Numbers speakers by order of appearance, only counting those who have text.
    static func renumbered(_ lines: [TranscriptLine]) -> [TranscriptLine] {
        var numbers: [Int: Int] = [:]
        return lines.map { line in
            let number = numbers[line.speaker] ?? numbers.count + 1
            numbers[line.speaker] = number
            return TranscriptLine(second: line.second, text: line.text, role: line.role, speaker: number)
        }
    }

    /// One recognised word with its time in the recording.
    struct TimedWord: Sendable, Equatable {
        var start: Double
        var end: Double
        var text: String
    }

    /// Gives every word to the speaker whose run covers it most, then joins neighbouring words of
    /// one speaker into a line. The engine reads the whole recording, so it keeps its context,
    /// and a short turn of another speaker is not lost. A word outside every run, farther than a
    /// second, stays with the speaker before it.
    static func speakerLines(words: [TimedWord], runs: [SpeechRun]) -> [TranscriptLine] {
        let spans = mergeRuns(runs, minimum: 0)
        guard let first = spans.first else { return [] }
        let longest = RoleRules.longestCluster(runs) ?? first.cluster
        var lines: [TranscriptLine] = []
        var cluster = first.cluster
        var span: SpeechRun = first
        var pieces: [String] = []
        var lineStart = 0

        func flush() {
            let text = pieces.joined(separator: " ")
            pieces.removeAll()
            guard !text.isEmpty else { return }
            let role = cluster == longest ? SpeakerRole.narrator : appleRole(span, longestCluster: longest)
            lines.append(TranscriptLine(second: lineStart, text: text, role: role, speaker: cluster))
        }

        for word in words {
            let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let found = bestSpan(for: word, in: spans)
            let next = found?.cluster ?? cluster
            if next != cluster, !pieces.isEmpty { flush() }
            if pieces.isEmpty { lineStart = max(0, Int(word.start)) }
            cluster = next
            if let found { span = found }
            pieces.append(text)
        }
        flush()
        return renumbered(lines)
    }

    private static func bestSpan(for word: TimedWord, in spans: [SpeechRun]) -> SpeechRun? {
        var best: SpeechRun?
        var bestOverlap = 0.0
        for span in spans {
            let overlap = min(word.end, Double(span.end)) - max(word.start, Double(span.start))
            // On a tie the run that began later wins: it is the one that just started speaking.
            if overlap > bestOverlap || (overlap == bestOverlap && overlap > 0 && span.start > (best?.start ?? -1)) {
                best = span
                bestOverlap = overlap
            }
        }
        if best != nil { return best }
        let middle = (word.start + word.end) / 2
        var nearest: SpeechRun?
        var nearestGap = 1.0
        for span in spans {
            let gap = max(Double(span.start) - middle, middle - Double(span.end), 0)
            if gap <= nearestGap {
                nearest = span
                nearestGap = gap
            }
        }
        return nearest
    }

    static func speakerTurns(_ runs: [SpeechRun]) -> [SpeechRun] {
        let longest = RoleRules.longestCluster(runs) ?? 1
        let kept = runs
            .filter { RoleRules.label($0, longestCluster: longest) != .room }
            .sorted { $0.start < $1.start }
        var merged: [SpeechRun] = []
        for run in kept {
            if var last = merged.last, last.cluster == run.cluster, run.start <= last.end + 1 {
                last.end = max(last.end, run.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(run)
            }
        }
        return merged
    }

    /// Apple dictation only. Qwen keeps `speakerTurns` unchanged.
    /// Every speaker keeps their own turns. `speakerTurns` drops short or overlapping runs
    /// of non-lecturers as room noise, which erased the other people here.
    private static func appleTurns(_ runs: [SpeechRun]) -> [SpeechRun] {
        mergeRuns(runs, minimum: 2)
    }

    /// Keeps runs of at least `minimum` seconds and joins neighbours of one speaker.
    private static func mergeRuns(_ runs: [SpeechRun], minimum: Int) -> [SpeechRun] {
        let kept = runs
            .filter { $0.duration >= minimum }
            .sorted { $0.start < $1.start }
        var merged: [SpeechRun] = []
        for run in kept {
            if var last = merged.last, last.cluster == run.cluster, run.start <= last.end + 1 {
                last.end = max(last.end, run.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(run)
            }
        }
        return merged
    }

    /// `.room` blocks are discarded later in the pipeline, so Apple turns never carry it.
    private static func appleRole(_ turn: SpeechRun, longestCluster: Int) -> SpeakerRole {
        let role = RoleRules.label(turn, longestCluster: longestCluster)
        return role == .room ? .unknown : role
    }

    private static func transcribeFile(
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
            } else {
                log.info("Speech transcriber unavailable locale=\(candidate.identifier, privacy: .public)")
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
                    if isUnsupportedConfiguration(error) || error as? TranscriptError == .qualityFailed { break }
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
                let seconds = lastSample.seconds
                log.info("Finalize through seconds=\(seconds)")
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                log.info("Finalize through end of input")
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
            "Transcript collected lines=\(lines.count) kept=\(selected.count) words=\(words) audioSeconds=\(audioSeconds) head=\(String(joined.prefix(80)), privacy: .public) tail=\(String(joined.suffix(80)), privacy: .public)"
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

    static func clipAudio(_ url: URL, from start: Int, through end: Int) throws -> URL {
        let source = try AVAudioFile(forReading: url)
        let format = source.processingFormat
        guard format.sampleRate > 0 else { throw TranscriptError.unreadable }
        let startFrame = min(source.length, AVAudioFramePosition(Double(max(0, start)) * format.sampleRate))
        let endFrame = min(source.length, AVAudioFramePosition(Double(max(start + 1, end)) * format.sampleRate))
        guard endFrame > startFrame else { throw TranscriptError.unreadable }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("bellnote-turn-\(UUID().uuidString).caf")
        let output = try AVAudioFile(
            forWriting: destination,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        source.framePosition = startFrame
        let capacity: AVAudioFrameCount = 8_192
        do {
            while source.framePosition < endFrame {
                let frames = AVAudioFrameCount(min(AVAudioFramePosition(capacity), endFrame - source.framePosition))
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
                    throw TranscriptError.unreadable
                }
                try source.read(into: buffer, frameCount: frames)
                if buffer.frameLength == 0 { break }
                try output.write(from: buffer)
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return destination
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
        var index = 0
        for try await result in results {
            index += 1
            let value = text(result).trimmingCharacters(in: .whitespacesAndNewlines)
            let start = result.range.start.seconds
            let duration = result.range.duration.seconds
            log.info(
                "Transcript result index=\(index) final=\(result.isFinal) start=\(start) duration=\(duration) characters=\(value.count) head=\(String(value.prefix(60)), privacy: .public) tail=\(String(value.suffix(60)), privacy: .public)"
            )
            guard !value.isEmpty else { continue }
            let second = max(0, Int(start.isFinite ? start.rounded(.down) : 0))
            if result.isFinal {
                finals.append(TranscriptLine(second: second, text: value, role: .narrator))
                volatileBySecond.removeValue(forKey: second)
            } else {
                volatileBySecond[second] = value
            }
        }
        log.info(
            "Transcript results count=\(index) finals=\(finals.count) volatile=\(volatileBySecond.count) kept=\(finals.isEmpty ? "volatile" : "final", privacy: .public)"
        )
        if !finals.isEmpty { return finals }
        return volatileBySecond.keys.sorted().compactMap { second in
            guard let value = volatileBySecond[second] else { return nil }
            return TranscriptLine(second: second, text: value, role: .narrator)
        }
    }

    private static func isUnsupportedConfiguration(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == SFSpeechErrorDomain && (nsError.code == 4 || nsError.code == 15)
    }

    private static func logAttemptFailure(_ kind: String, locale: Locale, error: Error) {
        let nsError = error as NSError
        log.error(
            "\(kind, privacy: .public) attempt failed locale=\(locale.identifier, privacy: .public) domain=\(nsError.domain, privacy: .public) code=\(nsError.code) message=\(error.localizedDescription, privacy: .public)"
        )
    }
}
