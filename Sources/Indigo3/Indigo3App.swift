import SwiftUI
import AppKit

@main
struct Indigo3App: App {
    @StateObject private var sourceManager = SourceManager()

    var body: some Scene {
        WindowGroup {
            ContentView(sourceManager: sourceManager)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
    }
}
