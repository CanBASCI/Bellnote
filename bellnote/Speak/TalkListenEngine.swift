import AVFoundation
import Foundation
import OSLog
@preconcurrency import Speech

/// Live microphone → `SpeechAnalyzer` with a progressive transcriber and a speech detector.
/// Ends a user turn after short silence once some words were heard.
@MainActor
final class TalkListenEngine {
    // Logger is thread-safe; the audio tap is @Sendable and must not touch MainActor state.
    nonisolated private static let log = Logger(subsystem: "app.bellnote", category: "talk")
    /// How long after the last transcript update (or speech) before the turn ends.
    /// ~2s so a normal mid-sentence breath does not cut the turn; still ends when the student is done.
    private static let silenceNanoseconds: UInt64 = 2_000_000_000
    private static let silenceSeconds: TimeInterval = 2.0

    private let engine = AVAudioEngine()
    /// Same graph as the mic so Voice Processing can cancel the loudspeaker.
    private let player = AVAudioPlayerNode()
    private var playerReady = false
    private(set) var isPlaybackActive = false
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzer: SpeechAnalyzer?
    private var inputConverter: AnalyzerInputConverter?
    private var feedTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?
    private var detectTask: Task<Void, Never>?
    private var silenceTask: Task<Void, Never>?
    private var reservedLocale: Locale?
    private var turnContinuation: CheckedContinuation<String, Error>?
    private var committed = ""
    private var volatile = ""
    private var heardSpeech = false
    private var lastActivity = Date.distantPast
    private var bargeInHandler: (() -> Void)?
    private var bargeInArmed = false
    /// Mic energy barge — SpeechDetector often misses the user over the loudspeaker.
    private let bargeMeter = BargeMeter()
    /// Folded TTS text so loudspeaker echo is not treated as the student’s words.
    private var bargeEchoSource = ""

    var partialText: String {
        let joined = [committed, volatile].filter { !$0.isEmpty }.joined(separator: " ")
        return joined.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Arms barge-in after TTS has been speaking a moment (avoids echo of the reply).
    func armBargeIn(after delay: Duration = .milliseconds(350), onBargeIn: @escaping () -> Void) {
        bargeInHandler = onBargeIn
        bargeInArmed = false
        bargeMeter.reset()
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard self.bargeInHandler != nil else { return }
            self.bargeInArmed = true
            self.bargeMeter.arm()
            Self.log.info("Talk barge-in armed")
        }
    }

    func disarmBargeIn() {
        bargeInHandler = nil
        bargeInArmed = false
        bargeMeter.disarm()
    }

