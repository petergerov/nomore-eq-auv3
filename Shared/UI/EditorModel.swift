// NoMore EQ — view model bridging the AU's parameter tree and meters to SwiftUI.
import AudioToolbox
import Combine
import Foundation

/// Live band data for the analyzer. Kept apart from `EditorModel` so the 30 Hz
/// meter updates re-render only the views that draw them, not the whole panel.
final class BandMeters: ObservableObject {
    /// Band centres; changes when the Bands switch picks another count.
    @Published fileprivate(set) var frequencies: [Float]
    @Published fileprivate(set) var gains: [Float]
    @Published fileprivate(set) var levels: [Float]
    /// The analyzer is listening to the sidechain input rather than the main one.
    @Published fileprivate(set) var analyzingSidechain = false

    init(frequencies: [Float]) {
        self.frequencies = frequencies
        gains = [Float](repeating: 0, count: frequencies.count)
        levels = [Float](repeating: -120, count: frequencies.count)
    }
}

/// One level meter's display state, in dBFS.
struct MeterReading: Equatable {
    static let floorDb: Float = -60

    var levelDb: Float = floorDb
    /// Peak-hold marker: the recent maximum, held for a moment before it drops.
    var holdDb: Float = floorDb
    /// The signal reached 0 dBFS recently.
    var clipped = false
}

struct StereoReading: Equatable {
    var left = MeterReading()
    var right = MeterReading()
}

/// Meter ballistics: instant attack, a steady fall, a peak-hold marker, and a
/// clip lamp that stays lit long enough that an over can't be missed.
struct MeterBallistics {
    static let fallDbPerSecond: Float = 24
    static let holdSeconds: Double = 1.5
    static let clipSeconds: Double = 2.5

    private(set) var reading = MeterReading()
    private var holdAge: Double = 0
    private var clipAge: Double = .infinity

    /// `peak` is the linear peak since the last update, `elapsed` the seconds since then.
    mutating func update(peak: Float, elapsed: Double) {
        let floor = MeterReading.floorDb
        let db = peak > 0 ? max(floor, 20 * log10(peak)) : floor
        reading.levelDb = max(db, reading.levelDb - Self.fallDbPerSecond * Float(elapsed), floor)

        if db >= reading.holdDb {
            reading.holdDb = db
            holdAge = 0
        } else {
            holdAge += elapsed
            if holdAge > Self.holdSeconds { reading.holdDb = reading.levelDb }
        }

        clipAge = peak >= 1 ? 0 : clipAge + elapsed
        reading.clipped = clipAge < Self.clipSeconds
    }
}

/// Input and output levels for the meters, kept apart from `EditorModel` for
/// the same reason as `BandMeters`: only the meters redraw at meter rate.
final class LevelMeters: ObservableObject {
    @Published fileprivate(set) var input = StereoReading()
    @Published fileprivate(set) var output = StereoReading()
}

final class EditorModel: ObservableObject {
    struct Spec: Identifiable {
        let id: String
        let label: String
        let defaultValue: AUValue
        let logarithmic: Bool
        let bipolar: Bool
        let hint: String
        /// Printed at the two ends of a bipolar knob's scale.
        var endLabels: (low: String, high: String)? = nil
    }

    // The ids are the AU parameter identifiers, which keep their original
    // names (tame, recover, bias, brighten) so saved sessions still load.

