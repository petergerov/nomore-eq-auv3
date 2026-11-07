// NoMore EQ — a latching illuminated push button, as on a 60s console.
import SwiftUI

/// A chrome bezel holds a coloured glass cap that sits dark when off, lights
/// from behind when engaged, and sinks into the bezel while held or latched.
struct IlluminatedButtonStyle: ButtonStyle {
    let isOn: Bool
    let lampColor: Color

    func makeBody(configuration: Configuration) -> some View {
        IlluminatedButtonFace(label: configuration.label, isOn: isOn,
                              isPressed: configuration.isPressed, lampColor: lampColor)
    }
}

private struct IlluminatedButtonFace: View {
    let label: ButtonStyleConfiguration.Label
    let isOn: Bool
    let isPressed: Bool
    let lampColor: Color
    @Environment(\.gear) private var theme

    /// How far the cap has sunk: further while the finger is on it, a little
    /// while latched, flush when released.
    private var depth: CGFloat { isPressed ? 1.6 : (isOn ? 0.8 : 0) }

    var body: some View {
        ZStack {
            bezel
            cap
                .padding(3)
                .offset(y: depth)
        }
        .animation(.easeOut(duration: 0.08), value: isPressed)
        .animation(.easeOut(duration: 0.12), value: isOn)
    }

    /// Chrome frame with the dark hole the cap sits in.
    private var bezel: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(LinearGradient(colors: [theme.metalLight, theme.metalMid, theme.metalDark],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.black.opacity(0.6), lineWidth: 0.8))
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .fill(.black.opacity(0.8))
                    .padding(2.2)
            )
            .shadow(color: .black.opacity(0.45), radius: 1.5, x: 0, y: 1.5)
    }

    private var cap: some View {
        let shape = RoundedRectangle(cornerRadius: 2.5)
        return shape
            .fill(isOn ? lampColor : theme.lampRedDim)
            // Lit: the bulb's hot spot behind the glass. Unlit: smoked glass.
            .overlay(
                shape.fill(isOn
                    ? RadialGradient(colors: [.white.opacity(0.55), .clear],
                                     center: .init(x: 0.5, y: 0.35), startRadius: 0, endRadius: 46)
                    : RadialGradient(colors: [.white.opacity(0.06), .clear],
                                     center: .init(x: 0.5, y: 0.2), startRadius: 0, endRadius: 46))
            )
            // Glass gloss on the top half, darker towards the bottom lip.
            .overlay(
                shape.fill(LinearGradient(colors: [.white.opacity(0.22), .clear, .black.opacity(0.3)],
                                          startPoint: .top, endPoint: .bottom))
            )
            .overlay(shape.stroke(.black.opacity(0.65), lineWidth: 0.8))
            .overlay(
                label
                    .font(.system(size: 8.5, weight: .heavy))
                    .tracking(1.3)
                    .foregroundStyle(isOn ? Color.white.opacity(0.95) : theme.textLight.opacity(0.55))
                    .shadow(color: isOn ? lampColor : .black.opacity(0.8),
                            radius: isOn ? 2.5 : 0, x: 0, y: isOn ? 0 : 1)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 4)
            )
            // Light spilling out around the cap while engaged.
            .shadow(color: isOn ? lampColor.opacity(0.6) : .clear, radius: 7)
            .shadow(color: .black.opacity(isPressed || isOn ? 0.2 : 0.5), radius: 0.8,
                    x: 0, y: isPressed || isOn ? 0.4 : 1.2)
    }
}
