import Foundation

struct DeviceBudget: Sendable, Equatable {
    var freeDiskBytes: Int64
    var physicalMemoryBytes: UInt64
}

enum ModelLock {
    static let twoGigabytes: Int64 = 2 * 1_073_741_824
    static let fourGigabytes: Int64 = 4 * 1_073_741_824

    /// `physicalMemory` is usable RAM. On every iPhone it sits below the installed size, inside the previous gibibyte.
    static func installedGigabytes(_ reportedBytes: UInt64) -> Int {
        let gibibytes = Double(reportedBytes) / Double(1_073_741_824)
        return Int(gibibytes.rounded(.up))
    }

    static func taggerLocked(_ budget: DeviceBudget) -> Bool {
        budget.freeDiskBytes < twoGigabytes
    }

    static func pageLocked(_ budget: DeviceBudget) -> Bool {
        budget.freeDiskBytes < fourGigabytes || installedGigabytes(budget.physicalMemoryBytes) < 8
    }

    /// Whisper large-v3 turbo is a 0.65 GB download. Core ML needs about the same again to prepare it.
    static func whisperLocked(_ budget: DeviceBudget) -> Bool {
        budget.freeDiskBytes < twoGigabytes
    }

    static func locked(_ role: ModelRole, _ budget: DeviceBudget) -> Bool {
        switch role {
        case .tagger: taggerLocked(budget)
        case .page: pageLocked(budget)
        case .whisper: whisperLocked(budget)
        }
    }
}

enum ModelCatalog {
    static let taggerRepo = "mlx-community/Qwen3.5-2B-4bit"
    static let pageRepo = "mlx-community/Qwen3.5-4B-4bit"
    /// Whisper large-v3 turbo (Core ML, 632 MB build) from Argmax, used through WhisperKit.
    static let whisperRepo = "argmaxinc/whisperkit-coreml"
    static let whisperVariant = "openai_whisper-large-v3-v20240930_turbo_632MB"
    /// WhisperKit needs the tokenizer files. They come with the download, never at load time.
    static let whisperTokenizerRepo = "openai/whisper-large-v3"
    static let supertonicRepo = "csukuangfj2/sherpa-onnx-supertonic-3-tts-int8-2026-05-11"

    static let taggerBytes: Int64 = 1_610_612_736
    static let pageBytes: Int64 = 3_114_000_000
    static let whisperBytes: Int64 = 648_500_000
    static let supertonicBytes: Int64 = 145_295_768
    /// Offline diarizer (FluidAudio); approximate download size.
    static let diarizerBytes: Int64 = 157_286_400

    static func repo(for role: ModelRole) -> String {
        switch role {
        case .tagger: taggerRepo
        case .page: pageRepo
        case .whisper: whisperRepo
        }
    }
}
