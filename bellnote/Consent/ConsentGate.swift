import Foundation

struct ConsentGate: Sendable {
    var allowed: Bool
    var permitted: Bool

    var canStart: Bool { allowed && permitted }
}