    private func applyVoiceProcessing(_ enabled: Bool) {
        let input = engine.inputNode
        guard input.isVoiceProcessingEnabled != enabled else { return }
        do {
            try input.setVoiceProcessingEnabled(enabled)
            if enabled {
                Self.log.info("Talk voice processing on")
            } else {
                Self.log.info("Talk voice processing off")
            }
        } catch {
            Self.log.info(
                "Talk voice processing change failed \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func fireBargeIn(reason: String) {
        guard bargeInArmed, let handler = bargeInHandler else { return }
        bargeInArmed = false
        bargeInHandler = nil
        bargeMeter.disarm()
        Self.log.info("Talk barge-in fire reason=\(reason, privacy: .public)")
        handler()
    }

    /// Starts the mic and analyzer, then waits until silence ends the user turn.
    /// `seed` keeps words already heard during barge-in so the student does not have to repeat.
    func listenTurn(locale: Locale, seed: String = "") async throws -> String {
        stopListening(cancelTurn: false)
        let prefix = seed.trimmingCharacters(in: .whitespacesAndNewlines)
        committed = prefix
        volatile = ""
        heardSpeech = !prefix.isEmpty
        lastActivity = Date()
        if !prefix.isEmpty {
            Self.log.info("Talk listen seed characters=\(prefix.count) head=\(String(prefix.prefix(60)), privacy: .public)")
        }
        try await Self.activateTalkSession()
        // Live talk uses Dictation (same family as the lecture transcript). Bare "tr" is not reservable;
        // resolve to an installed/supported locale such as tr_TR.
        let resolved = try await Self.resolveDictationLocale(locale)
        let transcriber = Self.makeDictationTranscriber(locale: resolved)
        let detector = SpeechDetector(
            detectionOptions: SpeechDetector.DetectionOptions(sensitivityLevel: .medium),
            reportResults: true
        )
        try await ensureAssets(for: [transcriber, detector], locale: resolved)
        reservedLocale = resolved

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(32))
        inputContinuation = continuation

        let modules: [any SpeechModule] = [transcriber, detector]
        let converter = try await AnalyzerInputConverter.converter(compatibleWith: modules)
        inputConverter = converter
        let analyzer = SpeechAnalyzer(modules: modules)
        self.analyzer = analyzer
        try await analyzer.prepareToAnalyze(in: nil)

        let input = engine.inputNode
        input.removeTap(onBus: 0)
        // Listening has no loudspeaker playback — keep Voice Processing off.
        applyVoiceProcessing(false)
        let format = input.outputFormat(forBus: 0)
        // AnalyzerInputConverter is not Sendable; the tap runs on the audio thread for one listen turn.
        nonisolated(unsafe) let tapConverter = converter
        try input.installAudioTap(onBus: 0, bufferSize: 2_048, format: format) { buffer, time in
            do {
                // iOS 27 tap yields a read-only buffer; the Speech converter still wants a mutable PCM buffer.
                let pcm = AVAudioPCMBuffer(copying: buffer)
                for item in try tapConverter.convert(pcm, at: time) {
                    continuation.yield(item)
                }
            } catch {
                Self.log.error("Talk convert failed \(error.localizedDescription, privacy: .public)")
            }
        }
        engine.prepare()
        try engine.start()
        Self.log.info("Talk mic started locale=\(resolved.identifier, privacy: .public)")

        feedTask = Task {
            do {
                _ = try await analyzer.analyzeSequence(stream)
            } catch is CancellationError {
                // Expected when the turn stops.
            } catch {
                Self.log.error("Talk analyzer feed failed \(error.localizedDescription, privacy: .public)")
            }
        }

        resultTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in transcriber.results {
                    await self.handleTranscript(
                        text: String(result.text.characters),
                        isFinal: result.isFinal
                    )
                }
            } catch is CancellationError {
            } catch {
                Self.log.error("Talk transcript failed \(error.localizedDescription, privacy: .public)")
                await self.failTurn(error)
            }
        }

        detectTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in detector.results {
                    await self.handleDetection(result)
                }
            } catch is CancellationError {
            } catch {
                Self.log.error("Talk detector failed \(error.localizedDescription, privacy: .public)")
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            turnContinuation = continuation
            bumpSilenceWatch()
        }
    }

    /// Mic + detector while Supertonic speaks. Speech requires a transcriber beside the detector.
    /// `echoOf` is the reply being spoken — ASR hits that match its start are ignored (speaker bleed).
    func startBargeMonitor(locale: Locale, echoOf spoken: String) async throws {
        stopListening(cancelTurn: false)
        heardSpeech = false
        committed = ""
        volatile = ""
        bargeEchoSource = Self.asciiFold(spoken)
        try await Self.activateTalkSession()
        let resolved = try await Self.resolveDictationLocale(locale)
        let transcriber = Self.makeDictationTranscriber(locale: resolved)
        // High sensitivity so user speech over the loudspeaker still trips barge-in.
        let detector = SpeechDetector(
            detectionOptions: SpeechDetector.DetectionOptions(sensitivityLevel: .high),
            reportResults: true
        )
        try await ensureAssets(for: [transcriber, detector], locale: resolved)
        reservedLocale = resolved

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(24))
        inputContinuation = continuation
        let modules: [any SpeechModule] = [transcriber, detector]
        let converter = try await AnalyzerInputConverter.converter(compatibleWith: modules)
        inputConverter = converter
        let analyzer = SpeechAnalyzer(modules: modules)
        self.analyzer = analyzer
        try await analyzer.prepareToAnalyze(in: nil)

        let input = engine.inputNode
        input.removeTap(onBus: 0)
        // One engine: attach the speaker first, then enable Voice Processing, then the mic tap.
        // VP needs the playback node in the graph so it can subtract the reply from the mic.
        do {
            try ensurePlayer()
        } catch {
            Self.log.error("Talk player attach failed \(error.localizedDescription, privacy: .public)")
        }
        applyVoiceProcessing(true)
        let format = input.outputFormat(forBus: 0)
        nonisolated(unsafe) let tapConverter = converter
        let meter = bargeMeter
        try input.installAudioTap(onBus: 0, bufferSize: 2_048, format: format) { buffer, time in
            let pcm = AVAudioPCMBuffer(copying: buffer)
            meter.note(rms: Self.bufferRMS(pcm))
            do {
                for item in try tapConverter.convert(pcm, at: time) {
                    continuation.yield(item)
                }
            } catch {
                Self.log.error("Talk barge convert failed \(error.localizedDescription, privacy: .public)")
            }
        }
        bargeMeter.onTrip = { [weak self] in
            Task { @MainActor in
                self?.fireBargeIn(reason: "micEnergy")
            }
        }
        engine.prepare()
        try engine.start()

        feedTask = Task {
            do {
                _ = try await analyzer.analyzeSequence(stream)
            } catch is CancellationError {
            } catch {
                Self.log.error("Talk barge feed failed \(error.localizedDescription, privacy: .public)")
            }
        }
        // Detector OR transcript can interrupt — speaker echo alone often misses speechDetected.
        resultTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    await self.handleBargeTranscript(text)
                }
            } catch is CancellationError {
            } catch {
                Self.log.error("Talk barge transcript failed \(error.localizedDescription, privacy: .public)")
            }
        }
        detectTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in detector.results {
                    await self.handleDetection(result)
                }
            } catch is CancellationError {
            } catch {
                Self.log.error("Talk barge detector failed \(error.localizedDescription, privacy: .public)")
            }
        }
        Self.log.info("Talk barge monitor started voiceProcessing=\(self.engine.inputNode.isVoiceProcessingEnabled)")
    }

    /// Plays a Supertonic clip on this engine (the barge mic must already be running).
    func play(_ clip: SupertonicClip) {
        guard !clip.samples.isEmpty else { return }
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(clip.sampleRate),
            channels: 1,
            interleaved: false
        )
        guard let format,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(clip.samples.count))
        else {
            Self.log.error("Talk play buffer failed")
            return
        }
        buffer.frameLength = buffer.frameCapacity
        clip.samples.withUnsafeBufferPointer { source in
            guard let address = source.baseAddress, let channel = buffer.floatChannelData else { return }
            channel[0].update(from: address, count: source.count)
        }
        guard engine.isRunning else {
            Self.log.error("Talk play skipped engine stopped")
            return
        }
        isPlaybackActive = true
        player.stop()
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                self?.isPlaybackActive = false
                Self.log.info("Talk play finished")
            }
        }
        do {
            try player.playAudio()
            Self.log.info("Talk play started seconds=\(Double(clip.samples.count) / Double(max(clip.sampleRate, 1)))")
        } catch {
            isPlaybackActive = false
            Self.log.error("Talk play failed \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Stops the speaker only. The mic tap stays up so barge-in can finish the turn.
    func stopPlayback() {
        player.stop()
        isPlaybackActive = false
    }

    /// Attaches the speaker while the engine is stopped, before Voice Processing is enabled.
    private func ensurePlayer() throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100,
            channels: 1,
            interleaved: false
        )
        guard let format else { return }
        if !playerReady {
            engine.attach(player)
            try engine.connectNode(player, to: engine.mainMixerNode, format: format)
            playerReady = true
            Self.log.info("Talk player attached")
        }
        engine.mainMixerNode.outputVolume = 1
        player.volume = 1
    }

    /// After barge-in stopped TTS, keep the same mic session until silence ends the user turn.
    /// Avoids tearing down ASR mid-sentence (which left `carried=0` and an empty You card).
    func finishBargeListenTurn() async throws -> String {
        disarmBargeIn()
        bargeMeter.disarm()
        // Drop loudspeaker leftovers ("Deneme" from the reply) before collecting the real question.
        if isBargeEcho(partialText) {
            Self.log.info("Talk barge drop echo characters=\(self.partialText.count)")
            committed = ""
            volatile = ""
            heardSpeech = false
        }
        if !partialText.isEmpty { heardSpeech = true }
        lastActivity = Date()
        Self.log.info(
            "Talk barge finish-listen characters=\(self.partialText.count) head=\(String(self.partialText.prefix(60)), privacy: .public)"
        )
        return try await withCheckedThrowingContinuation { continuation in
            turnContinuation = continuation
            bumpSilenceWatch()
        }
    }

    func stopListening(cancelTurn: Bool = true) {
        silenceTask?.cancel()
        silenceTask = nil
        resultTask?.cancel()
        resultTask = nil
        detectTask?.cancel()
        detectTask = nil
        feedTask?.cancel()
        feedTask = nil
        inputContinuation?.finish()
        inputContinuation = nil
        tearDownMicTap()
        inputConverter = nil
        let finishing = analyzer
        analyzer = nil
        if let finishing {
            Task { await finishing.cancelAndFinishNow() }
        }
        if let locale = reservedLocale {
            reservedLocale = nil
            Task { _ = await AssetInventory.release(reservedLocale: locale) }
        }
        if cancelTurn, let turnContinuation {
            self.turnContinuation = nil
            turnContinuation.resume(throwing: CancellationError())
        }
    }

    private func handleTranscript(text raw: String, isFinal: Bool) async {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if isFinal {
            // Final supersedes the current volatile hypothesis — do not append both.
            volatile = ""
            if !committed.isEmpty { committed += " " }
            committed += text
        } else {
            // After a mid-turn pause, Dictation often starts a fresh volatile hypothesis
            // ("Bu hafta… var" → "ve ne zaman"). Keep the earlier words in committed.
            if shouldCommitVolatile(before: text) {
                commitVolatile()
            }
            volatile = text
        }
        heardSpeech = true
        lastActivity = Date()
        bumpSilenceWatch()
        Self.log.info(
            "Talk partial final=\(isFinal) characters=\(self.partialText.count) head=\(String(self.partialText.prefix(60)), privacy: .public)"
        )
    }

    /// Moves the current volatile hypothesis into the stable turn text.
    private func commitVolatile() {
        let piece = volatile.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !piece.isEmpty else {
            volatile = ""
            return
        }
        if !committed.isEmpty { committed += " " }
        committed += piece
        volatile = ""
    }

    /// True when the new partial looks like a new utterance, not an edit of the current one.
    private func shouldCommitVolatile(before text: String) -> Bool {
        let prev = volatile.trimmingCharacters(in: .whitespacesAndNewlines)
        guard prev.count >= 8 else { return false }
        if text.hasPrefix(prev) || prev.hasPrefix(text) { return false }
        let shared = zip(prev, text).prefix(while: { $0 == $1 }).count
        let need = max(6, min(prev.count, text.count) * 2 / 3)
        return shared < need
    }

    /// Progressive preset gives volatile partials; shortForm matches Talk turn length.
    private static func makeDictationTranscriber(locale: Locale) -> DictationTranscriber {
        let preset = DictationTranscriber.Preset.progressiveLongDictation
        return DictationTranscriber(
            locale: locale,
            contentHints: preset.contentHints.union([.shortForm]),
            transcriptionOptions: preset.transcriptionOptions,
            reportingOptions: preset.reportingOptions.union([.volatileResults]),
            attributeOptions: preset.attributeOptions
        )
    }

    /// Bare language tags like `tr` cannot be reserved. Prefer installed/supported regional locales.
    private static func resolveDictationLocale(_ preferred: Locale) async throws -> Locale {
        let language = preferred.language.languageCode?.identifier
            ?? preferred.identifier.split(whereSeparator: { $0 == "_" || $0 == "-" }).first.map(String.init)
            ?? preferred.identifier
        Self.log.info(
            "Talk locale resolve preferred=\(preferred.identifier, privacy: .public) language=\(language, privacy: .public)"
        )

        var candidates: [Locale] = []
        func append(_ locale: Locale?) {
            guard let locale else { return }
            if candidates.contains(where: { $0.identifier == locale.identifier }) { return }
            candidates.append(locale)
        }

        append(await DictationTranscriber.supportedLocale(equivalentTo: preferred))
        if language == "tr" {
            append(Locale(identifier: "tr_TR"))
            append(Locale(identifier: "tr-TR"))
        }
        append(Locale(identifier: "\(language)_TR"))
        append(Locale(identifier: "\(language)-\(language.uppercased())"))
        append(Locale(identifier: "\(language)_\(language.uppercased())"))
        append(preferred)
        append(Locale.current)
        for installed in await DictationTranscriber.installedLocales
            where installed.language.languageCode?.identifier == language
        {
            append(installed)
        }
        for supported in await DictationTranscriber.supportedLocales
            where supported.language.languageCode?.identifier == language
        {
            append(supported)
        }
        append(Locale(identifier: "en_US"))
        append(await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en_US")))

        for candidate in candidates {
            if let resolved = await DictationTranscriber.supportedLocale(equivalentTo: candidate) {
                // Skip bare language codes — AssetInventory rejects "tr".
                let id = resolved.identifier
                if id.count > 2, id.contains("_") || id.contains("-") || resolved.region != nil {
                    Self.log.info("Talk locale resolved=\(id, privacy: .public)")
                    return resolved
                }
            }
            let id = candidate.identifier
            if id.count > 2, id.contains("_") || id.contains("-") {
                Self.log.info("Talk locale candidate=\(id, privacy: .public)")
                return candidate
            }
        }
        Self.log.error("Talk locale unsupported preferred=\(preferred.identifier, privacy: .public)")
        throw TalkListenError.speechUnsupported
    }

    private func handleDetection(_ result: SpeechDetector.Result) async {
        if result.speechDetected {
            heardSpeech = true
            lastActivity = Date()
            bumpSilenceWatch()
            // While TTS plays, detector hears the loudspeaker — only mic-energy may barge.
            if turnContinuation != nil { return }
        } else if heardSpeech {
            // Pause between phrases — lock what was heard so the next partial cannot wipe it.
            commitVolatile()
            bumpSilenceWatch()
        }
    }

    private func handleBargeTranscript(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // After TTS stopped we already have a turn continuation — treat like a normal listen.
        if turnContinuation != nil {
            if isBargeEcho(trimmed) { return }
            await handleTranscript(text: trimmed, isFinal: false)
            return
        }
        // While Supertonic plays: never barge on transcript (echo of "Deneme…"). Mic-energy only.
        if isBargeEcho(trimmed) {
            Self.log.info("Talk barge ignore echo head=\(String(trimmed.prefix(40)), privacy: .public)")
            return
        }
        if shouldCommitVolatile(before: trimmed) {
            commitVolatile()
        }
        volatile = trimmed
        heardSpeech = true
        lastActivity = Date()
        Self.log.info(
            "Talk barge partial characters=\(self.partialText.count) head=\(String(self.partialText.prefix(60)), privacy: .public)"
        )
        // AEC can keep mic energy under the trip threshold. A non-echo phrase is the student.
        let words = partialText.split(whereSeparator: \.isWhitespace).count
        guard words >= 2 || partialText.count >= 12 else { return }
        fireBargeIn(reason: "transcript")
    }

    /// Loudspeaker bleed of the reply currently playing.
    func looksLikeEcho(_ text: String) -> Bool {
        isBargeEcho(text)
    }

    /// True when ASR is hearing the reply from the speaker, not the student.
    private func isBargeEcho(_ text: String) -> Bool {
        let folded = Self.asciiFold(text)
        guard folded.count >= 2, !bargeEchoSource.isEmpty else { return false }
        if bargeEchoSource.hasPrefix(folded) { return true }
        if folded.count >= 4, bargeEchoSource.contains(folded) { return true }
        let speakWord = bargeEchoSource.split(whereSeparator: { !$0.isLetter }).first.map(String.init)
        let heardWord = folded.split(whereSeparator: { !$0.isLetter }).first.map(String.init)
        if let speakWord, let heardWord, speakWord == heardWord, folded.count <= speakWord.count + 3 {
            return true
        }
        return false
    }

    private static func asciiFold(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "ı", with: "i")
            .replacingOccurrences(of: "İ", with: "i")
            .replacingOccurrences(of: "ş", with: "s")
            .replacingOccurrences(of: "ğ", with: "g")
            .replacingOccurrences(of: "ü", with: "u")
            .replacingOccurrences(of: "ö", with: "o")
            .replacingOccurrences(of: "ç", with: "c")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func bufferRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n {
            let s = channel[i]
            sum += s * s
        }
        return sqrt(sum / Float(n))
    }

    private func bumpSilenceWatch() {
        silenceTask?.cancel()
        guard turnContinuation != nil else { return }
        silenceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.silenceNanoseconds)
            guard !Task.isCancelled else { return }
            await self?.finishTurnIfReady()
        }
    }

    private func finishTurnIfReady() async {
        guard let turnContinuation else { return }
        let text = partialText
        guard heardSpeech, !text.isEmpty else {
            bumpSilenceWatch()
            return
        }
        let idle = Date().timeIntervalSince(lastActivity)
        guard idle >= Self.silenceSeconds else {
            bumpSilenceWatch()
            return
        }
        Self.log.info("Talk turn end characters=\(text.count)")
        self.turnContinuation = nil
        silenceTask?.cancel()
        silenceTask = nil
        // Stop feeding; keep assets release in stopListening after the caller moves on.
        inputContinuation?.finish()
        inputContinuation = nil
        tearDownMicTap()
        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
            self.analyzer = nil
        }
        turnContinuation.resume(returning: text)
    }

    /// Removes the mic tap, turns Voice Processing off if it was left on, then stops the engine.
    private func tearDownMicTap() {
        player.stop()
        isPlaybackActive = false
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        // VP can only change while the engine is stopped.
        applyVoiceProcessing(false)
    }

    private func failTurn(_ error: Error) async {
        guard let turnContinuation else { return }
        self.turnContinuation = nil
        turnContinuation.resume(throwing: error)
        stopListening(cancelTurn: false)
    }

    private func ensureAssets(for modules: [any SpeechModule], locale: Locale) async throws {
        do {
            _ = try await AssetInventory.reserve(locale: locale)
        } catch {
            Self.log.error(
                "Talk reserve failed locale=\(locale.identifier, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            let message = error.localizedDescription.lowercased()
            if message.contains("unsupported locale") || message.contains("unable to reserve") {
                throw TalkListenError.speechUnsupported
            }
            throw error
        }
        let status = await AssetInventory.status(forModules: modules)
        Self.log.info("Talk asset status=\(String(describing: status), privacy: .public)")
        switch status {
        case .installed:
            break
        case .supported, .downloading:
            if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                try await request.downloadAndInstall()
            }
        case .unsupported:
            throw TalkListenError.speechUnsupported
        @unknown default:
            break
        }
    }

    private static let sessionQueue = DispatchQueue(label: "app.bellnote.talk-session")

    /// Category/activate must not run on the main thread while a session is already active (SessionCore hang risk).
    /// Handsfree on the built-in speaker; headphones / Bluetooth keep their own route (not earpiece voice-chat).
    static func activateTalkSession() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                let session = AVAudioSession.sharedInstance()
                do {
                    // `.voiceChat` ducks to the receiver like a phone call. Spoken audio + defaultToSpeaker
                    // is the handsfree path; A2DP covers stereo headphones when not recording through BT.
                    try session.setCategory(
                        .playAndRecord,
                        mode: .spokenAudio,
                        options: [.defaultToSpeaker, .allowBluetoothA2DP, .allowBluetoothHFP]
                    )
                    try Self.applyTalkOutputRoute(session)
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                session.activate(options: []) { activated, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard activated else {
                        continuation.resume(throwing: TalkListenError.sessionFailed)
                        return
                    }
                    do {
                        try Self.applyTalkOutputRoute(session)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// Loudspeaker when nothing is plugged in; otherwise leave the system route (wired / AirPods).
    /// Runs on `sessionQueue`, not the main actor (same hang risk as category/activate).
    nonisolated private static func applyTalkOutputRoute(_ session: AVAudioSession) throws {
        let external: Set<AVAudioSession.Port> = [
            .headphones,
            .bluetoothA2DP,
            .bluetoothHFP,
            .bluetoothLE,
            .carAudio,
            .usbAudio,
        ]
        let hasExternal = session.currentRoute.outputs.contains { external.contains($0.portType) }
        if hasExternal {
            try session.overrideOutputAudioPort(.none)
            log.info("Talk audio route external")
        } else {
            try session.overrideOutputAudioPort(.speaker)
            log.info("Talk audio route speaker handsfree")
        }
    }
}

enum TalkListenError: Error {
    case speechUnsupported
    case sessionFailed
}

/// Adaptive mic-level barge while Supertonic plays on the loudspeaker.
private final class BargeMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    private var calibrating = true
    private var calibCount = 0
    private var floor: Float = 0.012
    private var hotFrames = 0
    var onTrip: (() -> Void)?

    func reset() {
        lock.lock()
        armed = false
        calibrating = true
        calibCount = 0
        floor = 0.012
        hotFrames = 0
        lock.unlock()
    }

    func arm() {
        lock.lock()
        armed = true
        calibrating = true
        calibCount = 0
        hotFrames = 0
        lock.unlock()
    }

    func disarm() {
        lock.lock()
        armed = false
        hotFrames = 0
        lock.unlock()
    }

    func note(rms: Float) {
        lock.lock()
        guard armed else {
            lock.unlock()
            return
        }
        if calibrating {
            floor = max(floor, rms * 1.15)
            calibCount += 1
            if calibCount >= 14 {
                calibrating = false
            }
            lock.unlock()
            return
        }
        let threshold = floor + 0.028
        if rms > threshold {
            hotFrames += 1
            if hotFrames >= 4 {
                hotFrames = 0
                armed = false
                let trip = onTrip
                lock.unlock()
                trip?()
                return
            }
        } else {
            hotFrames = 0
        }
        lock.unlock()
    }
}
