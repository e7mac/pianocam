//
//  PianoOverlay.swift
//
//  Shared between the host app and the camera extension.
//  Pure CG, no SwiftUI / AppKit deps.
//

import CoreGraphics
import Foundation

// MARK: - PianoOverlay (inlined; will be extracted to a shared file in a later step)

enum PianoOverlay {
    static func draw(into ctx: CGContext,
                     rect: CGRect,
                     heightFraction: CGFloat = 0.30,
                     activeNotes: [UInt8: UInt8] = [:],
                     sustainDown: Bool = false) {
        let h = rect.height * heightFraction
        // Small safe-area margin so the bottom of the pedal isn't flush to
        // the frame edge (some video apps crop a few pixels of the bottom).
        let bottomMargin = max(2, rect.height * 0.012)
        let frame = CGRect(x: rect.minX, y: rect.minY + bottomMargin,
                           width: rect.width, height: h - bottomMargin)
        let cs = CGColorSpaceCreateDeviceRGB()

        // Vertical layout, top to bottom (visually): felt, keyboard, pedal area.
        // CG coords are bottom-up, so build from bottom: pedal -> keyboard -> felt.
        let pedalH = frame.height * 0.18
        let feltH  = max(2, frame.height * 0.04)
        let pedal    = CGRect(x: frame.minX, y: frame.minY,
                              width: frame.width, height: pedalH)
        let keyboard = CGRect(x: frame.minX, y: pedal.maxY,
                              width: frame.width, height: frame.height - pedalH - feltH)
        let felt     = CGRect(x: frame.minX, y: keyboard.maxY,
                              width: frame.width, height: feltH)

        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 0.55)
        ctx.fill(frame)
        drawFelt(ctx: ctx, rect: felt, cs: cs)
        drawWhiteKeys(ctx: ctx, rect: keyboard, cs: cs, active: activeNotes)
        drawBlackKeys(ctx: ctx, rect: keyboard, cs: cs, active: activeNotes)
        drawPedal(ctx: ctx, rect: pedal, cs: cs, sustainDown: sustainDown)
    }

    private static let whiteNotes: [UInt8] = {
        var v: [UInt8] = []
        for n: UInt8 in 21...108 where [0,2,4,5,7,9,11].contains(Int(n % 12)) { v.append(n) }
        return v
    }()

    /// Three pedals (una corda, sostenuto, sustain) drawn below the keyboard.
    /// Only the sustain pedal animates from MIDI right now.
    private static func drawPedal(ctx: CGContext, rect: CGRect, cs: CGColorSpace, sustainDown: Bool) {
        // Dark floor under the pedal lyre.
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 0.6)
        ctx.fill(rect)

        // Centered cluster of 3 pedals occupying ~12% of the frame width.
        let clusterW = rect.width * 0.12
        let pedalSpacing = clusterW / 3
        let cx = rect.midX
        let positions: [CGFloat] = [
            cx - pedalSpacing,   // una corda (soft)
            cx,                  // sostenuto
            cx + pedalSpacing,   // sustain
        ]
        let active = [false, false, sustainDown]

        for (i, x) in positions.enumerated() {
            drawSinglePedal(ctx: ctx, rect: rect, cs: cs, centerX: x,
                            spacing: pedalSpacing, depressed: active[i])
        }
    }

    private static func drawSinglePedal(ctx: CGContext,
                                        rect: CGRect,
                                        cs: CGColorSpace,
                                        centerX: CGFloat,
                                        spacing: CGFloat,
                                        depressed: Bool) {
        // Post (vertical brass rod from floor up to the pad)
        let postW = max(1.5, spacing * 0.07)
        let postBottom = rect.minY + rect.height * 0.08
        let postTop    = rect.minY + rect.height * 0.65
        let postRect = CGRect(x: centerX - postW / 2,
                              y: postBottom,
                              width: postW,
                              height: postTop - postBottom)
        let postLight = CGColor(red: 0.55, green: 0.50, blue: 0.40, alpha: 1)
        let postDark  = CGColor(red: 0.20, green: 0.18, blue: 0.14, alpha: 1)
        if let g = CGGradient(colorsSpace: cs, colors: [postLight, postDark, postLight] as CFArray, locations: [0, 0.5, 1]) {
            ctx.saveGState()
            ctx.clip(to: postRect)
            ctx.drawLinearGradient(g,
                                   start: CGPoint(x: postRect.minX, y: postRect.midY),
                                   end: CGPoint(x: postRect.maxX, y: postRect.midY),
                                   options: [])
            ctx.restoreGState()
        }

        // Pad — brass paddle. When depressed, translate downward (no rotation
        // so it can't escape the pedal area).
        let padW = spacing * 0.78
        let padH = max(4, rect.height * 0.20)
        let depressOffset: CGFloat = depressed ? -rect.height * 0.10 : 0
        let padCenterY = postTop + padH * 0.05 + depressOffset
        let padRect = CGRect(x: centerX - padW / 2,
                             y: padCenterY - padH / 2,
                             width: padW,
                             height: padH)
        let cornerR = padH * 0.30
        let pad = CGPath(roundedRect: padRect, cornerWidth: cornerR, cornerHeight: cornerR, transform: nil)

        // Drop shadow under the pad.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1.5), blur: 4,
                      color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.8))
        ctx.setFillColor(CGColor(red: 0.30, green: 0.25, blue: 0.16, alpha: 1))
        ctx.addPath(pad)
        ctx.fillPath()
        ctx.restoreGState()

        // Brass body gradient.
        let brassTop = CGColor(red: 0.95, green: 0.78, blue: 0.32, alpha: 1)
        let brassMid = CGColor(red: 0.78, green: 0.55, blue: 0.16, alpha: 1)
        let brassBot = CGColor(red: 0.45, green: 0.30, blue: 0.10, alpha: 1)
        if let g = CGGradient(colorsSpace: cs,
                              colors: [brassTop, brassMid, brassBot] as CFArray,
                              locations: [0, 0.55, 1]) {
            ctx.saveGState()
            ctx.addPath(pad)
            ctx.clip()
            ctx.drawLinearGradient(g,
                                   start: CGPoint(x: 0, y: padRect.maxY),
                                   end: CGPoint(x: 0, y: padRect.minY),
                                   options: [])
            ctx.restoreGState()
        }

        // Specular highlight strip.
        let hl = CGRect(x: padRect.minX + padW * 0.08,
                        y: padRect.maxY - padH * 0.18,
                        width: padW * 0.84,
                        height: max(0.6, padH * 0.08))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 0.9, alpha: 0.55))
        ctx.fill(hl)

        // Glow ring when this pedal is engaged.
        if depressed {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 10,
                          color: CGColor(red: 0.45, green: 0.85, blue: 1.0, alpha: 0.95))
            ctx.setStrokeColor(CGColor(red: 0.5, green: 0.9, blue: 1, alpha: 0.95))
            ctx.setLineWidth(1.2)
            ctx.addPath(pad)
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    private static func drawFelt(ctx: CGContext, rect: CGRect, cs: CGColorSpace) {
        let dark = CGColor(red: 0.32, green: 0.02, blue: 0.04, alpha: 1)
        let mid  = CGColor(red: 0.55, green: 0.05, blue: 0.08, alpha: 1)
        if let g = CGGradient(colorsSpace: cs, colors: [dark, mid, dark] as CFArray, locations: [0, 0.5, 1]) {
            ctx.saveGState(); ctx.clip(to: rect)
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.maxY), options: [])
            ctx.restoreGState()
        }
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 0.65)
        ctx.fill(CGRect(x: rect.minX, y: rect.minY - 1, width: rect.width, height: 1))
    }

    private static func drawWhiteKeys(ctx: CGContext, rect: CGRect, cs: CGColorSpace, active: [UInt8: UInt8]) {
        let w = rect.width / CGFloat(whiteNotes.count)
        let radius = min(6, w * 0.18)
        for (i, note) in whiteNotes.enumerated() {
            let r = CGRect(x: rect.minX + CGFloat(i) * w + 0.5, y: rect.minY, width: w - 1, height: rect.height)
            let path = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
            ctx.saveGState(); ctx.addPath(path); ctx.clip()
            if let v = active[note] { fillActiveWhite(ctx: ctx, rect: r, cs: cs, velocity: v) }
            else { fillIdleWhite(ctx: ctx, rect: r, cs: cs) }
            ctx.restoreGState()
            ctx.setStrokeColor(red: 0, green: 0, blue: 0, alpha: 0.18); ctx.setLineWidth(0.5)
            ctx.move(to: CGPoint(x: r.maxX, y: r.minY + radius))
            ctx.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            ctx.strokePath()
        }
    }

    private static func fillIdleWhite(ctx: CGContext, rect: CGRect, cs: CGColorSpace) {
        let top = CGColor(red: 0.99, green: 0.99, blue: 0.99, alpha: 1)
        let mid = CGColor(red: 0.96, green: 0.96, blue: 0.96, alpha: 1)
        let bot = CGColor(red: 0.88, green: 0.88, blue: 0.88, alpha: 1)
        if let g = CGGradient(colorsSpace: cs, colors: [top, mid, bot] as CFArray, locations: [0, 0.45, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
        }
    }

    private static func fillActiveWhite(ctx: CGContext, rect: CGRect, cs: CGColorSpace, velocity: UInt8) {
        // Brightness scales 0.25 (whisper) → 1.0 (fortissimo) with a floor so
        // soft notes are still visible.
        let i = CGFloat(velocity) / 127.0
        let scale = 0.25 + 0.75 * i
        let glow   = CGColor(red: 0.45 * scale + 0.10, green: 0.85 * scale + 0.10, blue: scale * 0.95 + 0.05, alpha: 1)
        let deeper = CGColor(red: 0.10 * scale,         green: 0.40 * scale + 0.05, blue: 0.85 * scale,         alpha: 1)
        if let g = CGGradient(colorsSpace: cs, colors: [glow, deeper] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
        }
    }

    private static func drawBlackKeys(ctx: CGContext, rect: CGRect, cs: CGColorSpace, active: [UInt8: UInt8]) {
        let whiteW = rect.width / CGFloat(whiteNotes.count)
        let blackW = whiteW * 0.62
        let blackH = rect.height * 0.65
        let radius = min(3.5, blackW * 0.22)
        for (i, note) in whiteNotes.enumerated() where i + 1 < whiteNotes.count {
            let next = whiteNotes[i + 1]
            guard next - note == 2 else { continue }
            let blackNote = note + 1
            let centerX = rect.minX + CGFloat(i + 1) * whiteW
            let r = CGRect(x: centerX - blackW / 2, y: rect.maxY - blackH, width: blackW, height: blackH)
            ctx.saveGState()
            let s = r.offsetBy(dx: 0, dy: -1).insetBy(dx: -0.5, dy: 0)
            ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 0.35)
            ctx.addPath(CGPath(roundedRect: s, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.fillPath()
            ctx.restoreGState()
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.clip()
            if let v = active[blackNote] { fillActiveBlack(ctx: ctx, rect: r, cs: cs, velocity: v) }
            else { fillIdleBlack(ctx: ctx, rect: r, cs: cs) }
            ctx.restoreGState()
        }
    }

    private static func fillIdleBlack(ctx: CGContext, rect: CGRect, cs: CGColorSpace) {
        let top = CGColor(red: 0.20, green: 0.20, blue: 0.20, alpha: 1)
        let mid = CGColor(red: 0.10, green: 0.10, blue: 0.10, alpha: 1)
        let bot = CGColor(red: 0.04, green: 0.04, blue: 0.04, alpha: 1)
        if let g = CGGradient(colorsSpace: cs, colors: [top, mid, bot] as CFArray, locations: [0, 0.45, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
        }
    }

    private static func fillActiveBlack(ctx: CGContext, rect: CGRect, cs: CGColorSpace, velocity: UInt8) {
        let i = CGFloat(velocity) / 127.0
        let scale = 0.25 + 0.75 * i
        let glow   = CGColor(red: 0.30 * scale + 0.05, green: 0.75 * scale + 0.05, blue: scale * 0.95 + 0.05, alpha: 1)
        let deeper = CGColor(red: 0.06 * scale,         green: 0.25 * scale,         blue: 0.65 * scale,         alpha: 1)
        if let g = CGGradient(colorsSpace: cs, colors: [glow, deeper] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
        }
    }
}
