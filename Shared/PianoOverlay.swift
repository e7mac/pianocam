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
    static func draw(into ctx: CGContext, rect: CGRect, heightFraction: CGFloat = 0.25, activeNotes: [UInt8: UInt8] = [:]) {
        let h = rect.height * heightFraction
        let frame = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: h)
        let cs = CGColorSpaceCreateDeviceRGB()
        let feltH = max(2, frame.height * 0.04)
        let keyboard = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height - feltH)
        let felt = CGRect(x: frame.minX, y: keyboard.maxY, width: frame.width, height: feltH)
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 0.55)
        ctx.fill(frame)
        drawFelt(ctx: ctx, rect: felt, cs: cs)
        drawWhiteKeys(ctx: ctx, rect: keyboard, cs: cs, active: activeNotes)
        drawBlackKeys(ctx: ctx, rect: keyboard, cs: cs, active: activeNotes)
    }

    private static let whiteNotes: [UInt8] = {
        var v: [UInt8] = []
        for n: UInt8 in 21...108 where [0,2,4,5,7,9,11].contains(Int(n % 12)) { v.append(n) }
        return v
    }()

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
        let blackH = rect.height * 0.5
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
