// NoMore EQ — plugin editor (macOS, iPadOS, iOS): the analyzer and controls bolted into a rack chassis.
import SwiftUI

struct NoMoreEQEditor: View {
    @ObservedObject var model: EditorModel
    @ObservedObject private var themes = ThemeStore.shared

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                ChassisBackground()

                HStack(spacing: 0) {
                    RackEar().frame(width: PanelMetrics.earWidth)
                    Spacer(minLength: 0)
                    RackEar().frame(width: PanelMetrics.earWidth)
                }

                PanelContent(model: model,
                             knobDiameter: Self.knobDiameter(for: geo.size),
                             showsModelPlate: geo.size.height >= 400)
                    .frame(width: geo.size.width, height: geo.size.height)

                FooterRivetStrip()
                    .frame(width: geo.size.width, height: PanelMetrics.footerHeight)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .environment(\.gear, themes.palette)
        .environment(\.colorScheme, .dark)
        .tint(themes.palette.accent)
    }

    /// Knobs shrink on short panels so the analyzer keeps some height.
    private static func knobDiameter(for size: CGSize) -> CGFloat {
        switch size.height {
        case ..<380: return 44
        case ..<480: return 50
        default: return 56
        }
    }
}

private struct PanelContent: View {
    @ObservedObject var model: EditorModel
    let knobDiameter: CGFloat
    let showsModelPlate: Bool

    var body: some View {
        let inset = PanelMetrics.sideInset
        VStack(spacing: 0) {
            EditorHeader(model: model)
                .padding(.horizontal, inset)
                .padding(.top, 10)
                .padding(.bottom, 8)

            EngravedGroove()
                .padding(.horizontal, inset)

            VStack(spacing: 12) {
                AnalyzerPanel(model: model, meters: model.meters)
                    .frame(minHeight: 110, maxHeight: .infinity)

                ViewThatFits(in: .horizontal) {
                    WideControls(model: model, knobDiameter: knobDiameter)
                    CompactControls(model: model, knobDiameter: knobDiameter)
                }
            }
            .padding(.horizontal, inset)
            .padding(.top, 12)
            .padding(.bottom, showsModelPlate ? 10 : PanelMetrics.footerHeight + 8)

            if showsModelPlate {
                ModelPlate(text: "MODEL NM-32  ·  PERCEPTUAL EQ  ·  \(Self.versionString)")
                    .padding(.horizontal, inset)
                    .padding(.bottom, PanelMetrics.footerHeight + 6)
            }
        }
    }

    private static let versionString: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "v\(version)"
    }()
}

// MARK: - Layouts

private struct WideControls: View {
    @ObservedObject var model: EditorModel
    let knobDiameter: CGFloat

