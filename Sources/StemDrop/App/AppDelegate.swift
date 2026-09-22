import AppKit

extension Notification.Name {
    /// Posted whenever `application(_:open:)` fires while the app is already
    /// running, so `AppState` can forward the URLs into `handleDrop`.
    static let stemDropOpenURLs = Notification.Name("StemDropOpenURLs")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    nonisolated(unsafe) static var pendingOpenURLs: [URL] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Only one StemDrop may ever run (Daniel, 2026-09-20): several copies
        // of the bundle on disk (build/, a stale root copy) share one bundle
        // id, and each launched instance had its own job queue. If another
        // instance is already up, hand it the spotlight and quit this one.
        let me = NSRunningApplication.current
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != me.processIdentifier }
        if let existing = others.first {
            existing.activate(options: [.activateAllWindows])
            NSApp.terminate(nil)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        TemporaryFiles.cleanupAll()
    }

    func applicationWillTerminate(_ notification: Notification) {
        PythonEngineRunner.terminateAll()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        AppDelegate.pendingOpenURLs.append(contentsOf: urls)
        NotificationCenter.default.post(name: .stemDropOpenURLs, object: nil, userInfo: ["urls": urls])
    }
}
