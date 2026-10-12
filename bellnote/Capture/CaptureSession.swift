import AVFoundation
import Foundation

nonisolated final class CaptureSession: NSObject, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var started = false
    private var paused = false
    private var recordedFrames: AVAudioFramePosition = 0
    private var writeError: Error?
    private let targetFormat: AVAudioFormat?

    var onInterruptionEnded: (@Sendable () -> Void)?

    override init() {
        targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )
        super.init()
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started && !paused
    }

    func elapsedSeconds() -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let targetFormat, targetFormat.sampleRate > 0 else { return 0 }
        return Int(Double(recordedFrames) / targetFormat.sampleRate)
    }

    func start(url: URL) throws {
        guard let targetFormat else { throw CaptureError.unsupportedFormat }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .defaultToSpeaker])
        try session.setActive(true)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000
        ]
        let audioFile = try AVAudioFile(forWriting: url, settings: settings)
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw CaptureError.unsupportedFormat
        }
        lock.lock()
        file = audioFile
        self.converter = converter
        recordedFrames = 0
        writeError = nil
        paused = false
        started = true
        lock.unlock()
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer)
        }
        engine.prepare()
        try engine.start()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: session
        )
    }

    func pauseCapture() {
        lock.lock()
        let shouldPause = started && !paused
        if shouldPause { paused = true }
        lock.unlock()
        if shouldPause { engine.pause() }
    }

    func resumeCapture() throws {
        lock.lock()
        let shouldResume = started && paused
        lock.unlock()
        guard shouldResume else { return }
        try AVAudioSession.sharedInstance().setActive(true)
        try engine.start()
        lock.lock()
        paused = false
        lock.unlock()
    }

    func stop() throws {
        if engine.isRunning || started {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        lock.lock()
        let error = writeError
        file = nil
        converter = nil
        started = false
        paused = false
        lock.unlock()
        NotificationCenter.default.removeObserver(self)
        if let error { throw error }
        try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let isPaused = paused
        let file = file
        let converter = converter
        let format = targetFormat
        lock.unlock()
        guard !isPaused, let file, let converter, let format else { return }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            store(CaptureError.unsupportedFormat)
            return
        }
        var error: NSError?
        var consumed = false
        converter.convert(to: converted, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if let error {
            store(error)
            return
        }
        guard converted.frameLength > 0 else { return }
        do {
            try file.write(from: converted)
            lock.lock()
            recordedFrames += AVAudioFramePosition(converted.frameLength)
            lock.unlock()
        } catch {
            store(error)
        }
    }

    private func store(_ error: Error) {
        lock.lock()
        if writeError == nil { writeError = error }
        lock.unlock()
    }

    @objc private func handleInterruption(_ note: Notification) {
        guard let value = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: value) else { return }
        if type == .began {
            pauseCapture()
        } else if type == .ended {
            onInterruptionEnded?()
        }
    }
}

enum CaptureError: Error {
    case unsupportedFormat
}
