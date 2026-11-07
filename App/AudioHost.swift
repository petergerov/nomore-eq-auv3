// NoMore EQ — minimal AVAudioEngine host: player → NoMore EQ → output.
import AVFoundation
import AudioToolbox
import CoreAudioKit

#if os(macOS)
import AppKit
typealias PluginViewController = NSViewController
#else
import UIKit
typealias PluginViewController = UIViewController
#endif

final class AudioHost: ObservableObject {
    static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: fourCharCode("nmeq"),
        componentManufacturer: fourCharCode("Riam"),
        componentFlags: 0,
        componentFlagsMask: 0
    )

    @Published private(set) var status = "Loading NoMore EQ…"
    @Published private(set) var isPlaying = false
    @Published private(set) var sourceName = "Demo loop"
    @Published private(set) var viewController: PluginViewController?
    @Published var bypassed = false {
        didSet { unit?.auAudioUnit.shouldBypassEffect = bypassed }
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var unit: AVAudioUnit?
    private var buffer: AVAudioPCMBuffer = DemoSignal.make()

    init() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        engine.attach(player)
        load(attempt: 1)
    }

    var isReady: Bool { unit != nil }

    // The system may need a moment to register the extension on first launch.
    private func load(attempt: Int) {
        AVAudioUnit.instantiate(with: Self.componentDescription, options: []) { [weak self] avUnit, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let avUnit {
                    self.attach(avUnit)
                } else if attempt < 8 {
                    self.status = "Waiting for the system to register the extension…"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { self.load(attempt: attempt + 1) }
                } else {
                    self.status = "Couldn't load NoMore EQ: \(error?.localizedDescription ?? "component not registered")"
                }
            }
        }
    }

    private func attach(_ avUnit: AVAudioUnit) {
        unit = avUnit
        engine.attach(avUnit)
        connect(format: buffer.format)
        status = "Ready"
        avUnit.auAudioUnit.requestViewController { [weak self] vc in
            DispatchQueue.main.async { self?.viewController = vc }
        }
    }

    private func connect(format: AVAudioFormat) {
        guard let unit else { return }
        engine.disconnectNodeOutput(player)
        engine.disconnectNodeOutput(unit)
        engine.connect(player, to: unit, format: format)
        engine.connect(unit, to: engine.mainMixerNode, format: format)
        engine.prepare()
    }

    func togglePlayback() {
        isPlaying ? stop() : play()
    }

    func play() {
        guard unit != nil else { return }
        do {
            if !engine.isRunning { try engine.start() }
            player.scheduleBuffer(buffer, at: nil, options: [.loops, .interruptsAtLoop])
            player.play()
            isPlaying = true
        } catch {
            status = "Audio engine failed to start: \(error.localizedDescription)"
        }
    }

    func stop() {
        player.stop()
        isPlaying = false
    }

    func load(fileAt url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            guard format.channelCount <= 8 else { status = "Files with more than 8 channels aren't supported"; return }
            let maxFrames = AVAudioFrameCount(format.sampleRate * 600)   // first 10 minutes
            let frames = AVAudioFrameCount(min(Int64(maxFrames), file.length))
            guard let newBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
            try file.read(into: newBuffer, frameCount: frames)

            let wasPlaying = isPlaying
            stop()
            engine.stop()
            buffer = newBuffer
            connect(format: format)
            sourceName = url.lastPathComponent
            status = "Ready"
            if wasPlaying { play() }
        } catch {
            status = "Couldn't open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func useDemoLoop() {
        let wasPlaying = isPlaying
        stop()
        engine.stop()
        buffer = DemoSignal.make()
        connect(format: buffer.format)
        sourceName = "Demo loop"
        if wasPlaying { play() }
    }
}

private func fourCharCode(_ string: String) -> FourCharCode {
    string.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
}
