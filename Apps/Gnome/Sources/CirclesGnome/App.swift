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
    private(set) var account: Account?
    private(set) var network: NetworkModel?
    private(set) var onboarding: OnboardingPage?
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
        if Account.exists(home: home) {
            do {
                await start(try await Account.open(home: home))
            } catch {
                let status = adw_status_page_new()!
                adw_status_page_set_icon_name(g(status), "dialog-error-symbolic")
                adw_status_page_set_title(g(status), "Couldn't open your account")
                adw_status_page_set_description(g(status), "\(error)\n\(home.path)")
                adw_application_window_set_content(g(window), status)
            }
        } else {
            let onboarding = OnboardingPage(model: OnboardingScreenModel(home: home)) { [weak self] account in
                Task { @MainActor in await self?.start(account) }
            }
            self.onboarding = onboarding
            adw_application_window_set_content(g(window), onboarding.widget)
        }
        gtk_window_present(g(window))
    }

    /// Builds the main UI and goes online.
    private func start(_ account: Account) async {
        guard self.account == nil else { return }
        self.account = account
        onboarding = nil
        let network = NetworkModel(account: account)
        self.network = network
        navigation = adw_navigation_view_new()!
        let stream = StreamPage(model: StreamScreenModel(account: account), media: MediaLoader(account: account), network: network, app: self)
        self.stream = stream
        adw_navigation_view_push(g(navigation), g(stream.widget))
        adw_application_window_set_content(g(window), navigation)
        stream.model.send(.refresh)
        network.send(.start)
        // New content from any sync, incoming or outgoing, refreshes the Stream.
        var seen = 0
        observe { [weak stream, weak network] in
            guard let network, let stream else { return }
            let count = network.state.newContentCount
            if count != seen {
                seen = count
                stream.model.send(.refresh)
            }
        }
    }

    func syncNow() {
        guard let network, let stream else { return }
        Task { @MainActor in
            await network.perform(.syncNow)
            await stream.model.perform(.refresh)
        }
    }

    @discardableResult
    func showPeople() -> PeoplePage? {
        guard let account else { return nil }
        let page = PeoplePage(model: PeopleScreenModel(account: account, services: GnomeServices(window: window)))
        pages.append(page)
        adw_navigation_view_push(g(navigation), g(page.widget))
        return page
    }

    @discardableResult
    func showSettings() -> SettingsPage? {
        guard let account, let network else { return nil }
        let page = SettingsPage(settings: SettingsScreenModel(account: account, services: GnomeServices(window: window)), network: network)
        pages.append(page)
        adw_navigation_view_push(g(navigation), g(page.widget))
        return page
    }

    /// Stops the network before exit, so the mDNS goodbye and port-mapping
    /// removal go out. Runs the GTK main context while waiting, because our
    /// main-actor work runs inside it.
    func shutdown() {
        guard let network else { return }
        var stopped = false
        Task { @MainActor in
            await network.perform(.stop)
            stopped = true
        }
        let deadline = ContinuousClock.now + .seconds(3)
        while !stopped && ContinuousClock.now < deadline {
            g_main_context_iteration(nil, 1)
        }
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
        func option(_ name: String) -> String? {
            arguments.firstIndex(of: name).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }
        let snapshotDirectory = option("--snapshot"), photo = option("--photo")
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
                    await Snapshot.run(controller, into: snapshotDirectory, photo: photo)
                    g_application_quit(g(application))
                }
            }
        }
        connect(application, "shutdown") { controller.shutdown() }
        // GTK must not see our own arguments.
        exit(g_application_run(g(application), 0, nil))
    }
}