    static let tame     = Spec(id: "tame",     label: "Cut",      defaultValue: 40,    logarithmic: false, bipolar: false, hint: "Cut what sticks out: resonances, harshness")
    static let recover  = Spec(id: "recover",  label: "Lift",     defaultValue: 40,    logarithmic: false, bipolar: false, hint: "Lift what's buried or masked")
    static let bias     = Spec(id: "bias",     label: "Lean",     defaultValue: 0,     logarithmic: false, bipolar: true,  hint: "Lean toward cutting (−) or lifting (+)",
                               endLabels: ("Cut", "Lift"))
    static let brighten = Spec(id: "brighten", label: "Tilt",     defaultValue: 0,     logarithmic: false, bipolar: true,  hint: "Tilt the tone darker or brighter around 1 kHz",
                               endLabels: ("Dark", "Bright"))
    static let lowFreq  = Spec(id: "lowFreq",  label: "Low",      defaultValue: 30,    logarithmic: true,  bipolar: false, hint: "Lowest processed frequency")
    static let highFreq = Spec(id: "highFreq", label: "High",     defaultValue: 18000, logarithmic: true,  bipolar: false, hint: "Highest processed frequency")
    static let output   = Spec(id: "output",   label: "Output",   defaultValue: 0,     logarithmic: false, bipolar: true,  hint: "Output gain")

    static let specs: [Spec] = [tame, recover, bias, brighten, lowFreq, highFreq, output]

    /// The Bands switch: index 0, 1, 2 of the `bands` parameter.
    static let bandChoices = [32, 48, 64]

    let audioUnit: NoMoreEQAudioUnit
    let meters: BandMeters
    let levels = LevelMeters()

    @Published private(set) var values: [String: AUValue] = [:]
    @Published private(set) var presetName: String

    private var parameters: [String: AUParameter] = [:]
    private var observerToken: AUParameterObserverToken?
    private var meterTimer: Timer?
    /// Input left/right, then output left/right.
    private var ballistics = [MeterBallistics](repeating: MeterBallistics(), count: 4)
    private var lastMeterPoll = ProcessInfo.processInfo.systemUptime

    init(audioUnit: NoMoreEQAudioUnit) {
        self.audioUnit = audioUnit
        let count = audioUnit.bandCount
        var freqs = [Float](repeating: 0, count: count)
        freqs.withUnsafeMutableBufferPointer { audioUnit.copyBandFrequencies($0.baseAddress!, count: count) }
        meters = BandMeters(frequencies: freqs)
        presetName = audioUnit.currentPreset?.name ?? "Custom"

        for p in audioUnit.parameterTree?.allParameters ?? [] {
            parameters[p.identifier] = p
            values[p.identifier] = p.value
        }

        observerToken = audioUnit.parameterTree?.token(byAddingParameterObserver: { [weak self] address, value in
            DispatchQueue.main.async {
                guard let self, let p = self.parameters.values.first(where: { $0.address == address }) else { return }
                self.values[p.identifier] = value
                self.presetName = self.audioUnit.currentPreset?.name ?? "Custom"
            }
        })

        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.pollMeters() }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    deinit {
        meterTimer?.invalidate()
        if let token = observerToken { audioUnit.parameterTree?.removeParameterObserver(token) }
    }

    // MARK: Reading

    func value(_ id: String) -> AUValue { values[id] ?? parameters[id]?.value ?? 0 }

    func display(_ id: String) -> String {
        guard let p = parameters[id] else { return "" }
        var v = value(id)
        return p.string(fromValue: &v)
    }

    /// The value as a 0…1 knob position, following the spec's taper.
    func normalized(_ id: String) -> Double {
        guard let p = parameters[id], p.maxValue > p.minValue else { return 0 }
        let v = min(max(value(id), p.minValue), p.maxValue)
        if spec(id)?.logarithmic == true, p.minValue > 0 {
            return Double(log(v / p.minValue) / log(p.maxValue / p.minValue))
        }
        return Double((v - p.minValue) / (p.maxValue - p.minValue))
    }

    // MARK: Editing

    func set(_ id: String, _ value: AUValue, event: AUParameterAutomationEventType = .value) {
        guard let p = parameters[id] else { return }
        let clamped = min(p.maxValue, max(p.minValue, value))
        p.setValue(clamped, originator: observerToken, atHostTime: 0, eventType: event)
        if values[id] != clamped { values[id] = clamped }
        if presetName != "Custom" { presetName = "Custom" }
    }

