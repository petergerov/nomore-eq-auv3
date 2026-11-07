// NoMore EQ — live band levels and the gain curve the EQ is applying, as a scope behind smoked glass.
import SwiftUI

struct ResponseView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var meters: BandMeters
    @Environment(\.gear) private var theme

    private static let minHz: Double = 20, maxHz: Double = 20000, rangeDb: Double = 12

    var body: some View {
        let theme = theme
        let freqs = meters.frequencies.map(Double.init)
        let gains = meters.gains.map(Double.init)
        let levels = meters.levels.map(Double.init)
        let lowHz = Double(model.value("lowFreq")), highHz = Double(model.value("highFreq"))
        let brighten = Double(model.value("brighten")) / 100
        let brightenText = model.display("brighten")

        Canvas { context, size in
            let pad: CGFloat = 8
            let plot = CGRect(x: pad, y: pad, width: size.width - pad * 2, height: size.height - pad * 2)
            guard plot.width > 0, plot.height > 0 else { return }
            func x(_ hz: Double) -> CGFloat {
                plot.minX + plot.width * CGFloat(log(hz / Self.minHz) / log(Self.maxHz / Self.minHz))
            }
            func y(_ db: Double) -> CGFloat {
                plot.midY - plot.height / 2 * CGFloat(max(-Self.rangeDb, min(Self.rangeDb, db)) / Self.rangeDb)
            }
            let labelFont = Font.system(size: 8, weight: .semibold, design: .monospaced)
            let grid = theme.ledText.opacity(0.09)

            // Brighten guide: the tilt drawn straight from the knob, so it moves
            // even while no audio is running (the trace only updates on render).
            func drawBrightenGuide(_ context: inout GraphicsContext) {
                guard abs(brighten) >= 0.005 else { return }
                let steps = 96
                var guide = Path()
                for i in 0...steps {
                    let hz = Self.minHz * pow(Self.maxHz / Self.minHz, Double(i) / Double(steps))
                    let point = CGPoint(x: x(hz), y: y(Self.brightenTiltDb(hz: hz, brighten: brighten)))
                    if i == 0 { guide.move(to: point) } else { guide.addLine(to: point) }
                }
                context.stroke(guide, with: .color(theme.textLight.opacity(0.75)),
                               style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [4, 3]))

                // Pivot at 1 kHz, where the tilt is always 0 dB.
                let pivot = CGPoint(x: x(Self.brightenPivotHz), y: y(0))
                context.fill(Path(ellipseIn: CGRect(x: pivot.x - 2.5, y: pivot.y - 2.5, width: 5, height: 5)),
                             with: .color(theme.textLight.opacity(0.9)))

                // Label at the bright end, on the side away from the line.
                let endY = y(Self.brightenTiltDb(hz: Self.maxHz, brighten: brighten))
                context.draw(Text("TILT \(brightenText)").font(labelFont)
                                .foregroundColor(theme.textLight.opacity(0.8)),
                             at: CGPoint(x: plot.maxX - 4, y: endY + (brighten > 0 ? 9 : -9)),
                             anchor: .trailing)
            }

            // Graticule, etched into the glass.
            for hz in [50.0, 100, 200, 500, 1000, 2000, 5000, 10000] {
                var line = Path()
                line.move(to: CGPoint(x: x(hz), y: plot.minY))
                line.addLine(to: CGPoint(x: x(hz), y: plot.maxY))
                context.stroke(line, with: .color(grid), lineWidth: 1)
                let label = hz >= 1000 ? "\(Int(hz / 1000))k" : "\(Int(hz))"
                context.draw(Text(label).font(labelFont).foregroundColor(theme.ledText.opacity(0.45)),
                             at: CGPoint(x: x(hz) + 3, y: plot.maxY - 6), anchor: .leading)
            }
            for db in [-12.0, -6, 0, 6, 12] {
                var line = Path()
                line.move(to: CGPoint(x: plot.minX, y: y(db)))
                line.addLine(to: CGPoint(x: plot.maxX, y: y(db)))
                context.stroke(line, with: .color(db == 0 ? theme.ledText.opacity(0.22) : grid), lineWidth: 1)
                // Short scopes keep only the ±12 labels, so they don't pile up.
                if db != 0 && (abs(db) == 12 || plot.height >= 90) && plot.height >= 36 {
                    context.draw(Text("\(db > 0 ? "+" : "")\(Int(db))").font(labelFont)
                                    .foregroundColor(theme.ledText.opacity(0.45)),
                                 at: CGPoint(x: plot.minX + 3, y: y(db) + (db < 0 ? -7 : 7)), anchor: .leading)
                }
            }

            guard freqs.count > 1, gains.count == freqs.count, levels.count == freqs.count else {
                drawBrightenGuide(&context)
                return
            }

            // Band levels as dim lamp columns (−90 … 0 dB, perceptually weighted).
            for (i, hz) in freqs.enumerated() {
                let h = plot.height * CGFloat(max(0, min(1, (levels[i] + 90) / 90)))
                let left = i == 0 ? x(hz) - 4 : (x(freqs[i - 1]) + x(hz)) / 2
                let right = i == freqs.count - 1 ? x(hz) + 4 : (x(hz) + x(freqs[i + 1])) / 2
                let bar = CGRect(x: left + 1, y: plot.maxY - h, width: max(1, right - left - 2), height: h)
                context.fill(Path(roundedRect: bar, cornerRadius: 1.5), with: .linearGradient(
                    Gradient(colors: [theme.ledText.opacity(0.16), theme.ledText.opacity(0.04)]),
                    startPoint: CGPoint(x: bar.midX, y: bar.minY),
                    endPoint: CGPoint(x: bar.midX, y: plot.maxY)))
            }

            // Outside the processed range: smoked over.
            context.fill(Path(CGRect(x: plot.minX, y: plot.minY, width: max(0, x(lowHz) - plot.minX), height: plot.height)),
                         with: .color(.black.opacity(0.45)))
            context.fill(Path(CGRect(x: x(highHz), y: plot.minY, width: max(0, plot.maxX - x(highHz)), height: plot.height)),
                         with: .color(.black.opacity(0.45)))

            // Gain curve, smoothed with quadratic segments through band centres.
            var points = [CGPoint(x: plot.minX, y: y(gains[0]))]
            points += freqs.indices.map { CGPoint(x: x(freqs[$0]), y: y(gains[$0])) }
            points.append(CGPoint(x: plot.maxX, y: y(gains[gains.count - 1])))

            var curve = Path()
            curve.move(to: points[0])
            for i in 1..<points.count {
                let mid = CGPoint(x: (points[i - 1].x + points[i].x) / 2, y: (points[i - 1].y + points[i].y) / 2)
                curve.addQuadCurve(to: mid, control: points[i - 1])
            }
            curve.addLine(to: points[points.count - 1])

            var fill = curve
            fill.addLine(to: CGPoint(x: plot.maxX, y: y(0)))
            fill.addLine(to: CGPoint(x: plot.minX, y: y(0)))
            fill.closeSubpath()

            // Recovered (boosted) bands glow green above the line, tamed bands amber below.
            context.drawLayer { layer in
                layer.clip(to: Path(CGRect(x: plot.minX, y: plot.minY, width: plot.width, height: y(0) - plot.minY)))
                layer.fill(fill, with: .color(theme.meterGreen.opacity(0.30)))
            }
            context.drawLayer { layer in
                layer.clip(to: Path(CGRect(x: plot.minX, y: y(0), width: plot.width, height: plot.maxY - y(0))))
                layer.fill(fill, with: .color(theme.meterAmber.opacity(0.30)))
            }

            // Phosphor trace: a soft bloom under a bright core.
            context.stroke(curve, with: .color(theme.ledText.opacity(0.25)), lineWidth: 4.5)
            context.stroke(curve, with: .color(theme.ledText), lineWidth: 1.6)

            drawBrightenGuide(&context)
        }
        .accessibilityElement()
        .accessibilityLabel("EQ curve")
        .accessibilityValue(Self.summary(gains))
    }

    /// Mirrors the kernel's tilt (the Tilt knob, parameter `brighten`) (`NoMoreEQKernel::process`): up to
    /// ±1.2 dB/octave pivoting at 1 kHz, clamped to ±6 dB. Keep the two in step.
    private static let brightenPivotHz: Double = 1000

    private static func brightenTiltDb(hz: Double, brighten: Double) -> Double {
        min(6, max(-6, brighten * 1.2 * log2(hz / brightenPivotHz)))
    }

    private static func summary(_ gains: [Double]) -> String {
        guard let lo = gains.min(), let hi = gains.max() else { return "" }
        return String(format: "%+.1f to %+.1f decibels", lo, hi)
    }
}
