//
//  TerminalWindowFocuser.swift
//  ClaudeIsland
//
//  Activates the terminal app + window hosting a given Claude/Codex session
//  using native macOS APIs only — works for Ghostty, Terminal, iTerm2, Warp,
//  WezTerm, Alacritty, etc. No dependency on yabai or tmux.
//
//  Bringing another app's window forward from an accessory (LSUIElement) app
//  is unreliable with NSRunningApplication.activate alone, so we drive it
//  through the Accessibility API:
//    1. NSRunningApplication.activate() — best-effort app activation.
//    2. AX kAXFrontmostAttribute on the app element — the part that actually
//       brings the app forward from a background process.
//    3. AX kAXRaiseAction on the matching window (by title), falling back to
//       the app's main/focused window so a click always surfaces *something*.
//  Steps 2–3 require the user to grant Accessibility permission once.
//

import AppKit
import ApplicationServices
import os.log

private let logger = Logger(subsystem: "com.claudeisland", category: "WindowFocus")

@MainActor
final class TerminalWindowFocuser {
    static let shared = TerminalWindowFocuser()

    /// Have we already shown the Accessibility prompt this session?
    /// We only prompt once so we don't spam the user.
    private var didRequestAccessibility = false

    private init() {}

    /// Bring the terminal hosting this session to the front.
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

        // Modern activation API. `.activateIgnoringOtherApps` was deprecated in
        // macOS 14 and is unreliable when called from an accessory app.
        app.activate()
        logger.info("Activating terminal pid=\(terminalPid) (\(app.localizedName ?? "?", privacy: .public)) for session \(session.sessionId.prefix(8), privacy: .public)")

        // Raise the specific window via Accessibility — this is what actually
        // surfaces the right window; app activation alone often does nothing.
        raiseWindow(appPid: terminalPid, session: session)

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

        // Fallback: any running terminal — caller may at least get *a* terminal forward
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

        // Bring the app forward at the AX level. Reliable from a background app
        // in a way NSRunningApplication.activate() is not.
        AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)

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

        // Prefer the window whose title matches this session.
        if let matched = matchWindow(in: windows, session: session) {
            raise(matched)
            logger.info("Raised matching window for session \(session.sessionId.prefix(8), privacy: .public)")
            return
        }

        // No title match — surface the app's main/focused window, or the first
        // window. The user clicked "go to terminal" and expects *a* window to
        // come forward; raising none (the old behavior) looked like a no-op.
        if let fallback = focusedOrMainWindow(of: appElement) ?? windows.first {
            raise(fallback)
            logger.info("No title match — raised main/first window for session \(session.sessionId.prefix(8), privacy: .public)")
        }
    }

    /// Find the window whose title contains a session-identifying substring.
    /// Claude Code writes the session summary / first user message into the
    /// terminal window title via OSC 2; cwd basename is the last-ditch hint.
    private func matchWindow(in windows: [AXUIElement], session: SessionState) -> AXUIElement? {
        let candidates: [String] = [
            session.summary,
            session.firstUserMessage,
            session.displayTitle == session.projectName ? nil : session.displayTitle,
            URL(fileURLWithPath: session.cwd).lastPathComponent,
        ]
        .compactMap { $0 }
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

        guard !candidates.isEmpty else { return nil }

        let titledWindows: [(AXUIElement, String)] = windows.compactMap { window in
            guard let title = axTitle(of: window) else { return nil }
            return (window, title)
        }

        for candidate in candidates {
            // Window titles often carry a spinner glyph prefix the session
            // metadata doesn't have; substring matching tolerates that. Cap the
            // needle so we don't fail when Claude truncates a long title.
            let needle = String(candidate.prefix(50))
            for (window, title) in titledWindows where title.contains(needle) {
                return window
            }
        }
        return nil
    }

    /// The app's main window, or its focused window, if either is exposed.
    private func focusedOrMainWindow(of appElement: AXUIElement) -> AXUIElement? {
        for attribute in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appElement, attribute as CFString, &ref) == .success,
                  let value = ref,
                  CFGetTypeID(value) == AXUIElementGetTypeID() else { continue }
            return (value as! AXUIElement)
        }
        return nil
    }

    private func raise(_ window: AXUIElement) {
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
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
