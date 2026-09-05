import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: UsageStore?
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = UsageStore(providers: [ClaudeProvider(), CodexProvider()])
        self.store = store
        statusBar = StatusBarController(store: store)
        store.startPolling()
    }
}
