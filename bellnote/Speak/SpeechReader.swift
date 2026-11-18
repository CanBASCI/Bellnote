import AVFoundation
import Foundation
import Observation
import OSLog

/// Reads text aloud with Supertonic. There is no other voice: when Supertonic is not installed, nothing is read,
/// and the screen that asks for it says to download it in Settings.
@MainActor
@Observable
final class SpeechReader {
    private static let log = Logger(subsystem: "app.bellnote", category: "listen")
    private(set) var isSpeaking = false
    /// True only while a Supertonic buffer is on the speaker (not during clip generation).
    private(set) var isAudioPlaying = false
    private var paragraphs: [String] = []
    private var index = 0
    private var locale = Locale.current
    private var turn = 0

    private var startedAt = Date.distantPast
    private let playback = AVAudioEngine()
    private let playbackNode = AVAudioPlayerNode()
    private let sessionQueue = DispatchQueue(label: "app.bellnote.listen-session", qos: .userInitiated)
    private var playbackReady = false
    private var sessionReady = false
    private var supertonicCancel = SupertonicCancel()

    /// A short sample of the chosen voice, for the voice picker.
    func preview(_ text: String, locale: Locale) {
        guard SupertonicSpeech.isInstalled else { return }
        // Self.log.info("Listen preview characters=\(text.count) locale=\(locale.identifier, privacy: .public)")
        begin(text, locale: locale)
    }

    func read(_ text: String, locale: Locale) {
        // Self.log.info(
            // "Listen read characters=\(text.count) locale=\(locale.identifier, privacy: .public) speaking=\(self.isSpeaking) preview=\(String(text.prefix(80)), privacy: .public)"
        // )
        guard SupertonicSpeech.isInstalled else {
            Self.log.error("Listen skipped; Supertonic is not installed")
            return
        }
        begin(text, locale: locale)
    }

    /// When false, playback uses the already-active session (Talk screen keeps `.playAndRecord` for barge-in).
    var ownsAudioSession = true
    /// 0...1. Talk ducks slightly while speaking so barge-in can hear the student over the loudspeaker.
    var playbackGain: Float = 1

    func stop(force: Bool = false) {
        guard force || Date().timeIntervalSince(startedAt) > 0.4 else {
            // Self.log.info("Listen ignored stop")
            return
        }
        // Self.log.info("Listen stop force=\(force)")
        turn += 1
        isSpeaking = false
        isAudioPlaying = false
        if ownsAudioSession { sessionReady = false }
        supertonicCancel.stopped = true
        playbackNode.stop()
        if playback.isRunning { playback.stop() }
        paragraphs = []
        index = 0
    }

    private func begin(_ text: String, locale: Locale) {
        supertonicCancel.stopped = true
        if playbackReady { playbackNode.stop() }
        let cancel = SupertonicCancel()
        supertonicCancel = cancel
        turn += 1
        self.locale = locale
        paragraphs = text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        if paragraphs.isEmpty, !text.isEmpty { paragraphs = [text] }
        index = 0
        startedAt = Date()
        isSpeaking = !paragraphs.isEmpty
        // Self.log.info("Listen supertonic start paragraphs=\(self.paragraphs.count) turn=\(self.turn)")
        Task { await playParagraph(cancel: cancel) }
    }

    private func playParagraph(cancel: SupertonicCancel) async {
        guard paragraphs.indices.contains(index), isSpeaking else {
            isSpeaking = false
            isAudioPlaying = false
            return
        }
        let text = paragraphs[index]
        let language = supertonicLanguage(locale)
        let speaker = SupertonicVoice.clamped(UserDefaults.standard.integer(forKey: AppPreferences.supertonicVoiceKey))
        let spokenTurn = turn
        // Self.log.info("Listen supertonic index=\(self.index) lang=\(language, privacy: .public) speaker=\(speaker) characters=\(text.count)")
        let clip: SupertonicClip
        do {
            clip = try await SupertonicSpeech.clip(text: text, language: language, speaker: speaker, cancel: cancel)
        } catch {
            Self.log.error("Listen supertonic failed \(error.localizedDescription, privacy: .public)")
            guard spokenTurn == turn, isSpeaking, !cancel.stopped else { return }
            isSpeaking = false
            isAudioPlaying = false
            return
        }
        guard spokenTurn == turn, isSpeaking, !cancel.stopped else { return }
        guard !clip.samples.isEmpty else { return }
        // let seconds = Double(clip.samples.count) / Double(max(clip.sampleRate, 1))
        // Self.log.info("Listen supertonic play seconds=\(seconds)")
        await play(clip, turn: spokenTurn)
    }

    private func play(_ clip: SupertonicClip, turn spokenTurn: Int) async {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(clip.sampleRate),
            channels: 1,
            interleaved: false
        )
        guard let format, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(clip.samples.count)) else {
            Self.log.error("Listen supertonic buffer failed")
            isSpeaking = false
            isAudioPlaying = false
            return
        }
        buffer.frameLength = buffer.frameCapacity
        clip.samples.withUnsafeBufferPointer { source in
            guard let address = source.baseAddress, let channel = buffer.floatChannelData else { return }
            channel[0].update(from: address, count: source.count)
        }
        guard await activatePlaybackSession() else {
            Self.log.error("Listen supertonic session failed")
            isSpeaking = false
            isAudioPlaying = false
            return
        }
        guard spokenTurn == turn, isSpeaking else { return }
        do {
            if !playbackReady {
                playback.attach(playbackNode)
                try playback.connectNode(playbackNode, to: playback.mainMixerNode, format: format)
                playbackReady = true
            }
            let gain = min(1, max(0, playbackGain))
            playback.mainMixerNode.outputVolume = gain
            playbackNode.volume = gain
            if !playback.isRunning { try playback.start() }
        } catch {
            Self.log.error("Listen supertonic audio \(error.localizedDescription, privacy: .public)")
            isSpeaking = false
            isAudioPlaying = false
            return
        }
        playbackNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                self?.paragraphFinished(turn: spokenTurn)
            }
        }
        do {
            try playbackNode.playAudio()
            isAudioPlaying = true
        } catch {
            Self.log.error("Listen supertonic play \(error.localizedDescription, privacy: .public)")
            isAudioPlaying = false
            isSpeaking = false
        }
    }

    private func activatePlaybackSession() async -> Bool {
        if !ownsAudioSession { return true }
        if sessionReady { return true }
        let ready = await withCheckedContinuation { continuation in
            sessionQueue.async {
                let session = AVAudioSession.sharedInstance()
                do {
                    try session.setCategory(.playback, mode: .spokenAudio)
                } catch {
                    continuation.resume(returning: false)
                    return
                }
                session.activate(options: []) { activated, _ in
                    continuation.resume(returning: activated)
                }
            }
        }
        if ready { sessionReady = true }
        return ready
    }

    private func paragraphFinished(turn spokenTurn: Int) {
        isAudioPlaying = false
        guard spokenTurn == turn, isSpeaking else { return }
        index += 1
        Task { await playParagraph(cancel: supertonicCancel) }
    }

    private func supertonicLanguage(_ locale: Locale) -> String {
        let code = locale.language.languageCode?.identifier ?? locale.identifier
        return code.hasPrefix("tr") ? "tr" : "en"
    }
}
