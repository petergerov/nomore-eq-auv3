// NoMore EQ — AUv3 principal class: creates the audio unit and its SwiftUI editor.
import CoreAudioKit
import SwiftUI

#if os(macOS)
private typealias PlatformHostingController = NSHostingController
#else
private typealias PlatformHostingController = UIHostingController
#endif

public class AudioUnitViewController: AUViewController, AUAudioUnitFactory {
    private var audioUnit: NoMoreEQAudioUnit?
    private var hostingController: PlatformHostingController<NoMoreEQEditor>?

    public override func viewDidLoad() {
        super.viewDidLoad()
        preferredContentSize = CGSize(width: 760, height: 520)
        if let audioUnit { installEditor(for: audioUnit) }
    }

    public func createAudioUnit(with componentDescription: AudioComponentDescription) throws -> AUAudioUnit {
        let unit = try NoMoreEQAudioUnit(componentDescription: componentDescription, options: [])
        audioUnit = unit
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isViewLoaded else { return }
            self.installEditor(for: unit)
        }
        return unit
    }

    private func installEditor(for unit: NoMoreEQAudioUnit) {
        guard hostingController == nil else { return }
        let host = PlatformHostingController(rootView: NoMoreEQEditor(model: EditorModel(audioUnit: unit)))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        #if os(iOS)
        host.didMove(toParent: self)
        #endif
        hostingController = host
    }
}
