import Foundation
import FoundationModels

/// What the model writes for one window. Only the fields the app uses are here: every extra field is more
/// text the model has to generate, and on a phone that is time.
@Generable
struct WindowTagging {
    var kind: String
    var topics: [String]
    var missing: Bool
}

/// A stored block as it is handed to the model when it writes a page or answers a question.
/// `text` is the spoken words of the block; the model does not write it.
@Generable
struct WindowTag {
    var language: String
    var speakerRole: String
    var kind: String
    var topics: [String]
    var text: String
    var importanceCue: Bool
    var missing: Bool
}

enum TagValidator {
    static func validate(_ tag: WindowTagging) -> Bool {
        BlockKind(rawValue: tag.kind) != nil
    }
}
