import Foundation

/// Looks up catalog strings in the language chosen in Settings, not the phone's system language.
/// SwiftUI `Text("…")` already follows `.environment(\.locale)`.
/// `String(localized:locale:)` only formats interpolations; it still looks up in the system language.
/// This uses `LocalizedStringResource.locale` so the catalog language matches Settings.
enum L10n {
    /// Resolved UI language: English or Turkish from Settings, or from the system when Settings says System.
    static var locale: Locale {
        let stored = UserDefaults.standard.string(forKey: AppPreferences.languageKey) ?? AppLanguage.system.rawValue
        let code = AppLanguage.resolved(preference: stored, system: Locale.current.identifier)
        return Locale(identifier: code)
    }

    /// Calendar whose weekday and month names follow Settings, not the phone language.
    static var calendar: Calendar {
        var calendar = Calendar.current
        calendar.locale = locale
        return calendar
    }

    /// A date or time written in the Settings language. `formatted(date:time:)` alone follows the phone.
    static func dateString(
        _ value: Date,
        date dateStyle: Date.FormatStyle.DateStyle = .omitted,
        time timeStyle: Date.FormatStyle.TimeStyle = .omitted
    ) -> String {
        value.formatted(Date.FormatStyle(date: dateStyle, time: timeStyle, locale: locale))
    }

    static func text(_ key: String.LocalizationValue, locale override: Locale? = nil) -> String {
        var resource = LocalizedStringResource(key)
        resource.locale = override ?? locale
        return String(localized: resource)
    }
}
