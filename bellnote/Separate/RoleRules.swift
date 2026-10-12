import Foundation

struct SpeechRun: Sendable, Equatable {
    var start: Int
    var end: Int
    var cluster: Int
    var overlap: Bool
    var near: Bool
    var addressedLecturer: Bool

    var duration: Int { max(0, end - start) }
}

enum RoleRules {
    static func label(_ run: SpeechRun, longestCluster: Int) -> SpeakerRole {
        if run.overlap && run.duration < 8 {
            return .room
        }
        if run.near && run.duration < 20 && run.addressedLecturer {
            return .question
        }
        if run.cluster == longestCluster && run.duration >= 20 {
            return .narrator
        }
        if run.duration < 4 {
            return .room
        }
        return .unknown
    }

    static func longestCluster(_ runs: [SpeechRun]) -> Int? {
        var totals: [Int: Int] = [:]
        for run in runs where !run.overlap {
            totals[run.cluster, default: 0] += run.duration
        }
        return totals.max { $0.value < $1.value }?.key
    }
}
