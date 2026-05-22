//
//  Settings.swift
//  ClaudeIsland
//
//  App settings manager using UserDefaults
//

import Foundation

/// Available notification sounds
enum NotificationSound: String, CaseIterable {
    case none = "None"
    case pop = "Pop"
    case ping = "Ping"
    case tink = "Tink"
    case glass = "Glass"
    case blow = "Blow"
    case bottle = "Bottle"
    case frog = "Frog"
    case funk = "Funk"
    case hero = "Hero"
    case morse = "Morse"
    case purr = "Purr"
    case sosumi = "Sosumi"
    case submarine = "Submarine"
    case basso = "Basso"

    /// The system sound name to use with NSSound, or nil for no sound
    var soundName: String? {
        self == .none ? nil : rawValue
    }
}

enum AppSettings {
    private static let defaults = UserDefaults.standard

    // MARK: - Keys

    private enum Keys {
        static let notificationSound = "notificationSound"
        static let claudeDirectoryName = "claudeDirectoryName"
        static let codexMonitoringEnabled = "codexMonitoringEnabled"
        static let codexDirectoryName = "codexDirectoryName"
    }

    // MARK: - Notification Sound

    /// The sound to play when Claude finishes and is ready for input
    static var notificationSound: NotificationSound {
        get {
            guard let rawValue = defaults.string(forKey: Keys.notificationSound),
                  let sound = NotificationSound(rawValue: rawValue) else {
                return .pop // Default to Pop
            }
            return sound
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.notificationSound)
        }
    }

    // MARK: - Claude Directory

    /// The name of the Claude config directory under the user's home folder.
    /// Defaults to ".claude" (standard Claude Code installation).
    /// Change to ".claude-internal" (or similar) for enterprise/custom distributions.
    static var claudeDirectoryName: String {
        get {
            let value = defaults.string(forKey: Keys.claudeDirectoryName) ?? ""
            return value.isEmpty ? ".claude" : value
        }
        set {
            defaults.set(newValue.trimmingCharacters(in: .whitespaces), forKey: Keys.claudeDirectoryName)
        }
    }

    // MARK: - Codex

    /// Whether the app monitors OpenAI Codex CLI sessions.
    /// Defaults to false: until the user opts in, no Codex code path runs and
    /// nothing is written to ~/.codex.
    static var codexMonitoringEnabled: Bool {
        get { defaults.bool(forKey: Keys.codexMonitoringEnabled) }
        set { defaults.set(newValue, forKey: Keys.codexMonitoringEnabled) }
    }

    /// The Codex config directory under the user's home folder.
    /// Defaults to ".codex". Power users on a custom layout can set an absolute
    /// path or a directory name; CODEX_HOME also overrides this.
    static var codexDirectoryName: String {
        get {
            let value = defaults.string(forKey: Keys.codexDirectoryName) ?? ""
            return value.isEmpty ? ".codex" : value
        }
        set {
            defaults.set(newValue.trimmingCharacters(in: .whitespaces), forKey: Keys.codexDirectoryName)
        }
    }
}
