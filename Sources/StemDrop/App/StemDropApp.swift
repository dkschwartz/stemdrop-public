import SwiftUI

@main
struct StemDropApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup("StemDrop") {
            MainView(appState: appState)
        }
        .defaultSize(width: 520, height: 660)
        .windowResizability(.contentSize)

        Settings {
            SettingsView(appState: appState)
        }
    }
}
