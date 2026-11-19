import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class AppSession {
    var unlocked: Bool
    /// Face ID / passcode gate before notes. On by default; the student can turn it off in Settings.
    var lockEnabled: Bool
    /// The walkthrough ends once, after the first install. Deleting the app clears it.
    var welcomeSeen: Bool
    var languageCode: String
    var appearance: AppAppearance
    var typeface: AppTypeface
    var focusCourseToken: UUID?
    var focusLectureID: PersistentIdentifier?
    var showModelDownload = false
    /// What the Models page and the launch check last read from disk. `nil` until the first check.
    /// While it says a model is missing, every tab but Settings is off.
    var modelSetup: ModelSetup?
    var setupIncomplete: Bool { modelSetup?.shouldGuide == true }
    var focusedModel: ModelRole?
    /// The recording that is open now. The tab bar's bottom accessory shows its player.
    var player: LectureAudio?
    var resumeAfterInterruption = false
    var pageModel: ModelRole
    var supertonicVoice: Int

    init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: AppPreferences.lockEnabledKey) == nil {
            defaults.set(true, forKey: AppPreferences.lockEnabledKey)
        }
        let lock = defaults.bool(forKey: AppPreferences.lockEnabledKey)
        lockEnabled = lock
        unlocked = !lock
        welcomeSeen = defaults.bool(forKey: AppPreferences.welcomeSeenKey)
        let stored = defaults.string(forKey: AppPreferences.languageKey) ?? AppLanguage.system.rawValue
        languageCode = AppLanguage.resolved(preference: stored, system: Locale.current.identifier)
        let storedAppearance = defaults.string(forKey: AppPreferences.appearanceKey) ?? AppAppearance.system.rawValue
        appearance = AppAppearance(rawValue: storedAppearance) ?? .system
        let storedTypeface = defaults.string(forKey: AppPreferences.typefaceKey) ?? AppTypeface.sfPro.rawValue
        typeface = AppTypeface(rawValue: storedTypeface) ?? .sfPro
        pageModel = AppPreferences.pageModel(defaults)
        supertonicVoice = SupertonicVoice.clamped(defaults.integer(forKey: AppPreferences.supertonicVoiceKey))
    }

    func finishWelcome() {
        UserDefaults.standard.set(true, forKey: AppPreferences.welcomeSeenKey)
        welcomeSeen = true
    }

    func setAppearance(_ appearance: AppAppearance) {
        UserDefaults.standard.set(appearance.rawValue, forKey: AppPreferences.appearanceKey)
        self.appearance = appearance
    }

    func setTypeface(_ typeface: AppTypeface) {
        UserDefaults.standard.set(typeface.rawValue, forKey: AppPreferences.typefaceKey)
        self.typeface = typeface
    }

    func setLanguage(_ language: AppLanguage) {
        UserDefaults.standard.set(language.rawValue, forKey: AppPreferences.languageKey)
        languageCode = AppLanguage.resolved(preference: language.rawValue, system: Locale.current.identifier)
    }

    /// Turns the app lock on or off. Turning it off unlocks at once. Turning it on keeps this session open.
    func setLockEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: AppPreferences.lockEnabledKey)
        lockEnabled = enabled
        if !enabled {
            unlocked = true
        }
    }

    func setPageModel(_ role: ModelRole) {
        guard role.isTextModel else { return }
        UserDefaults.standard.set(role.rawValue, forKey: AppPreferences.pageModelKey)
        pageModel = role
    }

    func setSupertonicVoice(_ voice: Int) {
        let clamped = SupertonicVoice.clamped(voice)
        UserDefaults.standard.set(clamped, forKey: AppPreferences.supertonicVoiceKey)
        supertonicVoice = clamped
    }

    var locale: Locale { Locale(identifier: languageCode) }
}
