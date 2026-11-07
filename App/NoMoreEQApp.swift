// NoMore EQ — container app. Registers the AUv3 and lets you try it on a demo loop or your own audio.
import SwiftUI

@main
struct NoMoreEQApp: App {
    @StateObject private var host = AudioHost()

    var body: some Scene {
        #if os(macOS)
        WindowGroup {
            ContentView().environmentObject(host)
        }
        .defaultSize(width: 860, height: 600)
        #else
        WindowGroup {
            ContentView().environmentObject(host)
        }
        #endif
    }
}
