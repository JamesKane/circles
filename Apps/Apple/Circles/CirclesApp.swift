import AppKit
import SwiftUI
import UserNotifications

/// The SwiftUI app (docs/DESIGN.md §11.6): one window over the shared
/// CirclesPresentation screen models, and a Settings window.
@main
struct CirclesApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        Window("Circles", id: "main") {
            RootView(app: delegate.app)
                .frame(minWidth: 720, minHeight: 600)
        }
        .defaultSize(width: 960, height: 900)

        Settings {
            SettingsView(app: delegate.app)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let app = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
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

    /// A clicked notification opens its post.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let post = Notifier.post(from: response.notification.request.content.userInfo) else { return }
        await MainActor.run {
            NSApp.activate()
            app.postToOpen = post
        }
    }
}
