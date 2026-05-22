//
//  CodexHookInstaller.swift
//  ClaudeIsland
//
//  Installs Vibe Notch hooks for OpenAI Codex CLI.
//
//  Isolation guarantees (see codex-mvp-plan.md):
//  - Opt-in: does nothing — touches no files, probes no binaries — unless
//    AppSettings.codexMonitoringEnabled is true.
//  - Never writes to ~/.claude. Only ever touches ~/.codex/hooks.json and
//    ~/.codex/hooks/codex-hook.py.
//  - Writes a standalone hooks.json rather than editing the user's
//    config.toml, so the user's core Codex config is never modified.
//

import Foundation

struct CodexHookInstaller {

    /// Codex hook events Vibe Notch registers. Tool events take a "*" matcher;
    /// the rest take no matcher (matches all).
    private static let matchedEvents = ["PreToolUse", "PermissionRequest", "PostToolUse"]
    private static let unmatchedEvents = ["SessionStart", "UserPromptSubmit", "Stop"]

    /// Install hook script + hooks.json, but only when Codex monitoring is
    /// enabled and Codex is actually present. Safe to call on every launch.
    static func installIfNeeded() {
        guard AppSettings.codexMonitoringEnabled else { return }
        guard codexIsInstalled() else { return }

        let hooksDir = CodexPaths.hooksDir
        try? FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)

        let script = hooksDir.appendingPathComponent("codex-hook.py")
        if let bundled = Bundle.main.url(forResource: "codex-hook", withExtension: "py") {
            try? FileManager.default.removeItem(at: script)
            try? FileManager.default.copyItem(at: bundled, to: script)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: script.path
            )
        }

        var json = readHooksConfig()
        var hooks = stripOwnEntries(from: json["hooks"] as? [String: Any] ?? [:])

        let python = detectPython()
        let command = "\(python) \(CodexPaths.hookScriptShellPath)"
        let hookEntry: [[String: Any]] = [["type": "command", "command": command]]
        let withMatcher: [[String: Any]] = [["matcher": "*", "hooks": hookEntry]]
        let withoutMatcher: [[String: Any]] = [["hooks": hookEntry]]

        for event in matchedEvents {
            var existing = hooks[event] as? [[String: Any]] ?? []
            existing.append(contentsOf: withMatcher)
            hooks[event] = existing
        }
        for event in unmatchedEvents {
            var existing = hooks[event] as? [[String: Any]] ?? []
            existing.append(contentsOf: withoutMatcher)
            hooks[event] = existing
        }

        json["hooks"] = hooks
        writeHooksConfig(json)
    }

    /// Remove only Vibe Notch's hook entries from hooks.json, leaving any other
    /// hooks the user configured intact. Called when the user disables Codex
    /// monitoring so codex-hook.py stops being spawned.
    static func uninstall() {
        let url = CodexPaths.hooksConfigFile
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        var json = readHooksConfig()
        let hooks = stripOwnEntries(from: json["hooks"] as? [String: Any] ?? [:])
        if hooks.isEmpty {
            json.removeValue(forKey: "hooks")
        } else {
            json["hooks"] = hooks
        }
        writeHooksConfig(json)
    }

    // MARK: - hooks.json read/write

    private static func readHooksConfig() -> [String: Any] {
        guard let data = try? Data(contentsOf: CodexPaths.hooksConfigFile),
              let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return existing
    }

    private static func writeHooksConfig(_ json: [String: Any]) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? data.write(to: CodexPaths.hooksConfigFile)
    }

    /// Drop every matcher entry whose command points at codex-hook.py, across
    /// all event types. Identifies our entries by script name so re-running the
    /// installer is idempotent and never duplicates entries.
    private static func stripOwnEntries(from hooks: [String: Any]) -> [String: Any] {
        var cleaned: [String: Any] = [:]
        for (event, value) in hooks {
            guard let matchers = value as? [[String: Any]] else {
                cleaned[event] = value
                continue
            }
            let kept = matchers.filter { matcher in
                guard let entries = matcher["hooks"] as? [[String: Any]] else { return true }
                return !entries.contains {
                    ($0["command"] as? String)?.contains("codex-hook.py") == true
                }
            }
            if !kept.isEmpty {
                cleaned[event] = kept
            }
        }
        return cleaned
    }

    // MARK: - Detection

    /// True when Codex looks installed — either ~/.codex exists or a `codex`
    /// binary is on a known path. Avoids creating a ~/.codex tree for users who
    /// don't have Codex.
    private static func codexIsInstalled() -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: CodexPaths.codexDir.path) { return true }
        let candidates = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            NSHomeDirectory() + "/.local/bin/codex",
            NSHomeDirectory() + "/.npm-global/bin/codex",
            "/usr/bin/codex",
        ]
        return candidates.contains { fm.fileExists(atPath: $0) }
    }

    private static func detectPython() -> String {
        let candidates = [
            "/usr/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            return path
        }
        return "/usr/bin/python3"
    }
}
