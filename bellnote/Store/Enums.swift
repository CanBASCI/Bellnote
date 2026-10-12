import Foundation

enum LectureState: String, Codable, Sendable {
    case recording
    case paused
    case processing
    case ready
    case failed
}

enum PipelineStage: String, Codable, Sendable, CaseIterable {
    case idle
    case audio
    case speakers
    case transcript
    case tags
    case page
    case links
    case ready
    case failed

    var next: PipelineStage? {
        switch self {
        case .idle: .audio
        case .audio: .speakers
        case .speakers: .transcript
        case .transcript: .tags
        case .tags: .page
        case .page: .links
        case .links: .ready
        case .ready, .failed: nil
        }
    }
}

enum SpeakerRole: String, Codable, Sendable {
    case narrator
    case question
    case room
    case unknown
    case lecturer
}

enum BlockKind: String, Codable, Sendable, CaseIterable {
    case definition
    case list
    case example
    case emphasis
    case reference
    case assignment
    case examScope
    case decision
    case other

    init(tag: String) {
        self = BlockKind(rawValue: tag) ?? .other
    }
}

enum SlotPlace: String, Codable, Sendable, CaseIterable {
    case inPerson
    case online
    case remote
}

enum ReminderKind: String, Codable, Sendable, CaseIterable {
    case none
    case notification
    case alert
}

enum GapMark: String, Codable, Sendable {
    case missed
    case cancelled
}

enum ExamKind: String, Codable, Sendable, CaseIterable {
    case midterm
    case final
    case other
}

enum InventoryKind: String, Codable, Sendable, CaseIterable {
    case book
    case chapter
    case other
}

enum CourseFileKind: String, Codable, Sendable {
    case pdf
    case slide
    case image
    case other

    init(url: URL) {
        switch url.pathExtension.lowercased() {
        case "pdf": self = .pdf
        case "ppt", "pptx", "key": self = .slide
        case "png", "jpg", "jpeg", "heic", "gif", "webp": self = .image
        default: self = .other
        }
    }
}

enum StudyMode: String, Codable, Sendable {
    case ask
    case quiz
}

enum ModelRole: String, Codable, Sendable, CaseIterable {
    case tagger
    case page
    case asr
}
