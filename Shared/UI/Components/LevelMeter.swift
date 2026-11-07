// NoMore EQ — a stereo LED level ladder behind glass, as on outboard gear.
import SwiftUI

/// Two columns of lamps (left, right) over 48 dB: green up to −18 dBFS, amber
/// to −6, red above, and a clip lamp on top that latches for a moment. A
/// single lamp marks the recent peak. Captioned like a knob so it lines up
/// with the knobs beside it.
struct LevelMeter: View {
    let label: String
    let reading: StereoReading
    /// Height of the ladder window.
    let height: CGFloat

    var body: some View {
        VStack(spacing: 5) {
            SilkscreenText(text: label, size: 9.5)
                .frame(minHeight: 14)
            HStack(spacing: 2) {
                LadderColumn(reading: reading.left)
                LadderColumn(reading: reading.right)
            }
            .padding(.horizontal, 3)
            .padding(.vertical, 4)
            .frame(width: 22, height: height)
            .background(LedWindow(cornerRadius: 2))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) level")
        .accessibilityValue(Self.spoken(reading))
    }

    private static func spoken(_ reading: StereoReading) -> String {
        let db = max(reading.left.levelDb, reading.right.levelDb)
        let level = db <= MeterReading.floorDb ? "silent" : String(format: "%.0f decibels", db)
        return reading.left.clipped || reading.right.clipped ? "\(level), clipping" : level
    }
}

private struct LadderColumn: View {
    /// Lamp thresholds in dBFS, bottom to top. The last one is the clip lamp.
    static let thresholds: [Float] = [-48, -42, -36, -30, -24, -18, -12, -9, -6, -3, -1, 0]

    let reading: MeterReading
    @Environment(\.gear) private var theme

    var body: some View {
        let (theme, reading) = (theme, reading)
        Canvas { context, size in
            let count = Self.thresholds.count
            let gap: CGFloat = 1.5
            let cellHeight = (size.height - gap * CGFloat(count - 1)) / CGFloat(count)
            let lit = Self.thresholds.lastIndex { reading.levelDb >= $0 }
            let held = Self.thresholds.lastIndex { reading.holdDb >= $0 }

            for i in 0..<count {
                let y = size.height - CGFloat(i + 1) * cellHeight - CGFloat(i) * gap
                let cell = CGRect(x: 0, y: y, width: size.width, height: cellHeight)
                let path = Path(roundedRect: cell, cornerRadius: min(1.2, cellHeight * 0.3))
                let isClip = i == count - 1
                let isOn = isClip ? reading.clipped : (lit.map { i <= $0 } ?? false) || i == held
                if isOn {
                    let colour = Self.colour(i, theme: theme)
                    context.fill(path.strokedPath(.init(lineWidth: 2.2)), with: .color(colour.opacity(0.35)))
                    context.fill(path, with: .color(colour))
                } else {
                    context.fill(path, with: .color(theme.meterOff))
                    context.stroke(path, with: .color(.black.opacity(0.55)), lineWidth: 0.6)
                }
            }
        }
    }

    private static func colour(_ index: Int, theme: GearPalette) -> Color {
        switch thresholds[index] {
        case ..<(-15): theme.meterGreen
        case ..<(-4): theme.meterAmber
        default: theme.meterRed
        }
    }
}
