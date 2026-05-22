//
//  AgentType.swift
//  ClaudeIsland
//
//  Which CLI agent a session belongs to. Sessions default to .claude so every
//  existing code path that doesn't read this field behaves exactly as before.
//

import Foundation

enum AgentType: String, Sendable, Equatable, CaseIterable {
    case claude
    case codex

    /// Human-readable name for UI.
    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    /// Short tag for compact UI (session rows, badges).
    var shortName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }
}
