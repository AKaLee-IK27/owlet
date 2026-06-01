import Foundation
import os.log

/// User-facing settings, persisted to UserDefaults. Single source of truth
/// for the hotkey chord, the Ollama model name, and the launch-at-login flag.
/// Posts `Preferences.changedNotification` (with a `Change` value in
/// userInfo["change"]) whenever a setter mutates the underlying defaults.
///
/// Use `Preferences.shared` from production code; tests inject a custom
/// `UserDefaults` suite via the designated initialiser.
final class Preferences: @unchecked Sendable {

    enum Change: String { case hotkey, model, launchAtLogin, visionModel, autocompleteEnabled, autocompleteModel }

    static let changedNotification = Notification.Name("OwletPreferencesChanged")
    static let shared = Preferences(defaults: .standard)

    private static let logger = Logger(subsystem: "co.greenpassport.owlet", category: "preferences")

    private let defaults: UserDefaults

    private enum Key {
        static let hotkey         = "hotkey"
        static let model          = "model"
        static let launchAtLogin        = "launchAtLogin"
        static let visionModel          = "visionModel"
        static let autocompleteEnabled = "autocompleteEnabled"
        static let autocompleteModel   = "autocompleteModel"
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var hotkey: Chord {
        get {
            guard let data = defaults.data(forKey: Key.hotkey) else { return .default }
            do {
                return try JSONDecoder().decode(Chord.self, from: data)
            } catch {
                Self.logger.warning("Stored hotkey failed to decode (\(error.localizedDescription, privacy: .public)); falling back to default")
                return .default
            }
        }
        set {
            do {
                let data = try JSONEncoder().encode(newValue)
                defaults.set(data, forKey: Key.hotkey)
                post(.hotkey)
            } catch {
                Self.logger.error("Failed to encode hotkey for persistence: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    var model: String {
        get { defaults.string(forKey: Key.model) ?? "qwen2.5:1.5b" }
        set {
            defaults.set(newValue, forKey: Key.model)
            post(.model)
        }
    }

    /// Default is `true`: preserves the v0.2 behaviour (where
    /// `AppDelegate` called `LoginItemManager.registerIfNeeded()` on every
    /// launch). If a stored value exists, return it as-is.
    var launchAtLogin: Bool {
        get {
            if defaults.object(forKey: Key.launchAtLogin) == nil { return true }
            return defaults.bool(forKey: Key.launchAtLogin)
        }
        set {
            defaults.set(newValue, forKey: Key.launchAtLogin)
            post(.launchAtLogin)
        }
    }

    var visionModel: String {
        get { defaults.string(forKey: Key.visionModel) ?? "llava:7b" }
        set {
            defaults.set(newValue, forKey: Key.visionModel)
            post(.visionModel)
        }
    }

    var autocompleteEnabled: Bool {
        get { defaults.bool(forKey: Key.autocompleteEnabled) } // default false
        set {
            defaults.set(newValue, forKey: Key.autocompleteEnabled)
            post(.autocompleteEnabled)
        }
    }

    var autocompleteModel: String {
        get { defaults.string(forKey: Key.autocompleteModel) ?? "qwen2.5:1.5b" }
        set {
            defaults.set(newValue, forKey: Key.autocompleteModel)
            post(.autocompleteModel)
        }
    }

    private func post(_ change: Change) {
        NotificationCenter.default.post(
            name: Self.changedNotification,
            object: self,
            userInfo: ["change": change]
        )
    }
}
