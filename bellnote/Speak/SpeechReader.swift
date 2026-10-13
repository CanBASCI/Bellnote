import AVFoundation
import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class SpeechReader: NSObject, AVSpeechSynthesizerDelegate {
    private static let log = Logger(subsystem: "app.bellnote", category: "listen")
    private(set) var isSpeaking = false
    private let synthesizer = AVSpeechSynthesizer()
    private var paragraphs: [String] = []
    private var index = 0
    private var locale = Locale.current
    private var turn = 0
    private var utteranceTurns: [ObjectIdentifier: Int] = [:]

    private var startedAt = Date.distantPast
    private let playback = AVAudioEngine()
    private let playbackNode = AVAudioPlayerNode()
    private var playbackReady = false
    private let supertonicCancel = SupertonicCancel()

    override init() {
        super.init()
        synthesizer.delegate = self
        synthesizer.usesApplicationAudioSession = false
    }

    func read(_ text: String, locale: Locale) {
        Self.log.info(
            "Listen read characters=\(text.count) locale=\(locale.identifier, privacy: .public) speaking=\(self.isSpeaking) synthesizer=\(self.synthesizer.isSpeaking) preview=\(String(text.prefix(80)), privacy: .public)"
        )
        if prefersSupertonic {
            beginSupertonic(text, locale: locale)
            return
        }
        let start = {
            self.turn += 1
            self.locale = locale
            self.paragraphs = text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            if self.paragraphs.isEmpty, !text.isEmpty { self.paragraphs = [text] }
            self.index = 0
            self.startedAt = Date()
            self.isSpeaking = !self.paragraphs.isEmpty
            Self.log.info("Listen start paragraphs=\(self.paragraphs.count) turn=\(self.turn)")
            self.speakCurrent()
        }
        guard synthesizer.isSpeaking else {
            start()
            return
        }
        Self.log.info("Listen stopping current speech before restart")
        synthesizer.stopSpeaking(at: .immediate)
        Task { @MainActor in start() }
    }

    func pause() {
        synthesizer.pauseSpeaking(at: .word)
    }

    func resume() {
        synthesizer.continueSpeaking()
    }

    func stop() {
        guard Date().timeIntervalSince(startedAt) > 0.4 else {
            Self.log.info("Listen ignored stop")
            return
        }
        Self.log.info("Listen stop")
        turn += 1
        isSpeaking = false
        supertonicCancel.stopped = true
        synthesizer.stopSpeaking(at: .immediate)
        playbackNode.stop()
        if playback.isRunning { playback.stop() }
        paragraphs = []
        index = 0
        utteranceTurns = [:]
    }

    private var prefersSupertonic: Bool {
        let raw = UserDefaults.standard.string(forKey: AppPreferences.readAloudKey) ?? ""
        return raw == ReadAloud.supertonic.rawValue && SupertonicSpeech.isInstalled
    }

    private func beginSupertonic(_ text: String, locale: Locale) {
        supertonicCancel.stopped = false
        synthesizer.stopSpeaking(at: .immediate)
        turn += 1
        self.locale = locale
        paragraphs = text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        if paragraphs.isEmpty, !text.isEmpty { paragraphs = [text] }
        index = 0
        startedAt = Date()
        isSpeaking = !paragraphs.isEmpty
        Self.log.info("Listen supertonic start paragraphs=\(self.paragraphs.count) turn=\(self.turn)")
        Task { await playSupertonicParagraph() }
    }

    private func playSupertonicParagraph() async {
        guard paragraphs.indices.contains(index), isSpeaking else {
            isSpeaking = false
            return
        }
        let text = paragraphs[index]
        let language = supertonicLanguage(locale)
        let speaker = SupertonicVoice.clamped(UserDefaults.standard.integer(forKey: AppPreferences.supertonicVoiceKey))
        let spokenTurn = turn
        Self.log.info("Listen supertonic index=\(self.index) lang=\(language, privacy: .public) speaker=\(speaker) characters=\(text.count)")
        let clip: SupertonicClip
        do {
            clip = try await SupertonicSpeech.clip(text: text, language: language, speaker: speaker, cancel: supertonicCancel)
        } catch {
            Self.log.error("Listen supertonic failed \(error.localizedDescription, privacy: .public)")
            guard spokenTurn == turn, isSpeaking, !supertonicCancel.stopped else { return }
            speakCurrent()
            return
        }
        guard spokenTurn == turn, isSpeaking, !supertonicCancel.stopped else { return }
        guard !clip.samples.isEmpty else { return }
        let seconds = Double(clip.samples.count) / Double(max(clip.sampleRate, 1))
        Self.log.info("Listen supertonic play seconds=\(seconds)")
        play(clip, turn: spokenTurn)
    }

    private func play(_ clip: SupertonicClip, turn spokenTurn: Int) {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(clip.sampleRate),
            channels: 1,
            interleaved: false
        )
        guard let format, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(clip.samples.count)) else {
            Self.log.error("Listen supertonic buffer failed")
            isSpeaking = false
            return
        }
        buffer.frameLength = buffer.frameCapacity
        clip.samples.withUnsafeBufferPointer { source in
            guard let address = source.baseAddress, let channel = buffer.floatChannelData else { return }
            channel[0].update(from: address, count: source.count)
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
            if !playbackReady {
                playback.attach(playbackNode)
                playback.connect(playbackNode, to: playback.mainMixerNode, format: format)
                playbackReady = true
            }
            if !playback.isRunning { try playback.start() }
        } catch {
            Self.log.error("Listen supertonic audio \(error.localizedDescription, privacy: .public)")
            isSpeaking = false
            return
        }
        playbackNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                self?.supertonicParagraphFinished(turn: spokenTurn)
            }
        }
        playbackNode.play()
    }

    private func supertonicParagraphFinished(turn spokenTurn: Int) {
        guard spokenTurn == turn, isSpeaking else { return }
        index += 1
        Task { await playSupertonicParagraph() }
    }

    private func supertonicLanguage(_ locale: Locale) -> String {
        let code = locale.language.languageCode?.identifier ?? locale.identifier
        return code.hasPrefix("tr") ? "tr" : "en"
    }

    private func speakCurrent() {
        guard paragraphs.indices.contains(index) else {
            Self.log.info("Listen no paragraph left index=\(self.index)")
            isSpeaking = false
            return
        }
        let utterance = AVSpeechUtterance(string: paragraphs[index])
        let voice = AVSpeechSynthesisVoice(language: locale.identifier)
        utterance.voice = voice
        utteranceTurns[ObjectIdentifier(utterance)] = turn
        Self.log.info(
            "Listen speak index=\(self.index) characters=\(self.paragraphs[self.index].count) voice=\(voice?.language ?? "missing", privacy: .public) name=\(voice?.name ?? "none", privacy: .public)"
        )
        synthesizer.speak(utterance)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let identity = ObjectIdentifier(utterance)
        Task { @MainActor in
            let spokenTurn = utteranceTurns.removeValue(forKey: identity)
            Self.log.info("Listen finished turn=\(spokenTurn ?? -1) current=\(self.turn) speaking=\(self.isSpeaking)")
            guard spokenTurn == turn, isSpeaking else { return }
            index += 1
            speakCurrent()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            Self.log.info("Listen cancelled")
        }
    }
}
