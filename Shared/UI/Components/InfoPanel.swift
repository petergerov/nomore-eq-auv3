// NoMore EQ — a control group on its own screwed-on sub-plate, with an info button.
import SwiftUI

/// A plate with no printed heading, just the controls, and an info button in
/// place of the top-right screw that lays the explanation over the plate.
/// Drawn on the plate rather than in a popover, which some AUv3 hosts clip.
struct InfoPanel<Content: View>: View {
    /// Not printed; names the plate for VoiceOver and heads the explanation.
    let title: String
    let info: String
    @ViewBuilder let content: Content

    @State private var showsInfo = false

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(showsInfo ? 0.15 : 1)
            .allowsHitTesting(!showsInfo)
            .accessibilityHidden(showsInfo)
            .overlay {
                if showsInfo {
                    InfoCard(title: title, text: info) { showsInfo = false }
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, PanelMetrics.plateInset)
            .padding(.top, 14)
            .padding(.bottom, 15)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(PanelPlate(omitsTopTrailingScrew: true))
            .overlay(alignment: .topTrailing) {
                InfoButton(title: title, isOn: showsInfo) {
                    withAnimation(.easeOut(duration: 0.15)) { showsInfo.toggle() }
                }
                // Centred on the missing screw: PanelPlate puts it 9.5 pt in
                // from the corner, the button is 22 pt square.
                .offset(x: InfoButton.size / 2 - 9.5, y: 9.5 - InfoButton.size / 2)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(title)
    }
}

private struct InfoButton: View {
    static let size: CGFloat = 22

    let title: String
    let isOn: Bool
    let action: () -> Void
    @Environment(\.gear) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: isOn ? "xmark.circle.fill" : "info.circle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isOn ? theme.ledText : theme.textLight.opacity(0.75))
                .shadow(color: .black.opacity(0.6), radius: 0, x: 0, y: 0.8)
                // A finger-sized target around a small engraved symbol.
                .frame(width: Self.size, height: Self.size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isOn ? "Close" : "What does \(title) do?")
        .accessibilityLabel(isOn ? "Close \(title) info" : "\(title) info")
    }
}

/// The explanation behind glass, sized to the plate. Tap anywhere to close.
private struct InfoCard: View {
    let title: String
    let text: String
    let close: () -> Void
    @Environment(\.gear) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                .tracking(1.2)
            Text(text)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(theme.ledText)
        .shadow(color: theme.ledText.opacity(0.45), radius: 2)
        .minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(8)
        .background(LedWindow(cornerRadius: 3))
        .contentShape(Rectangle())
        .onTapGesture(perform: close)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }
}