    var body: some View {
        // Range and Output take only the width they need and Balance gets the
        // rest. fixedSize resolves the row to its tallest plate and the others
        // stretch to it — modules cut to one height, as in a rack.
        HStack(alignment: .top, spacing: 14) {
            BalancePanel(model: model, knobDiameter: knobDiameter, layout: .row)
            RangePanel(model: model, knobDiameter: knobDiameter)
                .fixedSize(horizontal: true, vertical: false)
            OutputPanel(model: model, knobDiameter: knobDiameter)
                .fixedSize(horizontal: true, vertical: false)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct CompactControls: View {
    @ObservedObject var model: EditorModel
    let knobDiameter: CGFloat

    var body: some View {
        VStack(spacing: 12) {
            BalancePanel(model: model, knobDiameter: knobDiameter, layout: .fitting)
                .fixedSize(horizontal: false, vertical: true)
            // Side by side where they fit, stacked on the narrowest screens.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    RangePanel(model: model, knobDiameter: knobDiameter)
                    OutputPanel(model: model, knobDiameter: knobDiameter)
                }
                VStack(spacing: 12) {
                    RangePanel(model: model, knobDiameter: knobDiameter)
                    OutputPanel(model: model, knobDiameter: knobDiameter)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Header

private struct EditorHeader: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            FinishSelector()
                .frame(width: 26, height: 26)
            Wordmark(bandCount: model.meters.frequencies.count)
            Spacer(minLength: 12)
            PresetMenu(model: model)
        }
    }
}

private struct Wordmark: View {
    let bandCount: Int
    @Environment(\.gear) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("NoMore EQ")
                .font(.custom("Georgia-BoldItalic", size: 18))
                .foregroundStyle(theme.textLight)
                .shadow(color: .black.opacity(0.75), radius: 0, x: 0, y: 1.5)
                .shadow(color: .black.opacity(0.35), radius: 3, x: 0, y: 2)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            // The full strapline where it fits, a shorter one on narrow panels.
            ViewThatFits(in: .horizontal) {
                strapline("PERCEPTUAL · SELF-ADJUSTING · \(bandCount) BANDS")
                strapline("PERCEPTUAL · \(bandCount) BANDS")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func strapline(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 7.5, weight: .bold, design: .monospaced))
            .tracking(1.1)
            .foregroundStyle(theme.textLight.opacity(0.88))
            .shadow(color: .black.opacity(0.75), radius: 0, x: 0, y: 1)
            .lineLimit(1)
            .fixedSize()
    }
}

/// The preset selector, behind the same smoked-glass window as the readouts.
private struct PresetMenu: View {
    @ObservedObject var model: EditorModel
    @Environment(\.gear) private var theme

    var body: some View {
        Menu {
            ForEach(model.factoryPresets, id: \.number) { preset in
                Button(preset.name) { model.select(preset) }
            }
        } label: {
            HStack(spacing: 8) {
                Text(model.presetName)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.ledText)
                    .shadow(color: theme.ledText.opacity(0.7), radius: 3)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(theme.ledText.opacity(0.7))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minWidth: 150, alignment: .leading)
            .background(LedWindow(cornerRadius: 3))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("Preset")
        .accessibilityValue(model.presetName)
    }
}

// MARK: - Plates

/// Observes the meters on its own, so only the analyzer redraws at meter rate.
private struct AnalyzerPanel: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var meters: BandMeters

    var body: some View {
        InfoPanel(title: "Analyzer", info: Self.info) {
            VStack(spacing: 8) {
                ResponseView(model: model, meters: meters)
                    .background(LedWindow(cornerRadius: 3))
                SidechainRow(model: model, meters: meters)
            }
        }
    }

    static let info = """
        The curve is what NoMore EQ applies right now: green where it lifts, \
        amber where it cuts. The bars show the level in each of the 32 bands. \
        The dashed line is the Tilt, pivoting at 1 kHz. Sidechain makes \
        the analyzer listen to the plug-in's sidechain input instead of the main \
        input; the readout beside it says which one it hears.
        """
}

/// Sidechain: the button makes the sidechain input the
/// analyzer's source; the EQ keeps processing the main input. The readout
/// says what the analyzer is actually hearing.
private struct SidechainRow: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var meters: BandMeters
    @Environment(\.gear) private var theme
    @State private var taps = 0

    var body: some View {
        let isOn = model.isOn("sidechain")
        HStack(spacing: 10) {
            Button {
                model.toggle("sidechain")
                taps += 1
            } label: {
                Text("SIDECHAIN")
            }
            .buttonStyle(IlluminatedButtonStyle(isOn: isOn, lampColor: theme.lampRed))
            .frame(width: 96, height: 26)
            .contentShape(Rectangle())
            .help("Analyze the sidechain input instead of the main input. Route a track to the plug-in's sidechain in your host.")
            .accessibilityLabel("Sidechain")
            .accessibilityValue(isOn ? "On" : "Off")
            .accessibilityAddTraits(isOn ? .isSelected : [])
            .tapFeedback(taps)

            let status = Self.status(isOn: isOn, analyzingSidechain: meters.analyzingSidechain)
            // The full status where it fits, a short one on narrow panels.
            ViewThatFits(in: .horizontal) {
                LedReadout(text: status.long)
                LedReadout(text: status.short)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Analyzer source")
            .accessibilityValue(status.long)
            Spacer(minLength: 0)
        }
    }

    private static func status(isOn: Bool, analyzingSidechain: Bool) -> (long: String, short: String) {
        switch (isOn, analyzingSidechain) {
        case (_, true): return ("ANALYZING SIDECHAIN", "SIDECHAIN")
        case (true, false): return ("NO SIDECHAIN INPUT · ANALYZING MAIN", "NO SIDECHAIN INPUT")
        case (false, false): return ("ANALYZING MAIN INPUT", "MAIN INPUT")
        }
    }
}

private struct BalancePanel: View {
    /// `.row` keeps the four knobs in a line (the wide layout falls back as a
    /// whole when they don't fit); `.fitting` drops to a 2×2 grid on narrow panels.
    enum Layout { case row, fitting }

