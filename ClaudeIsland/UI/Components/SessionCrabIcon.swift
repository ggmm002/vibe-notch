//
//  SessionCrabIcon.swift
//  ClaudeIsland
//
//  Per-session pixel-art crab indicator. Wraps ClaudeCrabIcon and drives its
//  color + animation based on the session's phase:
//    - processing/compacting : brand-orange crab walking
//    - waitingForInput       : green crab, slow breathing pulse
//    - waitingForApproval    : amber crab, head-shake + tiny bounce (attention)
//    - idle / ended          : not rendered
//

import SwiftUI

struct SessionCrabIcon: View {
    let session: SessionState

    /// Body height of the crab. Final view width = size * 66/52 ≈ size * 1.27.
    private let size: CGFloat = 18

    @State private var sway: CGFloat = 0
    @State private var bounceY: CGFloat = 0
    @State private var pulseOpacity: Double = 1.0

    var body: some View {
        Group {
            if isHidden {
                EmptyView()
            } else {
                agentIcon
                .rotationEffect(.degrees(sway))
                .offset(y: bounceY)
                .opacity(pulseOpacity)
                .contentShape(Rectangle())
                .help(tooltip)
                .onAppear(perform: applyPhaseAnimation)
                .onChange(of: phaseKey) { _, _ in applyPhaseAnimation() }
                .onTapGesture {
                    TerminalWindowFocuser.shared.focus(session: session)
                }
            }
        }
    }

    /// Per-agent indicator: crab for Claude, robot for Codex. Both share the
    /// same init signature and footprint, so the crab strip layout is unaffected.
    @ViewBuilder
    private var agentIcon: some View {
        switch session.agentType {
        case .codex:
            CodexAgentIcon(size: size, color: tintColor, animateLegs: isWalking)
        case .claude:
            ClaudeCrabIcon(size: size, color: tintColor, animateLegs: isWalking)
        }
    }

    // MARK: - Phase mapping

    /// Equatable primitive for .onChange — SessionPhase has an associated value
    /// (PermissionContext) that we don't want to depend on here.
    private var phaseKey: String {
        switch session.phase {
        case .idle: return "idle"
        case .processing: return "processing"
        case .compacting: return "compacting"
        case .waitingForInput: return "waitingForInput"
        case .waitingForApproval: return "waitingForApproval"
        case .ended: return "ended"
        }
    }

    private var isHidden: Bool {
        switch session.phase {
        case .idle, .ended: return true
        default: return false
        }
    }

    private var tintColor: Color {
        switch session.phase {
        case .processing, .compacting:
            return TerminalColors.prompt
        case .waitingForApproval:
            return TerminalColors.amber
        case .waitingForInput:
            return TerminalColors.green
        case .idle, .ended:
            return .clear
        }
    }

    private var isWalking: Bool {
        switch session.phase {
        case .processing, .compacting: return true
        default: return false
        }
    }

    // MARK: - Animation

    private func applyPhaseAnimation() {
        // Snap any in-flight animation back to neutral with no transition,
        // then start the phase-appropriate loop.
        withTransaction(Transaction(animation: nil)) {
            sway = 0
            bounceY = 0
            pulseOpacity = 1.0
        }

        switch session.phase {
        case .waitingForApproval:
            withAnimation(.easeInOut(duration: 0.35).repeatForever(autoreverses: true)) {
                sway = 7
            }
            withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                bounceY = -1.5
            }
        case .waitingForInput:
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                pulseOpacity = 0.55
            }
        default:
            break
        }
    }

    // MARK: - Tooltip

    private var tooltip: String {
        let state: String
        switch session.phase {
        case .processing: state = "Processing"
        case .compacting: state = "Compacting"
        case .waitingForInput: state = "Ready for input"
        case .waitingForApproval(let ctx): state = "Needs approval: \(ctx.toolName)"
        case .idle: state = "Idle"
        case .ended: state = "Ended"
        }
        return "\(session.projectName) — \(state)"
    }
}
