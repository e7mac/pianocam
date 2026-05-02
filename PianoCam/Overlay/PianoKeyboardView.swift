import SwiftUI

/// 88-key piano keyboard, MIDI notes 21 (A0) → 108 (C8).
///
/// Layout: a dark felt strip at the top, then white keys with a subtle gradient
/// and rounded front, with black keys layered on top using a 3D-feeling
/// bevel. Pressed keys get a velocity-scaled glow tint.
struct PianoKeyboardView: View {
    let activeVelocities: [UInt8: UInt8]

    private static let firstNote: UInt8 = 21
    private static let lastNote: UInt8 = 108

    var body: some View {
        Canvas { ctx, size in
            draw(ctx: &ctx, size: size)
        }
        .background(Color.black.opacity(0.55))
        .clipped()
        .allowsHitTesting(false)
    }

    // MARK: - Drawing

    private func draw(ctx: inout GraphicsContext, size: CGSize) {
        let feltHeight = max(2, size.height * 0.04)
        let keyboardRect = CGRect(
            x: 0,
            y: feltHeight,
            width: size.width,
            height: size.height - feltHeight
        )

        drawFelt(ctx: &ctx, size: size, feltHeight: feltHeight)
        drawWhiteKeys(ctx: &ctx, rect: keyboardRect)
        drawBlackKeys(ctx: &ctx, rect: keyboardRect)
    }

    private func drawFelt(ctx: inout GraphicsContext, size: CGSize, feltHeight: CGFloat) {
        let feltRect = CGRect(x: 0, y: 0, width: size.width, height: feltHeight)
        let felt = Color(red: 0.55, green: 0.05, blue: 0.08)
        let feltDark = Color(red: 0.32, green: 0.02, blue: 0.04)
        let gradient = Gradient(colors: [feltDark, felt, feltDark])
        ctx.fill(
            Path(feltRect),
            with: .linearGradient(
                gradient,
                startPoint: CGPoint(x: 0, y: 0),
                endPoint: CGPoint(x: 0, y: feltHeight)
            )
        )
        // Bottom edge shadow under the felt
        let shadowH: CGFloat = 1
        ctx.fill(
            Path(CGRect(x: 0, y: feltHeight, width: size.width, height: shadowH)),
            with: .color(.black.opacity(0.65))
        )
    }

    private func drawWhiteKeys(ctx: inout GraphicsContext, rect: CGRect) {
        let whites = Self.whiteNotes
        let w = rect.width / CGFloat(whites.count)
        let radius: CGFloat = min(6, w * 0.18)

        for (i, note) in whites.enumerated() {
            let keyRect = CGRect(
                x: rect.minX + CGFloat(i) * w,
                y: rect.minY,
                width: w,
                height: rect.height
            )
            // Inset slightly so adjacent keys show as separate.
            let drawRect = keyRect.insetBy(dx: 0.5, dy: 0)
            let path = Path(roundedRect: drawRect,
                            cornerSize: CGSize(width: radius, height: radius),
                            style: .continuous)

            let velocity = activeVelocities[note]

            // Base body
            if let velocity {
                fillActiveWhite(ctx: &ctx, path: path, rect: drawRect, velocity: velocity)
            } else {
                fillIdleWhite(ctx: &ctx, path: path, rect: drawRect)
            }

            // Subtle separator line on right edge
            let sepX = drawRect.maxX
            ctx.stroke(
                Path { p in
                    p.move(to: CGPoint(x: sepX, y: drawRect.minY))
                    p.addLine(to: CGPoint(x: sepX, y: drawRect.maxY - radius))
                },
                with: .color(.black.opacity(0.18)),
                lineWidth: 0.5
            )

            // C-note label, sitting well above the front edge so it doesn't
            // get clipped by the window.
            if note % 12 == 0 {
                let label = "C\(Int(note) / 12 - 1)"
                let fontSize = max(8, w * 0.5)
                let text = Text(label)
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundColor(Color(white: 0.45))
                let labelY = drawRect.maxY - fontSize * 1.4
                ctx.draw(
                    text,
                    at: CGPoint(x: drawRect.midX, y: labelY),
                    anchor: .center
                )
            }
        }
    }

