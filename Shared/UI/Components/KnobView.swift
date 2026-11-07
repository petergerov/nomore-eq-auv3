// NoMore EQ — passive drawing of a bakelite pointer knob in a chrome collar.
import SwiftUI

/// A black bakelite pointer knob in a chrome collar, inside a cream scale
/// printed on the panel. The thin accent arc runs from `origin` to the value,
/// so bipolar controls light from their centre detent. Both are 0...1 over a
/// 270° sweep.
struct KnobView: View {
    let normalized: Double
    var origin: Double = 0
    @Environment(\.gear) private var theme

    private static let startAngle = -135.0 * .pi / 180.0
    private static let endAngle = 135.0 * .pi / 180.0

    private static func angle(_ fraction: Double) -> Double {
        startAngle + min(max(fraction, 0), 1) * (endAngle - startAngle)
    }

    var body: some View {
        let (theme, normalized, origin) = (theme, normalized, origin)
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2)
            let diameter = min(rect.width, rect.height)
            let radius = diameter / 2
            let centre = CGPoint(x: rect.midX, y: rect.midY)
            let angle = Self.angle(normalized)
            let unit = diameter / 78.0 // the design's reference knob size

            func point(_ a: Double, _ r: CGFloat) -> CGPoint {
                CGPoint(x: centre.x + CGFloat(sin(a)) * r, y: centre.y - CGFloat(cos(a)) * r)
            }

            // Scale printed on the panel around the knob.
            for i in 0..<11 {
                let tickAngle = Self.angle(Double(i) / 10.0)
                let major = i % 5 == 0
                var tick = Path()
                tick.move(to: point(tickAngle, radius * (major ? 0.80 : 0.86)))
                tick.addLine(to: point(tickAngle, radius * 0.97))
                context.stroke(tick,
                               with: .color(theme.textLight.opacity(major ? 0.9 : 0.55)),
                               lineWidth: (major ? 2.2 : 1.4) * unit)
            }

            // Value arc, from the origin detent to the pointer.
            let from = min(Self.angle(origin), angle), to = max(Self.angle(origin), angle)
            if to - from > 0.001 {
                var arc = Path()
                arc.addArc(center: centre, radius: radius * 0.885,
                           startAngle: .radians(from - .pi / 2),
                           endAngle: .radians(to - .pi / 2), clockwise: false)
                context.stroke(arc, with: .color(theme.accent.opacity(0.18)), lineWidth: 4.6 * unit)
                context.stroke(arc, with: .color(theme.accent.opacity(0.92)), lineWidth: 2.0 * unit)
            }

            // Chrome collar the knob is seated in.
            let collarR = radius * 0.74
            let collarBox = CGRect(x: centre.x - collarR, y: centre.y - collarR,
                                   width: collarR * 2, height: collarR * 2)
            context.fill(Path(ellipseIn: collarBox.offsetBy(dx: 0, dy: 2.6 * unit)),
                         with: .color(.black.opacity(0.45)))
            context.fill(Path(ellipseIn: collarBox), with: .linearGradient(
                Gradient(colors: [theme.metalLight, theme.metalMid, theme.metalDark, theme.metalMid]),
                startPoint: CGPoint(x: collarBox.minX, y: collarBox.minY),
                endPoint: CGPoint(x: collarBox.maxX, y: collarBox.maxY)))

            // Bakelite cap.
            let capR = collarR * 0.86
            let capBox = CGRect(x: centre.x - capR, y: centre.y - capR,
                                width: capR * 2, height: capR * 2)
            context.fill(Path(ellipseIn: capBox), with: .radialGradient(
                Gradient(colors: [theme.bakeliteLight, theme.bakeliteDark]),
                center: CGPoint(x: centre.x - capR * 0.4, y: centre.y - capR * 0.5),
                startRadius: 0, endRadius: capR * 1.5))
            context.stroke(Path(ellipseIn: capBox), with: .color(.black.opacity(0.7)),
                           lineWidth: 1.2 * unit)

            // Gloss on the moulded top surface.
            let gloss = CGRect(x: centre.x - capR * 0.62, y: centre.y - capR * 0.78,
                               width: capR * 1.05, height: capR * 0.62)
            context.fill(Path(ellipseIn: gloss), with: .radialGradient(
                Gradient(colors: [.white.opacity(0.20), .clear]),
                center: CGPoint(x: gloss.midX, y: gloss.midY),
                startRadius: 0, endRadius: gloss.width * 0.6))

            // Pointer, rotating with the value.
            var rotated = context
            rotated.translateBy(x: centre.x, y: centre.y)
            rotated.rotate(by: .radians(angle))
            rotated.translateBy(x: -centre.x, y: -centre.y)

            let pointerWidth = 3.4 * unit
            let pointer = CGRect(x: centre.x - pointerWidth / 2, y: centre.y - capR * 0.94,
                                 width: pointerWidth, height: capR * 0.94)
            rotated.fill(Path(roundedRect: pointer.offsetBy(dx: 0, dy: 1.2 * unit),
                              cornerRadius: pointerWidth / 2),
                         with: .color(.black.opacity(0.55)))
            rotated.fill(Path(roundedRect: pointer, cornerRadius: pointerWidth / 2),
                         with: .color(theme.textLight))
        }
    }
}
