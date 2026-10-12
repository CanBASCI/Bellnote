import Foundation

enum AppLanguage: String, CaseIterable, Sendable {
    case system
    case english = "en"
    case turkish = "tr"

    static func resolved(preference: String, system: String) -> String {
        if preference == AppLanguage.english.rawValue || preference == AppLanguage.turkish.rawValue {
            return preference
        }
        if system.hasPrefix("tr") { return "tr" }
        return "en"
    }
}

enum AppPreferences {
    static let languageKey = "appLanguage"
    static let lockEnabledKey = "lockEnabled"
    static let lecturerAskedKey = "lecturerAsked."
    static let pagePrefersTaggerKey = "pagePrefersTagger"
    static let measuredPageSecondsKey = "measuredPageSeconds"
}
