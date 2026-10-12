import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class AppSession {
    var unlocked: Bool
    var languageCode: String
    var focusCourseToken: UUID?
    var focusLectureID: PersistentIdentifier?
    var showModelDownload = false
    var focusedModel: ModelRole?
    var resumeAfterInterruption = false
    var preferTaggerForPage: Bool

    init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: AppPreferences.lockEnabledKey) == nil {
            defaults.set(true, forKey: AppPreferences.lockEnabledKey)
        }
        let lock = defaults.bool(forKey: AppPreferences.lockEnabledKey)
        unlocked = !lock
        let stored = defaults.string(forKey: AppPreferences.languageKey) ?? AppLanguage.system.rawValue
        languageCode = AppLanguage.resolved(preference: stored, system: Locale.current.identifier)
        preferTaggerForPage = defaults.bool(forKey: AppPreferences.pagePrefersTaggerKey)
    }

    func setLanguage(_ language: AppLanguage) {
        UserDefaults.standard.set(language.rawValue, forKey: AppPreferences.languageKey)
        languageCode = AppLanguage.resolved(preference: language.rawValue, system: Locale.current.identifier)
    }

    var locale: Locale { Locale(identifier: languageCode) }
}
