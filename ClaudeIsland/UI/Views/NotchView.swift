//
//  NotchView.swift
//  ClaudeIsland
//
//  The main dynamic island SwiftUI view with accurate notch shape
//

import AppKit
import CoreGraphics
import SwiftUI

// Corner radius constants
private let cornerRadiusInsets = (
    opened: (top: CGFloat(19), bottom: CGFloat(24)),
    closed: (top: CGFloat(6), bottom: CGFloat(14))
)

struct NotchView: View {
    @ObservedObject var viewModel: NotchViewModel
    @StateObject private var sessionMonitor = ClaudeSessionMonitor()
    @ObservedObject private var updateManager = UpdateManager.shared
    @State private var previousAttentionIds: Set<String> = []
    @State private var isVisible: Bool = false
    @State private var isHovering: Bool = false
    @State private var isBouncing: Bool = false

    /// Cap on simultaneously rendered session crabs in the closed notch.
    /// Beyond this, overflow renders as `+N`.
    private let maxVisibleCrabs = 5

    /// Single crab footprint in the expansion strip (width + gap).
    /// ClaudeCrabIcon renders at width = size * 66/52, so size 18 ≈ 23pt.
    private let crabSize: CGFloat = 18
    private var crabWidth: CGFloat { crabSize * (66.0 / 52.0) }
    private let crabGap: CGFloat = 5

    /// Sessions worth showing as crabs (active or attention-needing only).
    /// Idle and ended sessions are filtered out — they have no informational
    /// value in the collapsed strip and would just take up width.
    private var renderableInstances: [SessionState] {
        sessionMonitor.instances
            .filter { phaseRank($0.phase) > 0 }
            .sorted { a, b in
                let pa = phaseRank(a.phase)
                let pb = phaseRank(b.phase)
                if pa != pb { return pa > pb }
                return a.createdAt > b.createdAt
            }
    }

    private var visibleInstances: [SessionState] {
        Array(renderableInstances.prefix(maxVisibleCrabs))
    }

    private var overflowCount: Int {
        max(0, renderableInstances.count - maxVisibleCrabs)
    }

    /// True when at least one renderable session exists.
    /// Drives whether the closed notch is visible at all — when every session
    /// is idle (or there are none), the notch hides entirely.
    private var hasAnySession: Bool {
        !renderableInstances.isEmpty
    }

    private func phaseRank(_ phase: SessionPhase) -> Int {
        switch phase {
        case .waitingForApproval: return 4
        case .waitingForInput: return 3
        case .processing, .compacting: return 2
        case .idle, .ended: return 0
        }
    }

    // MARK: - Sizing

    private var closedNotchSize: CGSize {
        CGSize(
            width: viewModel.deviceNotchRect.width,
            height: viewModel.deviceNotchRect.height
        )
    }

    /// Extra width on the right of the notch to host the per-session crab strip.
    /// Zero when no renderable session exists.
    private var expansionWidth: CGFloat {
        let visibleCount = visibleInstances.count
        guard visibleCount > 0 else { return 0 }

        let crabsBlock = CGFloat(visibleCount) * crabWidth + CGFloat(visibleCount - 1) * crabGap
        let overflowBlock: CGFloat = overflowCount > 0 ? crabGap + 24 : 0
        let horizontalPadding: CGFloat = 14

        return horizontalPadding + crabsBlock + overflowBlock
    }

    private var notchSize: CGSize {
        switch viewModel.status {
        case .closed, .popping:
            return closedNotchSize
        case .opened:
            return viewModel.openedSize
        }
    }

    // MARK: - Corner Radii

    private var topCornerRadius: CGFloat {
        viewModel.status == .opened
            ? cornerRadiusInsets.opened.top
            : cornerRadiusInsets.closed.top
    }

    private var bottomCornerRadius: CGFloat {
        viewModel.status == .opened
            ? cornerRadiusInsets.opened.bottom
            : cornerRadiusInsets.closed.bottom
    }

