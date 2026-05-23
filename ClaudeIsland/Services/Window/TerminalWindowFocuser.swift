//
//  TerminalWindowFocuser.swift
//  ClaudeIsland
//
//  Activates the terminal app + window hosting a given Claude/Codex session
//  using native macOS APIs only — works for Ghostty, Terminal, iTerm2, Warp,
//  WezTerm, Alacritty, etc. No dependency on yabai or tmux.
//
//  Bringing a specific window of another app forward from an accessory
//  (LSUIElement) app is done through the Accessibility API:
//    1. Enumerate the terminal app's AX windows.
//    2. Pick the window whose title uniquely identifies this session.
//    3. Raise + focus that window, then NSRunningApplication.activate() so the
//       raised window becomes key.
//  Steps 1–3 require the user to grant Accessibility permission once.
//

import AppKit
import ApplicationServices
import os.log

private let logger = Logger(subsystem: "com.claudeisland", category: "WindowFocus")

@MainActor
final class TerminalWindowFocuser {
    static let shared = TerminalWindowFocuser()

    /// Have we already shown the Accessibility prompt this session?
    private var didRequestAccessibility = false

    private init() {}

    /// Bring the terminal window hosting this session to the front.
    /// - Returns: true if a terminal app was resolved and activation attempted.
    @discardableResult
    func focus(session: SessionState) -> Bool {
        guard let terminalPid = resolveTerminalPid(for: session) else {
            logger.warning("Could not resolve terminal PID for session \(session.sessionId.prefix(8), privacy: .public)")
            return false
        }

        guard let app = NSRunningApplication(processIdentifier: pid_t(terminalPid)) else {
            logger.warning("NSRunningApplication lookup failed for pid \(terminalPid)")
            return false
        }

        // Raise the specific window first (Accessibility), then activate the
        // app so the just-raised window becomes key. `.activateIgnoringOtherApps`
        // was deprecated in macOS 14 and is unreliable from an accessory app.
        raiseWindow(appPid: terminalPid, session: session)
        app.activate()
        logger.info("Activated terminal pid=\(terminalPid) (\(app.localizedName ?? "?", privacy: .public)) for session \(session.sessionId.prefix(8), privacy: .public)")

        return true
    }

    // MARK: - Process tree resolution

    /// Walk from the CLI's PID up the process tree to find the terminal app PID.
    /// Falls back to any running terminal if we have no PID at all.
    private func resolveTerminalPid(for session: SessionState) -> Int? {
        if let claudePid = session.pid {
            let tree = ProcessTreeBuilder.shared.buildTree()
            if let terminalPid = ProcessTreeBuilder.shared.findTerminalPid(
                forProcess: claudePid,
                tree: tree
            ) {
                return terminalPid
            }
        }

        for app in NSWorkspace.shared.runningApplications {
            if let bundleId = app.bundleIdentifier,
               TerminalAppRegistry.isTerminalBundle(bundleId) {
                return Int(app.processIdentifier)
            }
        }

        return nil
    }

    // MARK: - Window raising via Accessibility

    private func raiseWindow(appPid: Int, session: SessionState) {
        guard ensureAccessibility() else {
            logger.info("Accessibility not granted — app activation only")
            return
        }

        let appElement = AXUIElementCreateApplication(pid_t(appPid))

        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &windowsRef
        )
        guard result == .success, let windows = windowsRef as? [AXUIElement], !windows.isEmpty else {
            logger.warning("AX windows enumeration failed for pid \(appPid): \(result.rawValue)")
            return
        }

        guard let target = matchWindow(in: windows, session: session) else {
            // Deliberately raise nothing when we can't uniquely identify the
            // window — raising an arbitrary one yanks the user to an unrelated
            // session. App activation in focus() still brings the app forward.
            logger.warning("No unique window match for session \(session.sessionId.prefix(8), privacy: .public)")
            return
        }

        AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(target, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(target, kAXRaiseAction as CFString)
        logger.info("Raised window for session \(session.sessionId.prefix(8), privacy: .public)")
    }

    /// Find the AX window that uniquely identifies this session by title.
    ///
    /// Claude Code / Codex write a session identifier into the terminal window
    /// title (via OSC 2). Titles are often truncated, so matching is done in
    /// both directions and a candidate is only accepted when it matches exactly
    /// one window — never guess between same-titled windows.
    private func matchWindow(in windows: [AXUIElement], session: SessionState) -> AXUIElement? {
        // Most-specific first. cwd basename is last: every session in the same
        // project shares it, so it only helps when it isolates one window.
        let candidates: [String] = [
            session.summary,
            session.firstUserMessage,
            session.displayTitle == session.projectName ? nil : session.displayTitle,
            URL(fileURLWithPath: session.cwd).lastPathComponent,
        ]
        .compactMap { $0 }
        .map { normalize($0) }
        .filter { $0.count >= 4 }

        let titled: [(window: AXUIElement, title: String)] = windows.compactMap { window in
            guard let raw = axTitle(of: window) else { return nil }
            let cleaned = normalize(stripLeadingGlyphs(raw))
            guard !cleaned.isEmpty else { return nil }
            return (window, cleaned)
        }
        guard !titled.isEmpty else { return nil }

        for candidate in candidates {
            let hits = titled.filter { titlesOverlap($0.title, candidate) }
            if hits.count == 1 {
                return hits[0].window
            }
        }
        return nil
    }

    /// True when two normalized strings plausibly name the same session,
    /// tolerating the title truncation terminals apply.
    private func titlesOverlap(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let shorter = a.count <= b.count ? a : b
        let longer = a.count <= b.count ? b : a
        guard shorter.count >= 4 else { return false }
        return longer.hasPrefix(shorter) || longer.contains(shorter)
    }

    /// Lowercase + collapse runs of whitespace, so titles and metadata compare
    /// cleanly regardless of spacing.
    private func normalize(_ string: String) -> String {
        string.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Drop leading non-alphanumeric characters — terminal titles carry a
    /// spinner glyph prefix ("✳ ", "⠙ ") that session metadata doesn't have.
    private func stripLeadingGlyphs(_ string: String) -> String {
        var chars = Substring(string)
        while let first = chars.first, !first.isLetter, !first.isNumber {
            chars = chars.dropFirst()
        }
        return String(chars)
    }

    /// Returns whether Accessibility is granted, prompting once per app session.
    private func ensureAccessibility() -> Bool {
        if didRequestAccessibility {
            return AXIsProcessTrusted()
        }
        didRequestAccessibility = true
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    }

    private func axTitle(of window: AXUIElement) -> String? {
        var titleRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
        guard result == .success else { return nil }
        return titleRef as? String
    }
}
