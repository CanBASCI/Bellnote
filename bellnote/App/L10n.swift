import Foundation

enum L10n {
    static func text(_ key: String.LocalizationValue) -> String {
        String(localized: key)
    }
}