    @ObservedObject var model: EditorModel
    let knobDiameter: CGFloat
    let layout: Layout

    var body: some View {
        InfoPanel(title: "Balance", info: Self.info) {
            switch layout {
            case .row:
                row
            case .fitting:
                ViewThatFits(in: .horizontal) {
                    row
                    grid
                }
            }
        }
    }

    static let info = """
        Cut pulls down bands that stick out, such as resonances and harshness. \
        Lift brings up bands that are masked or buried. Lean shifts the work \
        toward cutting or lifting. Tilt makes the whole curve darker or \
        brighter around 1 kHz, by up to ±1.2 dB per octave.
        """

    private var row: some View {
        HStack(alignment: .top, spacing: 10) {
            knob(EditorModel.tame)
            knob(EditorModel.recover)
            knob(EditorModel.bias)
            knob(EditorModel.brighten)
        }
    }

    private var grid: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                knob(EditorModel.tame)
                knob(EditorModel.recover)
            }
            GridRow {
                knob(EditorModel.bias)
                knob(EditorModel.brighten)
            }
        }
    }

    /// Each knob takes an equal share of the plate's width, so they spread
    /// evenly however wide the plate is.
    private func knob(_ spec: EditorModel.Spec) -> some View {
        ParameterKnob(spec: spec, model: model, diameter: knobDiameter)
            .frame(maxWidth: .infinity)
    }
}

private struct RangePanel: View {
    @ObservedObject var model: EditorModel
    let knobDiameter: CGFloat

    var body: some View {
        InfoPanel(title: "Range", info: Self.info) {
            HStack(alignment: .top, spacing: 10) {
                ParameterKnob(spec: EditorModel.lowFreq, model: model, diameter: knobDiameter)
                    .frame(maxWidth: .infinity)
                ParameterKnob(spec: EditorModel.highFreq, model: model, diameter: knobDiameter)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    static let info = """
        Only bands between Low and High are processed; the edges fade in \
        softly. Narrow the range to leave the lows or the air untouched.
        """
}

private struct OutputPanel: View {
    @ObservedObject var model: EditorModel
    let knobDiameter: CGFloat

    var body: some View {
        InfoPanel(title: "Output", info: Self.info) {
            HStack(alignment: .top, spacing: 12) {
                IOMeter(label: "In", levels: model.levels, side: \.input, height: meterHeight)
                ParameterKnob(spec: EditorModel.output, model: model, diameter: knobDiameter)
                IOMeter(label: "Out", levels: model.levels, side: \.output, height: meterHeight)
            }
        }
    }

    /// The ladder spans the knob and its readout, so the meters line up with it.
    private var meterHeight: CGFloat { knobDiameter + 5 + 22 }

    static let info = """
        Gain after the EQ. In shows the main input, Out the result, left and \
        right. The top lamp lights at 0 dBFS.
        """
}

/// Observes the levels on its own, so only the meters redraw at meter rate.
private struct IOMeter: View {
    let label: String
    @ObservedObject var levels: LevelMeters
    let side: KeyPath<LevelMeters, StereoReading>
    let height: CGFloat

    var body: some View {
        LevelMeter(label: label, reading: levels[keyPath: side], height: height)
    }
}
