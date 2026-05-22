//
//  CodexPaths.swift
//  ClaudeIsland
//
//  Single source of truth for OpenAI Codex CLI config directory paths.
//  Mirrors ClaudePaths but resolves ~/.codex. Kept separate so nothing here
//  can affect Claude path resolution.
//
//  Resolution order:
//  1. CODEX_HOME environment variable (if set and exists)
//  2. AppSettings.codexDirectoryName override (if changed from default)
//  3. ~/.codex/ (standard Codex CLI install)
//

import Foundation

enum CodexPaths {

    private static var _cachedDir: URL?
    private static let cacheLock = NSLock()

    /// Root Codex config directory, resolved once and cached.
    static var codexDir: URL {
        cacheLock.lock()
        if let cached = _cachedDir {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let resolved = resolveCodexDir()

        cacheLock.lock()
        if let existing = _cachedDir {
            cacheLock.unlock()
            return existing
        }
        _cachedDir = resolved
        cacheLock.unlock()
        return resolved
    }

    static var hooksDir: URL {
        codexDir.appendingPathComponent("hooks")
    }

    /// Codex loads lifecycle hooks from a standalone hooks.json next to
    /// config.toml. Using this file (rather than editing config.toml) keeps us
    /// from ever touching the user's core Codex config.
    static var hooksConfigFile: URL {
        codexDir.appendingPathComponent("hooks.json")
    }

    /// Shell-safe absolute path for the hook command written into hooks.json.
    static var hookScriptShellPath: String {
        shellQuote(codexDir.appendingPathComponent("hooks/codex-hook.py").path)
    }

    /// Invalidate the cached directory so the next access re-resolves.
    /// Call after the user changes AppSettings.codexDirectoryName.
    static func invalidateCache() {
        cacheLock.lock()
        _cachedDir = nil
        cacheLock.unlock()
    }

    private static func resolveCodexDir() -> URL {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        // 1. CODEX_HOME env var takes highest priority
        if let envDir = Foundation.ProcessInfo.processInfo.environment["CODEX_HOME"] {
            let expanded = (envDir as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            if fm.fileExists(atPath: url.path) {
                return url
            }
        }

        // 2. User override via settings — absolute path or directory name under ~/
        let settingsValue = AppSettings.codexDirectoryName
        if !settingsValue.isEmpty && settingsValue != ".codex" {
            if settingsValue.hasPrefix("/") {
                return URL(fileURLWithPath: settingsValue)
            } else {
                return home.appendingPathComponent(settingsValue)
            }
        }

        // 3. Standard install
        return home.appendingPathComponent(".codex")
    }

    private static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
