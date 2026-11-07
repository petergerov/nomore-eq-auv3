// NoMore EQ — a knob bound to one AU parameter: silkscreened caption, bakelite knob, LED readout.
import SwiftUI

/// Drag up/right to increase, double-tap/click to reset to the default.
struct ParameterKnob: View {
    let spec: EditorModel.Spec
    @ObservedObject var model: EditorModel
    var diameter: CGFloat = 54

    @State private var dragOrigin: Double?
    @State private var resets = 0

    /// Points of drag travel for the full range.
    private static let dragRange: CGFloat = 180

    var body: some View {
        let normalized = model.normalized(spec.id)
        let display = model.display(spec.id)

        VStack(spacing: 5) {
            SilkscreenText(text: spec.label, size: 9.5)
                .frame(minHeight: 14)

            KnobView(normalized: normalized, origin: spec.bipolar ? 0.5 : 0)
                .frame(width: diameter, height: diameter)
                .contentShape(Circle())
                .gesture(dragGesture(from: normalized))
                .onTapGesture(count: 2) {
                    model.resetToDefault(spec)
                    resets += 1
                }
                .tapFeedback(resets)
                .overlay(alignment: .bottom) {
                    if let ends = spec.endLabels {
                        ScaleEndLabels(low: ends.low, high: ends.high)
                            // Beside the scale's end ticks, below the knob's collar.
                            .frame(width: diameter + 10)
                            .offset(y: 1)
                    }
                }

            // Wide enough for the longest readout ("+12.0 dB", "18.0 kHz") so
            // the window doesn't resize while the knob turns.
            LedReadout(text: display, minWidth: max(diameter, 62))
        }
        .fixedSize()
        .help(spec.hint)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spec.label)
        .accessibilityValue(display)
        .accessibilityHint(spec.hint)
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 0.02 : -0.02
            model.setNormalized(normalized + step, for: spec.id)
        }
    }

    private func dragGesture(from normalized: Double) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { gesture in
                if dragOrigin == nil {
                    dragOrigin = normalized
                    model.beginEditing(spec.id)
                }
                let travel = gesture.translation.width - gesture.translation.height
                model.setNormalized((dragOrigin ?? normalized) + Double(travel / Self.dragRange), for: spec.id)
            }
            .onEnded { _ in
                dragOrigin = nil
                model.endEditing(spec.id)
            }
    }
}

/// The words at the two ends of a bipolar knob's scale, printed small on the panel.
private struct ScaleEndLabels: View {
    let low: String
    let high: String
    @Environment(\.gear) private var theme

    var body: some View {
        HStack(spacing: 2) {
            label(low)
            Spacer(minLength: 0)
            label(high)
        }
        .accessibilityHidden(true)
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 6.5, weight: .heavy))
            .tracking(0.6)
            .foregroundStyle(theme.textLight.opacity(0.7))
            .shadow(color: .black.opacity(0.6), radius: 0, x: 0, y: 0.6)
            .lineLimit(1)
            .fixedSize()
    }
}
