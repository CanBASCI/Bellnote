import Foundation

enum AppLanguage: String, CaseIterable, Sendable {
    case system
    case english = "en"
    case turkish = "tr"

    static var courseChoices: [AppLanguage] {
        let preferred = deviceCourseDefault
        return [preferred] + [english, turkish].filter { $0 != preferred }
    }

    static var deviceCourseDefault: AppLanguage {
        Locale.current.identifier.hasPrefix("tr") ? .turkish : .english
    }

    var speechLocaleIdentifier: String {
        switch self {
        case .turkish: "tr_TR"
        case .english, .system: "en_US"
        }
    }

    var title: String {
        switch self {
        case .system: "System"
        case .english: "English"
        case .turkish: "Turkish"
        }
    }

    static func resolved(preference: String, system: String) -> String {
        if preference == AppLanguage.english.rawValue || preference == AppLanguage.turkish.rawValue {
            return preference
        }
        if system.hasPrefix("tr") { return "tr" }
        return "en"
    }
}

enum AppAppearance: String, CaseIterable, Sendable {
    case system
    case light
    case dark
}

enum AppPreferences {
    static let languageKey = "appLanguage"
    static let appearanceKey = "appAppearance"
    static let lockEnabledKey = "lockEnabled"
    static let lecturerAskedKey = "lecturerAsked."
    static let pagePrefersTaggerKey = "pagePrefersTagger"
    static let speechEngineKey = "speechEngine"
    static let measuredPageSecondsKey = "measuredPageSeconds"
}
