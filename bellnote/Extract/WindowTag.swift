import Foundation
import FoundationModels

@Generable
struct WindowTag {
    var language: String
    var speakerRole: String
    var kind: String
    var topics: [String]
    var text: String
    var listItems: [String]
    var numbers: [Double]
    var importanceCue: Bool
    var missing: Bool
}

enum TagValidator {
    static func validate(_ tag: WindowTag) -> Bool {
        BlockKind(rawValue: tag.kind) != nil && !tag.text.isEmpty
    }
}
