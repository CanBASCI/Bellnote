import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class AppSession {
    var unlocked: Bool
    var languageCode: String
    var appearance: AppAppearance
    var focusCourseToken: UUID?
    var focusLectureID: PersistentIdentifier?
    var showModelDownload = false
    var focusedModel: ModelRole?
    var resumeAfterInterruption = false
    var preferTaggerForPage: Bool
    var speechEngine: SpeechEngine

    init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: AppPreferences.lockEnabledKey) == nil {
            defaults.set(true, forKey: AppPreferences.lockEnabledKey)
        }
        let lock = defaults.bool(forKey: AppPreferences.lockEnabledKey)
        unlocked = !lock
        let stored = defaults.string(forKey: AppPreferences.languageKey) ?? AppLanguage.system.rawValue
        languageCode = AppLanguage.resolved(preference: stored, system: Locale.current.identifier)
        let storedAppearance = defaults.string(forKey: AppPreferences.appearanceKey) ?? AppAppearance.system.rawValue
        appearance = AppAppearance(rawValue: storedAppearance) ?? .system
        preferTaggerForPage = defaults.bool(forKey: AppPreferences.pagePrefersTaggerKey)
        speechEngine = SpeechEngine(rawValue: defaults.string(forKey: AppPreferences.speechEngineKey) ?? "") ?? .apple
    }

    func setAppearance(_ appearance: AppAppearance) {
        UserDefaults.standard.set(appearance.rawValue, forKey: AppPreferences.appearanceKey)
        self.appearance = appearance
    }

    func setLanguage(_ language: AppLanguage) {
        UserDefaults.standard.set(language.rawValue, forKey: AppPreferences.languageKey)
        languageCode = AppLanguage.resolved(preference: language.rawValue, system: Locale.current.identifier)
    }

    func setPreferTaggerForPage(_ preferTagger: Bool) {
        UserDefaults.standard.set(preferTagger, forKey: AppPreferences.pagePrefersTaggerKey)
        preferTaggerForPage = preferTagger
    }

    func setSpeechEngine(_ engine: SpeechEngine) {
        UserDefaults.standard.set(engine.rawValue, forKey: AppPreferences.speechEngineKey)
        speechEngine = engine
    }

    var locale: Locale { Locale(identifier: languageCode) }
}
