import SwiftUI
import AppKit

@main
struct WendigoApp: App {
    @StateObject private var sourceManager = SourceManager()

    var body: some Scene {
        WindowGroup {
            ContentView(sourceManager: sourceManager)
                .preferredColorScheme(.dark)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
    }
}
