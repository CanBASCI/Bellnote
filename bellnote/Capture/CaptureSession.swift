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
    private var observationTokens: [NotificationCenter.ObservationToken] = []

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

    func start(url: URL) async throws {
        guard let targetFormat else { throw CaptureError.unsupportedFormat }
        let session = AVAudioSession.sharedInstance()
        try await Self.activateRecordSession()
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
        lock.withLock {
            file = audioFile
            self.converter = converter
            recordedFrames = 0
            writeError = nil
            paused = false
            started = true
        }
        input.removeTap(onBus: 0)
        do {
            try input.installAudioTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
                self?.append(buffer)
            }
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            lock.withLock {
                file = nil
                self.converter = nil
                started = false
            }
            throw error
        }
        observeSession(session)
    }

    func pauseCapture() {
        lock.lock()
        let shouldPause = started && !paused
        if shouldPause { paused = true }
        lock.unlock()
        if shouldPause { engine.pause() }
    }

    func resumeCapture() async throws {
        let shouldResume = lock.withLock { started && paused }
        guard shouldResume else { return }
        try await Self.activateRecordSession()
        try engine.start()
        lock.withLock { paused = false }
    }

    func stop() async throws {
        if engine.isRunning || started {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        let error = lock.withLock {
            let error = writeError
            file = nil
            converter = nil
            started = false
            paused = false
            return error
        }
        endObservations()
        if let error { throw error }
        try await Self.deactivateRecordSession()
    }

    private static let sessionQueue = DispatchQueue(label: "app.bellnote.capture-session")

    private static func activateRecordSession() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                let session = AVAudioSession.sharedInstance()
                do {
                    try session.setCategory(
                        .playAndRecord,
                        mode: .default,
                        options: [.allowBluetoothHFP, .defaultToSpeaker]
                    )
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                session.activate(options: []) { activated, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if activated {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: CaptureError.unsupportedFormat)
                    }
                }
            }
        }
    }

    private static func deactivateRecordSession() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                AVAudioSession.sharedInstance().deactivate(options: [.notifyOthersOnDeactivation]) { deactivated, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if deactivated {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: CaptureError.unsupportedFormat)
                    }
                }
            }
        }
    }

    private func append(_ buffer: AVReadOnlyAudioPCMBuffer) {
        let pcm = AVAudioPCMBuffer(copying: buffer)
        lock.lock()
        let isPaused = paused
        let file = file
        let converter = converter
        let format = targetFormat
        lock.unlock()
        guard !isPaused, let file, let converter, let format else { return }
        let ratio = format.sampleRate / pcm.format.sampleRate
        let capacity = AVAudioFrameCount(Double(pcm.frameLength) * ratio) + 1
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
            return pcm
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

    private func observeSession(_ session: AVAudioSession) {
        let center = NotificationCenter.default
        let inactive = center.addObserver(of: session, for: .didBecomeInactive) { [weak self] message in
            guard case .systemInterruption = message.deactivationResult else { return }
            self?.pauseCapture()
        }
        let resume = center.addObserver(of: session, for: .resumptionRecommendation) { [weak self] message in
            guard message.recommendation == .shouldResume else { return }
            self?.onInterruptionEnded?()
        }
        lock.lock()
        observationTokens = [inactive, resume]
        lock.unlock()
    }

    private func endObservations() {
        lock.lock()
        let tokens = observationTokens
        observationTokens = []
        lock.unlock()
        let center = NotificationCenter.default
        for token in tokens {
            center.removeObserver(token)
        }
    }
}

enum CaptureError: Error {
    case unsupportedFormat
}
