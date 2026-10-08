import CGtk
import GtkKit
import Foundation
import CirclesCore
import CirclesKit
import CirclesPresentation

/// The GNOME app: one window, a navigation view with the Stream at its root,
/// posts and Circles pushed as pages, and the composer as a dialog.
@MainActor
final class AppController {
    let application: UnsafeMutablePointer<AdwApplication>
    private(set) var window: Widget!
    private var navigation: Widget!
    private var account: Account?
    private var stream: StreamPage?
    private var pages: [AnyObject] = [] // keeps page controllers alive
    private var composer: ComposerDialog?

    init(application: UnsafeMutablePointer<AdwApplication>) {
        self.application = application
    }

    func activate(home: URL) async {
        Style.loadCSS()
        Style.loadIcons()
        window = adw_application_window_new(g(application))!
        gtk_window_set_title(g(window), "Circles")
        gtk_window_set_default_size(g(window), 760, 900)
        do {
            let account = try await Account.open(home: home)
            self.account = account
            navigation = adw_navigation_view_new()!
            let stream = StreamPage(model: StreamScreenModel(account: account), media: MediaLoader(account: account), app: self)
            self.stream = stream
            adw_navigation_view_push(g(navigation), g(stream.widget))
            adw_application_window_set_content(g(window), navigation)
            stream.model.send(.refresh)
        } catch {
            let status = adw_status_page_new()!
            adw_status_page_set_icon_name(g(status), "system-users-symbolic")
            adw_status_page_set_title(g(status), "No Circles account yet")
            adw_status_page_set_description(g(status), "Create one with `circles init --name <your name>`, then reopen Circles.\n\(home.path)")
            adw_application_window_set_content(g(window), status)
        }
        gtk_window_present(g(window))
    }

    var streamModel: StreamScreenModel? { stream?.model }
    var streamPage: StreamPage? { stream }

    func open(_ post: ObjectRef) {
        guard let account else { return }
        let page = PostPage(model: PostScreenModel(post: post, account: account), media: MediaLoader(account: account))
        pages.append(page)
        adw_navigation_view_push(g(navigation), g(page.widget))
    }

    func showCircles() {
        guard let account else { return }
        let page = CirclesPage(model: CirclesScreenModel(account: account))
        pages.append(page)
        adw_navigation_view_push(g(navigation), g(page.widget))
    }

    @discardableResult
    func compose() -> ComposerDialog? {
        guard let account else { return nil }
        let composer = ComposerDialog(model: ComposerScreenModel(account: account, services: GnomeServices(window: window))) { [weak self] in
            self?.stream?.model.send(.refresh)
        }
        self.composer = composer
        adw_dialog_present(g(composer.dialog), window)
        return composer
    }

    func back() {
        adw_navigation_view_pop(g(navigation))
    }
}

/// GNOME implementations of the services screen models ask for.
struct GnomeServices: PlatformServices {
    nonisolated(unsafe) let window: Widget

    func pickImage() async -> PickedImage? {
        await withCheckedContinuation { (continuation: CheckedContinuation<PickedImage?, Never>) in
            Task { @MainActor in
                let dialog = gtk_file_dialog_new()!
                gtk_file_dialog_set_title(dialog, "Add a photo")
                let box = Unmanaged.passRetained(ContinuationBox(continuation)).toOpaque()
                gtk_file_dialog_open(dialog, g(window), nil, { source, result, data in
                    let box = Unmanaged<ContinuationBox>.fromOpaque(data!).takeRetainedValue()
                    var error: UnsafeMutablePointer<GError>?
                    guard let file = gtk_file_dialog_open_finish(g(source!), result, &error) else {
                        if error != nil { g_error_free(error) }
                        box.continuation.resume(returning: nil)
                        return
                    }
                    var contents: UnsafeMutablePointer<CChar>?
                    var length: gsize = 0
                    let ok = g_file_load_contents(file, nil, &contents, &length, nil, nil) != 0
                    let path = g_file_get_path(file).map { String(cString: $0) } ?? ""
                    g_object_unref(g(file))
                    guard ok, let contents else {
                        box.continuation.resume(returning: nil)
                        return
                    }
                    let bytes = Array(UnsafeRawBufferPointer(start: contents, count: Int(length)))
                    g_free(contents)
                    box.continuation.resume(returning: PickedImage(data: bytes, mediaType: mediaType(for: path)))
                }, box)
                g_object_unref(g(dialog))
            }
        }
    }

    func copyToClipboard(_ text: String) async {
        await MainActor.run {
            gdk_clipboard_set_text(gtk_widget_get_clipboard(window), text)
        }
    }

    func notify(title: String, body: String) async {
        await MainActor.run {
            let notification = g_notification_new(title)!
            g_notification_set_body(notification, body)
            g_application_send_notification(g_application_get_default(), nil, notification)
            g_object_unref(g(notification))
        }
    }
}

private final class ContinuationBox: @unchecked Sendable {
    let continuation: CheckedContinuation<PickedImage?, Never>
    init(_ continuation: CheckedContinuation<PickedImage?, Never>) { self.continuation = continuation }
}

func mediaType(for path: String) -> String {
    switch URL(fileURLWithPath: path).pathExtension.lowercased() {
    case "jpg", "jpeg": "image/jpeg"
    case "png": "image/png"
    case "gif": "image/gif"
    case "webp": "image/webp"
    default: "application/octet-stream"
    }
}

@main
enum CirclesGnome {
    static func main() {
        MainLoop.integrateSwiftMainActor()
        let arguments = CommandLine.arguments
        let snapshotDirectory = arguments.firstIndex(of: "--snapshot").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        let home = ProcessInfo.processInfo.environment["CIRCLES_HOME"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".circles")

        // Snapshot runs are separate instances, so they never hand off to a
        // running Circles window.
        let flags = GApplicationFlags(rawValue: snapshotDirectory == nil ? 0 : 1 << 5) // G_APPLICATION_NON_UNIQUE
        let application = adw_application_new("dev.circles.Circles", flags)!
        let controller = AppController(application: application)
        connect(application, "activate") {
            // Opening the account is async; hold the application so it doesn't
            // exit for lack of a window before the window exists.
            g_application_hold(g(application))
            Task { @MainActor in
                await controller.activate(home: home)
                g_application_release(g(application))
                if let snapshotDirectory {
                    await Snapshot.run(controller, into: snapshotDirectory)
                    g_application_quit(g(application))
                }
            }
        }
        // GTK must not see our own arguments.
        exit(g_application_run(g(application), 0, nil))
    }
}
