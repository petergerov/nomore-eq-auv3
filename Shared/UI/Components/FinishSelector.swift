// NoMore EQ — the panel-finish selector: a small rotary switch that turns to the next colourway.
import SwiftUI

/// The cap is painted in the fitted finish and the pointer stands at that
/// finish's detent. Clicking turns it to the next finish.
struct FinishSelector: View {
    @Environment(\.gear) private var theme
    @State private var taps = 0

    private var finishes: [GearPalette] { GearPalette.all }
    private var index: Int { finishes.firstIndex { $0.id == theme.id } ?? 0 }

    var body: some View {
        Button {
            ThemeStore.shared.selectNext()
            taps += 1
        } label: {
            FinishSelectorDrawing(theme: theme, count: finishes.count, index: index)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Panel finish: \(theme.name)")
        .accessibilityLabel("Panel finish")
        .accessibilityValue(theme.name)
        .accessibilityHint("Switches the panel colourway")
        .tapFeedback(taps)
    }
}

private struct FinishSelectorDrawing: View {
    let theme: GearPalette
    let count: Int
    let index: Int

    /// Detents spread over a 70° arc, centred.
    private static func detentAngle(_ i: Int, of count: Int) -> Double {
        let steps = max(1, count - 1)
        return (-35 + Double(i) / Double(steps) * 70) * .pi / 180
    }

    var body: some View {
        let (theme, count, index) = (theme, count, index)
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            let centre = CGPoint(x: rect.midX, y: rect.midY)
            let radius = min(rect.width, rect.height) / 2

            func point(_ a: Double, _ r: CGFloat) -> CGPoint {
                CGPoint(x: centre.x + CGFloat(sin(a)) * r, y: centre.y - CGFloat(cos(a)) * r)
            }

            // Detent marks printed on the panel, one per finish.
            for i in 0..<count {
                let a = Self.detentAngle(i, of: count)
                var tick = Path()
                tick.move(to: point(a, radius * 0.82))
                tick.addLine(to: point(a, radius * 0.99))
                context.stroke(tick, with: .color(theme.textLight.opacity(i == index ? 0.9 : 0.45)),
                               lineWidth: 1.4)
            }

            // Chrome bezel.
            let bezelR = radius * 0.74
            let bezel = CGRect(x: centre.x - bezelR, y: centre.y - bezelR,
                               width: bezelR * 2, height: bezelR * 2)
            context.fill(Path(ellipseIn: bezel.offsetBy(dx: 0, dy: 1.4)),
                         with: .color(.black.opacity(0.45)))
            context.fill(Path(ellipseIn: bezel), with: .linearGradient(
                Gradient(colors: [theme.metalLight, theme.metalMid, theme.metalDark]),
                startPoint: CGPoint(x: bezel.minX, y: bezel.minY),
                endPoint: CGPoint(x: bezel.maxX, y: bezel.maxY)))

            // Cap painted in the fitted finish, so it doubles as a swatch.
            let capR = bezelR * 0.78
            let cap = CGRect(x: centre.x - capR, y: centre.y - capR,
                             width: capR * 2, height: capR * 2)
            context.fill(Path(ellipseIn: cap), with: .linearGradient(
                Gradient(colors: [theme.paintTop, theme.paintBottom]),
                startPoint: CGPoint(x: cap.midX, y: cap.minY),
                endPoint: CGPoint(x: cap.midX, y: cap.maxY)))
            context.stroke(Path(ellipseIn: cap), with: .color(.black.opacity(0.55)), lineWidth: 0.8)

            // Pointer standing at the fitted finish's detent.
            var rotated = context
            rotated.translateBy(x: centre.x, y: centre.y)
            rotated.rotate(by: .radians(Self.detentAngle(index, of: count)))
            rotated.translateBy(x: -centre.x, y: -centre.y)
            let width: CGFloat = 2.0
            let pointer = CGRect(x: centre.x - width / 2, y: centre.y - capR * 0.92,
                                 width: width, height: capR * 0.92)
            rotated.fill(Path(roundedRect: pointer, cornerRadius: width / 2),
                         with: .color(theme.textLight))

            // Gloss.
            context.fill(Path(ellipseIn: CGRect(x: centre.x - capR * 0.55, y: centre.y - capR * 0.72,
                                                 width: capR * 0.9, height: capR * 0.5)),
                         with: .radialGradient(
                            Gradient(colors: [.white.opacity(0.22), .clear]),
                            center: CGPoint(x: centre.x - capR * 0.1, y: centre.y - capR * 0.47),
                            startRadius: 0, endRadius: capR * 0.6))
        }
    }
}