    private var currentNotchShape: NotchShape {
        NotchShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: bottomCornerRadius
        )
    }

    // Animation springs
    private let openAnimation = Animation.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
    private let closeAnimation = Animation.spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .top) {
            // Outer container does NOT receive hits - only the notch content does
            VStack(spacing: 0) {
                notchLayout
                    .frame(
                        maxWidth: viewModel.status == .opened ? notchSize.width : nil,
                        alignment: .top
                    )
                    .padding(
                        .horizontal,
                        viewModel.status == .opened
                            ? cornerRadiusInsets.opened.top
                            : cornerRadiusInsets.closed.bottom
                    )
                    .padding([.horizontal, .bottom], viewModel.status == .opened ? 12 : 0)
                    .background(.black)
                    .clipShape(currentNotchShape)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(.black)
                            .frame(height: 1)
                            .padding(.horizontal, topCornerRadius)
                    }
                    .shadow(
                        color: (viewModel.status == .opened || isHovering) ? .black.opacity(0.7) : .clear,
                        radius: 6
                    )
                    .frame(
                        maxWidth: viewModel.status == .opened ? notchSize.width : nil,
                        maxHeight: viewModel.status == .opened ? notchSize.height : nil,
                        alignment: .top
                    )
                    .animation(viewModel.status == .opened ? openAnimation : closeAnimation, value: viewModel.status)
                    .animation(openAnimation, value: notchSize)
                    .animation(.smooth, value: hasAnySession)
                    .animation(.smooth, value: visibleInstances.map(\.stableId))
                    .animation(.spring(response: 0.3, dampingFraction: 0.5), value: isBouncing)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
                            isHovering = hovering
                        }
                    }
                    .onTapGesture {
                        if viewModel.status != .opened {
                            viewModel.notchOpen(reason: .click)
                        }
                    }
            }
        }
        .opacity(isVisible ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
        .onAppear {
            sessionMonitor.startMonitoring()
            // On non-notched devices, keep visible so users have a target to interact with
            if !viewModel.hasPhysicalNotch {
                isVisible = true
            }
        }
        .onChange(of: viewModel.status) { oldStatus, newStatus in
            handleStatusChange(from: oldStatus, to: newStatus)
        }
        .onChange(of: sessionMonitor.instances) { _, instances in
            handleSessionRosterChange()
            handleAttentionChange(instances)
        }
    }

    // MARK: - Notch Layout

    @ViewBuilder
    private var notchLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
                .frame(height: max(24, closedNotchSize.height))

            if viewModel.status == .opened {
                contentView
                    .frame(width: notchSize.width - 24)
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.8, anchor: .top)
                                .combined(with: .opacity)
                                .animation(.smooth(duration: 0.35)),
                            removal: .opacity.animation(.easeOut(duration: 0.15))
                        )
                    )
            }
        }
    }

    // MARK: - Header Row

    @ViewBuilder
    private var headerRow: some View {
        if viewModel.status == .opened {
            openedHeader
        } else {
            closedHeader
        }
    }

    @ViewBuilder
    private var openedHeader: some View {
        HStack(spacing: 12) {
            ClaudeCrabIcon(size: 14)
                .padding(.leading, 8)
            Spacer()
            menuToggleButton
        }
        .frame(height: closedNotchSize.height)
    }

    /// Collapsed state: black bar matching the physical notch, with per-session
    /// pixel crabs floating in the expansion area to its right.
    @ViewBuilder
    private var closedHeader: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(.black)
                .frame(width: closedNotchSize.width - cornerRadiusInsets.closed.top + (isBouncing ? 16 : 0))

            if hasAnySession {
                sessionCrabStrip
                    .padding(.horizontal, 7)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .frame(height: closedNotchSize.height)
    }

    @ViewBuilder
    private var sessionCrabStrip: some View {
        HStack(spacing: crabGap) {
            ForEach(visibleInstances, id: \.stableId) { session in
                SessionCrabIcon(session: session)
                    .transition(.scale.combined(with: .opacity))
            }
            if overflowCount > 0 {
                Text("+\(overflowCount)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
                    .frame(minWidth: 20)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: visibleInstances.map(\.stableId))
        .animation(.easeInOut(duration: 0.22), value: overflowCount)
    }

    // MARK: - Menu Toggle Button

    @ViewBuilder
    private var menuToggleButton: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                viewModel.toggleMenu()
                if viewModel.contentType == .menu {
                    updateManager.markUpdateSeen()
                }
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: viewModel.contentType == .menu ? "xmark" : "line.3.horizontal")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())

                if updateManager.hasUnseenUpdate && viewModel.contentType != .menu {
                    Circle()
                        .fill(TerminalColors.green)
                        .frame(width: 6, height: 6)
                        .offset(x: -2, y: 2)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Content View (Opened State)

    @ViewBuilder
    private var contentView: some View {
        Group {
            switch viewModel.contentType {
            case .instances:
                ClaudeInstancesView(
                    sessionMonitor: sessionMonitor,
                    viewModel: viewModel
                )
            case .menu:
                NotchMenuView(viewModel: viewModel)
            case .chat(let session):
                ChatView(
                    sessionId: session.sessionId,
                    initialSession: session,
                    sessionMonitor: sessionMonitor,
                    viewModel: viewModel
                )
                // Force a fresh ChatView when switching sessions — otherwise
                // @State (history, session, scroll position) leaks from the
                // previous session and the view shows the wrong conversation.
                // Keyed on sessionId only (not the whole SessionState) so
                // per-event updates still reuse the view.
                .id(session.sessionId)
            }
        }
        .frame(width: notchSize.width - 24) // Fixed width to prevent text reflow
    }

    // MARK: - Event Handlers

    /// Drive notch visibility off "any session exists" instead of "processing".
    /// Each session is now self-describing via its dot, so any non-empty roster
    /// is reason enough to keep the notch on screen.
    private func handleSessionRosterChange() {
        if hasAnySession {
            isVisible = true
        } else if viewModel.status == .closed && viewModel.hasPhysicalNotch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if !hasAnySession && viewModel.status == .closed {
                    isVisible = false
                }
            }
        }
    }

    private func handleStatusChange(from oldStatus: NotchStatus, to newStatus: NotchStatus) {
        switch newStatus {
        case .opened, .popping:
            isVisible = true
        case .closed:
            guard viewModel.hasPhysicalNotch else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                if viewModel.status == .closed && !hasAnySession {
                    isVisible = false
                }
            }
        }
    }

    /// Auto-open the notch when a new session needs the user — approvals OR
    /// stop-and-wait-for-input. Suppressed while the terminal owning the
    /// session is already in focus on the active Space.
    private func handleAttentionChange(_ instances: [SessionState]) {
        let attentionSessions = instances.filter { $0.phase.needsAttention }
        let currentIds = Set(attentionSessions.map(\.stableId))
        let newIds = currentIds.subtracting(previousAttentionIds)

        if !newIds.isEmpty {
            let newlyAttentionSessions = attentionSessions.filter { newIds.contains($0.stableId) }

            if viewModel.status == .closed &&
               !TerminalVisibilityDetector.isTerminalVisibleOnCurrentSpace() {
                viewModel.notchOpen(reason: .notification)
            }

            if let soundName = AppSettings.notificationSound.soundName {
                Task {
                    let shouldPlay = await shouldPlayNotificationSound(for: newlyAttentionSessions)
                    if shouldPlay {
                        await MainActor.run {
                            NSSound(named: soundName)?.play()
                        }
                    }
                }
            }

            DispatchQueue.main.async {
                isBouncing = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    isBouncing = false
                }
            }
        }

        previousAttentionIds = currentIds
    }

    /// Determine if notification sound should play for the given sessions
    /// Returns true if ANY session is not actively focused
    private func shouldPlayNotificationSound(for sessions: [SessionState]) async -> Bool {
        for session in sessions {
            guard let pid = session.pid else {
                // No PID means we can't check focus, assume not focused
                return true
            }

            let isFocused = await TerminalVisibilityDetector.isSessionFocused(sessionPid: pid)
            if !isFocused {
                return true
            }
        }

        return false
    }
}
