import Foundation

enum LectureState: String, Codable, Sendable {
    case recording
    case paused
    case processing
    case ready
    case failed

    var title: String {
        switch self {
        case .recording: String(localized: "Recording")
        case .paused: String(localized: "Paused")
        case .processing: String(localized: "Processing")
        case .ready: String(localized: "Ready")
        case .failed: String(localized: "Failed")
        }
    }
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

    var fraction: Double {
        switch self {
        case .idle: 0.08
        case .audio: 0.2
        case .speakers: 0.35
        case .transcript: 0.55
        case .tags: 0.75
        case .page: 0.9
        case .links, .ready: 1
        case .failed: 0
        }
    }

    var title: String {
        switch self {
        case .idle, .audio: String(localized: "Reading the recording")
        case .speakers: String(localized: "Separating speakers")
        case .transcript: String(localized: "Writing the transcript")
        case .tags: String(localized: "Tagging the lecture")
        case .page: String(localized: "Writing the page")
        case .links, .ready: String(localized: "Linking notes")
        case .failed: String(localized: "Failed")
        }
    }

    /// One or two sentences that say what the app does in this stage.
    var info: String {
        switch self {
        case .idle, .audio: String(localized: "The app checks that the recording opens and is complete.")
        case .speakers: String(localized: "The app finds out who speaks when. This happens on your phone.")
        case .transcript: String(localized: "Whisper turns the speech into text. The ring follows how much of the recording it has read.")
        case .tags: String(localized: "The model marks definitions, lists, examples and assignments in the text.")
        case .page: String(localized: "The AI correction is written from the transcript, with correct spelling and punctuation.")
        case .links, .ready: String(localized: "The notes are linked to earlier lectures of this course.")
        case .failed: ""
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

enum ModelRole: String, Codable, Sendable, CaseIterable {
    case tagger
    case page
    case whisper

    /// Models that write text through `LanguageModelSession`. Whisper only hears audio.
    var isTextModel: Bool { self != .whisper }
}

enum SpeechEngine: String, Codable, Sendable {
    case apple
    case whisper
}

enum ReadAloud: String, Codable, Sendable {
    case apple
    case supertonic
}
