//
//  TerminalAppRegistry.swift
//  ClaudeIsland
//
//  Centralized registry of known terminal applications
//

import Foundation

/// Registry of known terminal application names and bundle identifiers
struct TerminalAppRegistry: Sendable {
    /// Terminal app names for process matching
    static let appNames: Set<String> = [
        "Terminal",
        "iTerm2",
        "iTerm",
        "Ghostty",
        "Alacritty",
        "kitty",
        "Hyper",
        "Warp",
        "WezTerm",
        "Tabby",
        "Rio",
        "Contour",
        "foot",
        "st",
        "urxvt",
        "xterm",
        "Code",           // VS Code
        "Code - Insiders",
        "Cursor",
        "Windsurf",
        "zed"
    ]

    /// Bundle identifiers for terminal apps (for window enumeration)
    static let bundleIdentifiers: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "io.alacritty",
        "org.alacritty",
        "net.kovidgoyal.kitty",
        "co.zeit.hyper",
        "dev.warp.Warp-Stable",
        "com.github.wez.wezterm",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92",  // Cursor
        "com.exafunction.windsurf",
        "dev.zed.Zed"
    ]

    /// Check if an app name or command path is a known terminal.
    ///
    /// Matching is word-boundary aware, not a plain substring test: the OpenAI
    /// Codex CLI's executable is `codex`, and a plain `contains("code")` (from
    /// the "Code" / VS Code entry) falsely flagged it as a terminal — which
    /// stopped the process-tree walk at the `codex` process instead of the
    /// real terminal app hosting it.
    static func isTerminal(_ appNameOrCommand: String) -> Bool {
        for name in appNames {
            if containsWord(appNameOrCommand, name) {
                return true
            }
        }
        return containsWord(appNameOrCommand, "terminal")
            || containsWord(appNameOrCommand, "iterm")
    }

    /// Case-insensitive search for `word` in `haystack` bounded by non-alphanumeric
    /// characters (or string ends), so `code` matches `Code.app` but not `codex`.
    private static func containsWord(_ haystack: String, _ word: String) -> Bool {
        guard !word.isEmpty else { return false }
        var searchStart = haystack.startIndex
        while let range = haystack.range(
            of: word,
            options: [.caseInsensitive],
            range: searchStart..<haystack.endIndex
        ) {
            let beforeOK = range.lowerBound == haystack.startIndex
                || !isWordChar(haystack[haystack.index(before: range.lowerBound)])
            let afterOK = range.upperBound == haystack.endIndex
                || !isWordChar(haystack[range.upperBound])
            if beforeOK && afterOK {
                return true
            }
            searchStart = range.upperBound
        }
        return false
    }

    private static func isWordChar(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    /// Check if a bundle identifier is a known terminal
    static func isTerminalBundle(_ bundleId: String) -> Bool {
        bundleIdentifiers.contains(bundleId)
    }
}
