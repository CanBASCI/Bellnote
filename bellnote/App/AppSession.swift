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
    /// The recording that is open now. The tab bar's bottom accessory shows its player.
    var player: LectureAudio?
    var resumeAfterInterruption = false
    var pageModel: ModelRole
    var speechEngine: SpeechEngine
    var readAloud: ReadAloud
    var supertonicVoice: Int

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
        pageModel = AppPreferences.pageModel(defaults)
        speechEngine = SpeechEngine(rawValue: defaults.string(forKey: AppPreferences.speechEngineKey) ?? "") ?? .apple
        readAloud = ReadAloud(rawValue: defaults.string(forKey: AppPreferences.readAloudKey) ?? "") ?? .apple
        supertonicVoice = SupertonicVoice.clamped(defaults.integer(forKey: AppPreferences.supertonicVoiceKey))
    }

    func setAppearance(_ appearance: AppAppearance) {
        UserDefaults.standard.set(appearance.rawValue, forKey: AppPreferences.appearanceKey)
        self.appearance = appearance
    }

    func setLanguage(_ language: AppLanguage) {
        UserDefaults.standard.set(language.rawValue, forKey: AppPreferences.languageKey)
        languageCode = AppLanguage.resolved(preference: language.rawValue, system: Locale.current.identifier)
    }

    func setPageModel(_ role: ModelRole) {
        guard role.isTextModel else { return }
        UserDefaults.standard.set(role.rawValue, forKey: AppPreferences.pageModelKey)
        pageModel = role
    }

    func setSpeechEngine(_ engine: SpeechEngine) {
        UserDefaults.standard.set(engine.rawValue, forKey: AppPreferences.speechEngineKey)
        speechEngine = engine
    }

    func setReadAloud(_ voice: ReadAloud) {
        UserDefaults.standard.set(voice.rawValue, forKey: AppPreferences.readAloudKey)
        readAloud = voice
    }

    func setSupertonicVoice(_ voice: Int) {
        let clamped = SupertonicVoice.clamped(voice)
        UserDefaults.standard.set(clamped, forKey: AppPreferences.supertonicVoiceKey)
        supertonicVoice = clamped
    }

    var locale: Locale { Locale(identifier: languageCode) }
}
