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

/// Reading face chosen in Settings. SF Pro is the system face. The others are installed on iOS.
enum AppTypeface: String, CaseIterable, Sendable {
    case sfPro
    case sfProCondensed
    case sfProCompressed
    case sfProExpanded
    case sfCompact
    case avenirNext
    case helveticaNeue
    case seravek
    case galvji
    case futura
    case dinAlternate
    case newYork
    case avenir
    case avenirNextCondensed
    case helvetica
    case arial
    case verdana
    case trebuchet
    case carlito
    case timesNewRoman
    case georgia
    case palatino
    case charter
    case baskerville
    case hoeflerText
    case iowanOldStyle
    case athelas
    case bodoni
    case superclarendon
    case americanTypewriter
    case rockwell
    case menlo
    case courierNew

    /// The name on the picker row. These are the faces' own names in both languages.
    var menuTitle: String {
        switch self {
        case .sfPro: "SF Pro"
        case .sfProCondensed: "SF Pro Condensed"
        case .sfProCompressed: "SF Pro Compressed"
        case .sfProExpanded: "SF Pro Expanded"
        case .sfCompact: "SF Compact"
        case .avenirNext: "Avenir Next"
        case .helveticaNeue: "Helvetica Neue"
        case .seravek: "Seravek"
        case .galvji: "Galvji"
        case .futura: "Futura"
        case .dinAlternate: "DIN Alternate"
        case .newYork: "New York"
        case .avenir: "Avenir"
        case .avenirNextCondensed: "Avenir Next Condensed"
        case .helvetica: "Helvetica"
        case .arial: "Arial"
        case .verdana: "Verdana"
        case .trebuchet: "Trebuchet MS"
        case .carlito: "Carlito"
        case .timesNewRoman: "Times New Roman"
        case .georgia: "Georgia"
        case .palatino: "Palatino"
        case .charter: "Charter"
        case .baskerville: "Baskerville"
        case .hoeflerText: "Hoefler Text"
        case .iowanOldStyle: "Iowan Old Style"
        case .athelas: "Athelas"
        case .bodoni: "Bodoni 72"
        case .superclarendon: "Superclarendon"
        case .americanTypewriter: "American Typewriter"
        case .rockwell: "Rockwell"
        case .menlo: "Menlo"
        case .courierNew: "Courier New"
        }
    }
}

enum AppPreferences {
    static let languageKey = "appLanguage"
    static let appearanceKey = "appAppearance"
    static let typefaceKey = "appTypeface"
    static let lockEnabledKey = "lockEnabled"
    static let lecturerAskedKey = "lecturerAsked."
    static let pagePrefersTaggerKey = "pagePrefersTagger"
    static let pageModelKey = "pageModel"
    static let speechEngineKey = "speechEngine"
    static let readAloudKey = "readAloud"
    static let supertonicVoiceKey = "supertonicVoice"
    static let measuredPageSecondsKey = "measuredPageSeconds"

    /// The text model the student picked for the page and Ask.
    /// Falls back to the older 2B/4B switch when no pick was stored yet.
    static func pageModel(_ defaults: UserDefaults = .standard) -> ModelRole {
        if let raw = defaults.string(forKey: pageModelKey),
           let role = ModelRole(rawValue: raw),
           role.isTextModel {
            return role
        }
        return defaults.bool(forKey: pagePrefersTaggerKey) ? .tagger : .page
    }
}
