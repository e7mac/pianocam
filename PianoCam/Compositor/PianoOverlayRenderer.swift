import CoreGraphics
import CoreImage
import Foundation

/// Renders the 88-key piano overlay as a `CIImage` of size (width, height)
/// for compositing onto camera frames. The visual style mirrors
/// `PianoKeyboardView`.
final class PianoOverlayRenderer {
    let width: Int
    let height: Int
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let firstNote: UInt8 = 21
    private let lastNote: UInt8 = 108
    private let whiteNotes: [UInt8]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        var notes: [UInt8] = []
        for n: UInt8 in 21...108 where [0, 2, 4, 5, 7, 9, 11].contains(Int(n % 12)) {
            notes.append(n)
        }
        self.whiteNotes = notes
    }

    func render(activeNotes: [UInt8: UInt8]) -> CIImage {
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return CIImage.empty() }

        // Core Image / CG coords: origin at bottom-left, Y increases up.
        // Piano top edge (felt) is at y = height; key fronts at y = 0.
        draw(ctx: ctx, activeNotes: activeNotes)

        guard let cg = ctx.makeImage() else { return CIImage.empty() }
        return CIImage(cgImage: cg)
    }

    private func draw(ctx: CGContext, activeNotes: [UInt8: UInt8]) {
        let size = CGSize(width: width, height: height)
        let feltHeight = max(2, size.height * 0.04)
        // Felt sits at top of view; in bottom-up coords that means high y.
        let feltRect = CGRect(x: 0, y: size.height - feltHeight, width: size.width, height: feltHeight)
        let keyboardRect = CGRect(x: 0, y: 0, width: size.width, height: size.height - feltHeight)

        // Background dark pad
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 0.55)
        ctx.fill(CGRect(origin: .zero, size: size))

        drawFelt(ctx: ctx, rect: feltRect)
        drawWhiteKeys(ctx: ctx, rect: keyboardRect, activeNotes: activeNotes)
        drawBlackKeys(ctx: ctx, rect: keyboardRect, activeNotes: activeNotes)
    }

    private func drawFelt(ctx: CGContext, rect: CGRect) {
        let dark = CGColor(red: 0.32, green: 0.02, blue: 0.04, alpha: 1)
        let mid = CGColor(red: 0.55, green: 0.05, blue: 0.08, alpha: 1)
        if let gradient = CGGradient(colorsSpace: colorSpace, colors: [dark, mid, dark] as CFArray, locations: [0, 0.5, 1]) {
            ctx.saveGState()
            ctx.clip(to: rect)
            ctx.drawLinearGradient(gradient,
                                   start: CGPoint(x: 0, y: rect.minY),
                                   end: CGPoint(x: 0, y: rect.maxY),
                                   options: [])
            ctx.restoreGState()
        }
        // Shadow line just below the felt
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 0.65)
        ctx.fill(CGRect(x: 0, y: rect.minY - 1, width: rect.width, height: 1))
    }

    private func drawWhiteKeys(ctx: CGContext, rect: CGRect, activeNotes: [UInt8: UInt8]) {
        let w = rect.width / CGFloat(whiteNotes.count)
        let radius: CGFloat = min(6, w * 0.18)

        for (i, note) in whiteNotes.enumerated() {
            let keyRect = CGRect(x: CGFloat(i) * w + 0.5, y: rect.minY,
                                 width: w - 1, height: rect.height)
            let path = CGPath(roundedRect: keyRect, cornerWidth: radius, cornerHeight: radius, transform: nil)

            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()

            if let velocity = activeNotes[note] {
                fillActiveWhite(ctx: ctx, rect: keyRect, velocity: velocity)
            } else {
                fillIdleWhite(ctx: ctx, rect: keyRect)
            }
            ctx.restoreGState()

            // Right-edge separator
            ctx.setStrokeColor(red: 0, green: 0, blue: 0, alpha: 0.18)
            ctx.setLineWidth(0.5)
            ctx.move(to: CGPoint(x: keyRect.maxX, y: keyRect.minY + radius))
            ctx.addLine(to: CGPoint(x: keyRect.maxX, y: keyRect.maxY))
            ctx.strokePath()

            // C-note label (CG y is up; place it near the front edge but well above the bottom).
            if note % 12 == 0 {
                let label = "C\(Int(note) / 12 - 1)" as NSString
                let fontSize = max(8, w * 0.5)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: CGFont("Helvetica" as CFString) as Any,
                    .foregroundColor: CGColor(red: 0.45, green: 0.45, blue: 0.45, alpha: 1)
                ]
                _ = attrs
                drawLabel(ctx: ctx,
                          text: label as String,
                          centerX: keyRect.midX,
                          y: keyRect.minY + fontSize * 0.6,
                          fontSize: fontSize)
            }
        }
    }

    private func drawLabel(ctx: CGContext, text: String, centerX: CGFloat, y: CGFloat, fontSize: CGFloat) {
        // Use CTLine for proper centering.
        let attrString = NSAttributedString(
            string: text,
            attributes: [
                .font: CTFontCreateWithName("Helvetica" as CFString, fontSize, nil),
                .foregroundColor: CGColor(red: 0.45, green: 0.45, blue: 0.45, alpha: 1)
            ]
        )
        let line = CTLineCreateWithAttributedString(attrString)
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        ctx.textPosition = CGPoint(x: centerX - bounds.width / 2 - bounds.minX, y: y)
        CTLineDraw(line, ctx)
    }

    private func fillIdleWhite(ctx: CGContext, rect: CGRect) {
        let top = CGColor(red: 0.99, green: 0.99, blue: 0.99, alpha: 1)
        let mid = CGColor(red: 0.96, green: 0.96, blue: 0.96, alpha: 1)
        let bottom = CGColor(red: 0.88, green: 0.88, blue: 0.88, alpha: 1)
        if let g = CGGradient(colorsSpace: colorSpace,
                              colors: [top, mid, bottom] as CFArray,
                              locations: [0, 0.45, 1]) {
            // CG y goes up — top of the visual key is rect.maxY.
            ctx.drawLinearGradient(g,
                                   start: CGPoint(x: rect.midX, y: rect.maxY),
                                   end: CGPoint(x: rect.midX, y: rect.minY),
                                   options: [])
        }
        // Front lip (visual bottom)
        let lipH = max(2, rect.height * 0.06)
        let lipRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: lipH)
        if let g = CGGradient(colorsSpace: colorSpace,
                              colors: [
                                CGColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1),
                                CGColor(red: 0.78, green: 0.78, blue: 0.78, alpha: 1)
                              ] as CFArray,
                              locations: [0, 1]) {
            ctx.drawLinearGradient(g,
                                   start: CGPoint(x: 0, y: lipRect.maxY),
                                   end: CGPoint(x: 0, y: lipRect.minY),
                                   options: [])
        }
    }

    private func fillActiveWhite(ctx: CGContext, rect: CGRect, velocity: UInt8) {
        let intensity = CGFloat(velocity) / 127.0
        let glow = CGColor(red: 0.35 + 0.25 * intensity,
                           green: 0.75 + 0.20 * intensity,
                           blue: 1.0, alpha: 1)
        let deeper = CGColor(red: 0.18 + 0.20 * intensity,
                             green: 0.55 + 0.25 * intensity,
                             blue: 0.92, alpha: 1)
        if let g = CGGradient(colorsSpace: colorSpace,
                              colors: [glow, deeper] as CFArray,
                              locations: [0, 1]) {
            ctx.drawLinearGradient(g,
                                   start: CGPoint(x: rect.midX, y: rect.maxY),
                                   end: CGPoint(x: rect.midX, y: rect.minY),
                                   options: [])
        }
        // Inner top shadow
        let shadowH = rect.height * 0.12
        let shadowRect = CGRect(x: rect.minX, y: rect.maxY - shadowH, width: rect.width, height: shadowH)
        if let g = CGGradient(colorsSpace: colorSpace,
                              colors: [
                                CGColor(red: 0, green: 0, blue: 0, alpha: 0.35),
                                CGColor(red: 0, green: 0, blue: 0, alpha: 0)
                              ] as CFArray,
                              locations: [0, 1]) {
            ctx.drawLinearGradient(g,
                                   start: CGPoint(x: 0, y: shadowRect.maxY),
                                   end: CGPoint(x: 0, y: shadowRect.minY),
                                   options: [])
        }
    }

    private func drawBlackKeys(ctx: CGContext, rect: CGRect, activeNotes: [UInt8: UInt8]) {
        let whiteW = rect.width / CGFloat(whiteNotes.count)
        let blackW = whiteW * 0.62
        let blackH = rect.height * 0.5
        let radius = min(3.5, blackW * 0.22)

        for (i, note) in whiteNotes.enumerated() where i + 1 < whiteNotes.count {
            let next = whiteNotes[i + 1]
            guard next - note == 2 else { continue }
            let blackNote = note + 1
            let centerX = CGFloat(i + 1) * whiteW
            // Visual top of the keyboard is rect.maxY in bottom-up coords.
            let keyRect = CGRect(x: centerX - blackW / 2,
                                 y: rect.maxY - blackH,
                                 width: blackW,
                                 height: blackH)

            // Drop shadow on the keybed
            ctx.saveGState()
            let shadowRect = keyRect.offsetBy(dx: 0, dy: -1).insetBy(dx: -0.5, dy: 0)
            ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 0.35)
            ctx.addPath(CGPath(roundedRect: shadowRect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.fillPath()
            ctx.restoreGState()

            ctx.saveGState()
            let path = CGPath(roundedRect: keyRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            ctx.addPath(path)
            ctx.clip()

            if let velocity = activeNotes[blackNote] {
                fillActiveBlack(ctx: ctx, rect: keyRect, velocity: velocity)
            } else {
                fillIdleBlack(ctx: ctx, rect: keyRect)
            }
            ctx.restoreGState()

            // Specular highlight near the back (visual top = rect.maxY)
            let hlH = max(0.8, blackH * 0.015)
            let hl = CGRect(x: keyRect.minX + blackW * 0.12,
                            y: keyRect.maxY - 1 - hlH,
                            width: blackW * 0.76,
                            height: hlH)
            ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 0.18)
            ctx.fill(hl)
        }
    }

    private func fillIdleBlack(ctx: CGContext, rect: CGRect) {
        let top = CGColor(red: 0.20, green: 0.20, blue: 0.20, alpha: 1)
        let mid = CGColor(red: 0.10, green: 0.10, blue: 0.10, alpha: 1)
        let bottom = CGColor(red: 0.04, green: 0.04, blue: 0.04, alpha: 1)
        if let g = CGGradient(colorsSpace: colorSpace,
                              colors: [top, mid, bottom] as CFArray,
                              locations: [0, 0.45, 1]) {
            ctx.drawLinearGradient(g,
                                   start: CGPoint(x: rect.midX, y: rect.maxY),
                                   end: CGPoint(x: rect.midX, y: rect.minY),
                                   options: [])
        }
        // Front lip (bottom in visual = rect.minY in CG)
        let lipH = max(1.5, rect.height * 0.07)
        ctx.setFillColor(red: 0.22, green: 0.22, blue: 0.22, alpha: 1)
        ctx.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: lipH))
    }

    private func fillActiveBlack(ctx: CGContext, rect: CGRect, velocity: UInt8) {
        let intensity = CGFloat(velocity) / 127.0
        let glow = CGColor(red: 0.20 + 0.30 * intensity,
                           green: 0.65 + 0.30 * intensity,
                           blue: 1.0, alpha: 1)
        let deeper = CGColor(red: 0.08 + 0.18 * intensity,
                             green: 0.30 + 0.30 * intensity,
                             blue: 0.70, alpha: 1)
        if let g = CGGradient(colorsSpace: colorSpace,
                              colors: [glow, deeper] as CFArray,
                              locations: [0, 1]) {
            ctx.drawLinearGradient(g,
                                   start: CGPoint(x: rect.midX, y: rect.maxY),
                                   end: CGPoint(x: rect.midX, y: rect.minY),
                                   options: [])
        }
    }
}