    func setNormalized(_ normalized: Double, for id: String) {
        guard let p = parameters[id] else { return }
        let n = Float(min(1, max(0, normalized)))
        if spec(id)?.logarithmic == true, p.minValue > 0 {
            set(id, p.minValue * pow(p.maxValue / p.minValue, n))
        } else {
            set(id, p.minValue + n * (p.maxValue - p.minValue))
        }
    }

    func isOn(_ id: String) -> Bool { value(id) >= 0.5 }

    /// The band count the Bands switch is set to.
    var bandCount: Int {
        let index = Int(value("bands").rounded())
        return Self.bandChoices[min(max(index, 0), Self.bandChoices.count - 1)]
    }

    func selectBandCount(_ count: Int) {
        guard let index = Self.bandChoices.firstIndex(of: count) else { return }
        beginEditing("bands")
        set("bands", AUValue(index))
        endEditing("bands")
    }

    /// Flips an on/off parameter as one gesture, so hosts record it cleanly.
    func toggle(_ id: String) {
        beginEditing(id)
        set(id, isOn(id) ? 0 : 1)
        endEditing(id)
    }

    func resetToDefault(_ spec: Spec) {
        beginEditing(spec.id)
        set(spec.id, spec.defaultValue)
        endEditing(spec.id)
    }

    /// Touch/release bracket a gesture so hosts record automation correctly.
    func beginEditing(_ id: String) {
        parameters[id]?.setValue(value(id), originator: observerToken, atHostTime: 0, eventType: .touch)
    }

    func endEditing(_ id: String) {
        parameters[id]?.setValue(value(id), originator: observerToken, atHostTime: 0, eventType: .release)
    }

    // MARK: Presets

    var factoryPresets: [AUAudioUnitPreset] { audioUnit.factoryPresets ?? [] }

    func select(_ preset: AUAudioUnitPreset) {
        audioUnit.currentPreset = preset
        for (id, p) in parameters { values[id] = p.value }
        presetName = preset.name
    }

    // MARK: Private

    private func spec(_ id: String) -> Spec? { Self.specs.first { $0.id == id } }

    private func pollMeters() {
        // The render thread switches band count on its own schedule; follow it.
        let count = audioUnit.bandCount
        if count != meters.frequencies.count {
            var freqs = [Float](repeating: 0, count: count)
            freqs.withUnsafeMutableBufferPointer { audioUnit.copyBandFrequencies($0.baseAddress!, count: count) }
            meters.frequencies = freqs
        }
        var g = [Float](repeating: 0, count: count)
        var l = [Float](repeating: 0, count: count)
        g.withUnsafeMutableBufferPointer { gp in
            l.withUnsafeMutableBufferPointer { lp in
                audioUnit.copyBandGains(gp.baseAddress!, levels: lp.baseAddress!, count: count)
            }
        }
        if g != meters.gains { meters.gains = g }
        if l != meters.levels { meters.levels = l }
        let sidechain = audioUnit.isAnalyzingSidechain
        if sidechain != meters.analyzingSidechain { meters.analyzingSidechain = sidechain }
        pollLevels()
    }

    private func pollLevels() {
        let now = ProcessInfo.processInfo.systemUptime
        // Capped so a stalled timer doesn't make the meters jump.
        let elapsed = min(0.25, max(0, now - lastMeterPoll))
        lastMeterPoll = now

        let peaks = audioUnit.takeLevelPeaks()
        for (i, peak) in [peaks.inputLeft, peaks.inputRight, peaks.outputLeft, peaks.outputRight].enumerated() {
            ballistics[i].update(peak: peak, elapsed: elapsed)
        }
        let input = StereoReading(left: ballistics[0].reading, right: ballistics[1].reading)
        let output = StereoReading(left: ballistics[2].reading, right: ballistics[3].reading)
        if input != levels.input { levels.input = input }
        if output != levels.output { levels.output = output }
    }
}
