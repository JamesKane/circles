import AppKit
import SwiftUI

/// The SwiftUI app (docs/DESIGN.md §11.6): one window over the shared
/// CirclesPresentation screen models.
@main
struct CirclesApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        Window("Circles", id: "main") {
            RootView(app: delegate.app)
                .frame(minWidth: 520, minHeight: 600)
        }
        .defaultSize(width: 760, height: 900)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let app = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await app.launch() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Stops the network before exit, so the mDNS goodbye and port-mapping
    /// removal go out.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard app.network != nil else { return .terminateNow }
        Task {
            await app.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
