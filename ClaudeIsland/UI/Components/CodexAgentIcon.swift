//
//  CodexAgentIcon.swift
//  ClaudeIsland
//
//  Pixel-art robot indicator for Codex sessions — the Codex counterpart to
//  ClaudeCrabIcon. Same init signature and footprint (width = size * 66/52)
//  so SessionCrabIcon can swap the two without affecting layout.
//
//  A blocky robot head: a single top antenna, two eyes, a mouth slit, and two
//  legs that animate up/down to mirror the crab's "walking" cue.
//

import Combine
import SwiftUI

struct CodexAgentIcon: View {
    let size: CGFloat
    let color: Color
    var animateLegs: Bool = false

    @State private var legPhase: Int = 0

    private let legTimer = Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()

    init(size: CGFloat = 16,
         color: Color = Color(red: 0.35, green: 0.62, blue: 0.95),
         animateLegs: Bool = false) {
        self.size = size
        self.color = color
        self.animateLegs = animateLegs
    }

    var body: some View {
        Canvas { context, canvasSize in
            // Coordinate space matches ClaudeCrabIcon: 66 wide x 52 tall.
            let scale = size / 52.0
            let xOffset = (canvasSize.width - 66 * scale) / 2
            let transform = CGAffineTransform(scaleX: scale, y: scale)
                .translatedBy(x: xOffset / scale, y: 0)

            func fill(_ rect: CGRect, _ fillColor: Color) {
                context.fill(Path(rect).applying(transform), with: .color(fillColor))
            }

            // Antenna: stalk + bulb, centered (viewBox center x = 33).
            fill(CGRect(x: 29, y: 0, width: 8, height: 6), color)
            fill(CGRect(x: 31, y: 6, width: 4, height: 6), color)

            // Head — baseline y=39 matches the crab so the strip aligns.
            fill(CGRect(x: 9, y: 12, width: 48, height: 27), color)

            // Eyes (cut-out black, like the crab's eyes).
            fill(CGRect(x: 18, y: 20, width: 9, height: 9), .black)
            fill(CGRect(x: 39, y: 20, width: 9, height: 9), .black)

            // Mouth slit.
            fill(CGRect(x: 21, y: 32, width: 24, height: 3), .black)

            // Two legs that animate up/down for the "working" cue.
            let legHeightOffsets: [[CGFloat]] = [
                [3, -3],   // Phase 0
                [0, 0],    // Phase 1
                [-3, 3],   // Phase 2
                [0, 0],    // Phase 3
            ]
            let offsets = animateLegs
                ? legHeightOffsets[legPhase % 4]
                : [CGFloat](repeating: 0, count: 2)
            let legXs: [CGFloat] = [18, 40]
            for (index, legX) in legXs.enumerated() {
                fill(CGRect(x: legX, y: 39, width: 8, height: 11 + offsets[index]), color)
            }
        }
        .frame(width: size * (66.0 / 52.0), height: size)
        .onReceive(legTimer) { _ in
            if animateLegs {
                legPhase = (legPhase + 1) % 4
            }
        }
    }
}