    private func fillIdleWhite(ctx: inout GraphicsContext, path: Path, rect: CGRect) {
        // Vertical gradient: brighter near top, slightly cooler near bottom.
        let top = Color(white: 0.99)
        let mid = Color(white: 0.96)
        let bottom = Color(white: 0.88)
        ctx.fill(
            path,
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: top, location: 0),
                    .init(color: mid, location: 0.55),
                    .init(color: bottom, location: 1)
                ]),
                startPoint: CGPoint(x: rect.midX, y: rect.minY),
                endPoint: CGPoint(x: rect.midX, y: rect.maxY)
            )
        )
        // Front edge highlight
        let frontH = max(2, rect.height * 0.06)
        let frontRect = CGRect(x: rect.minX, y: rect.maxY - frontH, width: rect.width, height: frontH)
        ctx.fill(
            Path(frontRect),
            with: .linearGradient(
                Gradient(colors: [Color(white: 0.78), Color(white: 0.95)]),
                startPoint: CGPoint(x: 0, y: frontRect.minY),
                endPoint: CGPoint(x: 0, y: frontRect.maxY)
            )
        )
    }

    private func fillActiveWhite(ctx: inout GraphicsContext, path: Path, rect: CGRect, velocity: UInt8) {
        let intensity = CGFloat(velocity) / 127.0
        let glow = Color(
            red: 0.35 + 0.25 * intensity,
            green: 0.75 + 0.20 * intensity,
            blue: 1.0
        )
        let deeper = Color(
            red: 0.18 + 0.20 * intensity,
            green: 0.55 + 0.25 * intensity,
            blue: 0.92
        )
        ctx.fill(
            path,
            with: .linearGradient(
                Gradient(colors: [glow, deeper]),
                startPoint: CGPoint(x: rect.midX, y: rect.minY),
                endPoint: CGPoint(x: rect.midX, y: rect.maxY)
            )
        )
        // Inner top shadow for "pressed" feel
        let shadow = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * 0.12)
        ctx.fill(
            Path(shadow),
            with: .linearGradient(
                Gradient(colors: [Color.black.opacity(0.35), .clear]),
                startPoint: CGPoint(x: 0, y: shadow.minY),
                endPoint: CGPoint(x: 0, y: shadow.maxY)
            )
        )
    }

    private func drawBlackKeys(ctx: inout GraphicsContext, rect: CGRect) {
        let whites = Self.whiteNotes
        let whiteW = rect.width / CGFloat(whites.count)
        let blackW = whiteW * 0.62
        let blackH = rect.height * 0.5
        let radius = min(3.5, blackW * 0.22)

        for (i, note) in whites.enumerated() where i + 1 < whites.count {
            let next = whites[i + 1]
            guard next - note == 2 else { continue }
            let blackNote = note + 1

            let centerX = rect.minX + CGFloat(i + 1) * whiteW
            let keyRect = CGRect(
                x: centerX - blackW / 2,
                y: rect.minY,
                width: blackW,
                height: blackH
            )

            // Drop shadow on the keybed below the black key
            let shadowRect = keyRect.offsetBy(dx: 0, dy: 1).insetBy(dx: -0.5, dy: 0)
            ctx.fill(
                Path(roundedRect: shadowRect,
                     cornerSize: CGSize(width: radius, height: radius),
                     style: .continuous),
                with: .color(.black.opacity(0.35))
            )

            let path = Path(roundedRect: keyRect,
                            cornerSize: CGSize(width: radius, height: radius),
                            style: .continuous)

            if let velocity = activeVelocities[blackNote] {
                fillActiveBlack(ctx: &ctx, path: path, rect: keyRect, velocity: velocity)
            } else {
                fillIdleBlack(ctx: &ctx, path: path, rect: keyRect)
            }

            // Top highlight (specular line near the back of the key)
            let hl = CGRect(
                x: keyRect.minX + blackW * 0.12,
                y: keyRect.minY + 1,
                width: blackW * 0.76,
                height: max(0.8, blackH * 0.015)
            )
            ctx.fill(
                Path(roundedRect: hl, cornerSize: CGSize(width: 0.5, height: 0.5)),
                with: .color(.white.opacity(0.18))
            )
        }
    }

    private func fillIdleBlack(ctx: inout GraphicsContext, path: Path, rect: CGRect) {
        let top = Color(white: 0.20)
        let mid = Color(white: 0.10)
        let bottom = Color(white: 0.04)
        ctx.fill(
            path,
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: top, location: 0),
                    .init(color: mid, location: 0.55),
                    .init(color: bottom, location: 1)
                ]),
                startPoint: CGPoint(x: rect.midX, y: rect.minY),
                endPoint: CGPoint(x: rect.midX, y: rect.maxY)
            )
        )
        // Front lip — slightly lighter than the body
        let lipH = max(1.5, rect.height * 0.07)
        let lipRect = CGRect(x: rect.minX, y: rect.maxY - lipH, width: rect.width, height: lipH)
        ctx.fill(
            Path(lipRect),
            with: .color(Color(white: 0.22))
        )
    }

    private func fillActiveBlack(ctx: inout GraphicsContext, path: Path, rect: CGRect, velocity: UInt8) {
        let intensity = CGFloat(velocity) / 127.0
        let glow = Color(
            red: 0.20 + 0.30 * intensity,
            green: 0.65 + 0.30 * intensity,
            blue: 1.0
        )
        let deeper = Color(
            red: 0.08 + 0.18 * intensity,
            green: 0.30 + 0.30 * intensity,
            blue: 0.70
        )
        ctx.fill(
            path,
            with: .linearGradient(
                Gradient(colors: [glow, deeper]),
                startPoint: CGPoint(x: rect.midX, y: rect.minY),
                endPoint: CGPoint(x: rect.midX, y: rect.maxY)
            )
        )
        // Subtle inner top shadow
        let shadow = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * 0.14)
        ctx.fill(
            Path(shadow),
            with: .linearGradient(
                Gradient(colors: [Color.black.opacity(0.4), .clear]),
                startPoint: CGPoint(x: 0, y: shadow.minY),
                endPoint: CGPoint(x: 0, y: shadow.maxY)
            )
        )
    }

    /// All white-key MIDI notes from 21 (A0) to 108 (C8).
    private static let whiteNotes: [UInt8] = {
        var notes: [UInt8] = []
        for n in firstNote...lastNote {
            let pc = n % 12
            if [0, 2, 4, 5, 7, 9, 11].contains(Int(pc)) {
                notes.append(n)
            }
        }
        return notes
    }()
}
