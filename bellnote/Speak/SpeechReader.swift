import AVFoundation
import Foundation

@MainActor
final class SpeechReader: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var paragraphs: [String] = []
    private var index = 0
    private var locale = Locale.current

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func read(_ text: String, locale: Locale) {
        stop()
        self.locale = locale
        paragraphs = text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        if paragraphs.isEmpty, !text.isEmpty { paragraphs = [text] }
        index = 0
        speakCurrent()
    }

    func pause() {
        synthesizer.pauseSpeaking(at: .word)
    }

    func resume() {
        synthesizer.continueSpeaking()
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        paragraphs = []
        index = 0
    }

    private func speakCurrent() {
        guard paragraphs.indices.contains(index) else { return }
        let utterance = AVSpeechUtterance(string: paragraphs[index])
        utterance.voice = AVSpeechSynthesisVoice(language: locale.identifier)
        synthesizer.speak(utterance)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            index += 1
            speakCurrent()
        }
    }
}
