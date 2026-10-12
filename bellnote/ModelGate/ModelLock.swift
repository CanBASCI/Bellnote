import Foundation

struct DeviceBudget: Sendable, Equatable {
    var freeDiskBytes: Int64
    var physicalMemoryBytes: UInt64
}

enum ModelLock {
    static let twoGigabytes: Int64 = 2 * 1_073_741_824
    static let fourGigabytes: Int64 = 4 * 1_073_741_824
    static let eightGigabytes: UInt64 = 8 * 1_073_741_824

    static func taggerLocked(_ budget: DeviceBudget) -> Bool {
        budget.freeDiskBytes < twoGigabytes
    }

    static func pageLocked(_ budget: DeviceBudget) -> Bool {
        budget.freeDiskBytes < fourGigabytes || budget.physicalMemoryBytes < eightGigabytes
    }
}

enum ModelCatalog {
    static let taggerRepo = "mlx-community/Qwen3.5-2B-MLX-4bit"
    static let pageRepo = "mlx-community/Qwen3.5-4B-MLX-4bit"
    static let asrRepo = "mlx-community/Qwen3-ASR-0.6B-4bit"

    static let taggerBytes: Int64 = 1_610_612_736
    static let pageBytes: Int64 = 3_114_000_000
    static let asrBytes: Int64 = 419_430_400
}
