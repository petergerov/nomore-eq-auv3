// NoMore EQ — container app UI: transport, bypass, file picker, and the plugin's own editor.
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var host: AudioHost
    @State private var importing = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            Group {
                if let vc = host.viewController {
                    PluginView(viewController: vc)
                } else {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(host.status).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            HStack {
                Image(systemName: "waveform")
                Text(host.sourceName).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(host.status).lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio]) { result in
            if case .success(let url) = result { host.load(fileAt: url) }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { host.togglePlayback() } label: {
                Label(host.isPlaying ? "Stop" : "Play", systemImage: host.isPlaying ? "stop.fill" : "play.fill")
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(!host.isReady)

            Toggle(isOn: $host.bypassed) { Label("Bypass", systemImage: "power") }
                .toggleStyle(.button)
                .disabled(!host.isReady)

            Spacer()

            Menu {
                Button("Open audio file…") { importing = true }
                Button("Use demo loop") { host.useDemoLoop() }
            } label: {
                Label("Source", systemImage: "music.note.list")
            }
            .fixedSize()
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

#if os(macOS)
struct PluginView: NSViewControllerRepresentable {
    let viewController: NSViewController
    func makeNSViewController(context: Context) -> NSViewController { viewController }
    func updateNSViewController(_ controller: NSViewController, context: Context) {}
}
#else
struct PluginView: UIViewControllerRepresentable {
    let viewController: UIViewController
    func makeUIViewController(context: Context) -> UIViewController { viewController }
    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}
#endif
