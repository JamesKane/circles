import CGtk
import GtkKit
import Foundation
import CirclesCore
import CirclesKit
import CirclesPresentation

/// `--snapshot DIR [--photo FILE]`: drives the real app and saves each screen
/// as a PNG rendered by GTK itself (only this window, never the rest of the
/// screen), while self-testing that real widget activations reach the shared
/// screen models.
///
/// With an empty `CIRCLES_HOME` it walks the first-run journey: onboarding,
/// adding a contact by invite, receiving their post through an incoming sync,
/// settings, posting and +1. With an existing account it tours its data.
@MainActor
enum Snapshot {
    static func run(_ app: AppController, into directory: String, photo: String?) async {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        if let onboarding = app.onboarding {
            await save(app, "0-onboarding", in: directory)
            onboarding.fill(name: "Alice Liddell")
            check(await waitFor { app.streamModel?.state.phase == .idle }, "onboarding created the account and showed the Stream")
            await firstRun(app, directory: directory, photo: photo)
        } else {
            await tour(app, directory: directory)
        }
        await interactions(app, directory: directory)
        report(failures == 0 ? "self-test passed" : "self-test FAILED (\(failures))")
        if failures > 0 { exit(1) }
    }

    private static func firstRun(_ app: AppController, directory: String, photo: String?) async {
        guard let account = app.account, let network = app.network else { return }
        check(await waitFor { if case .online = network.state.status { true } else { false } }, "the network came online")
        await save(app, "1-stream-empty", in: directory)
        guard case .online(let port) = network.state.status else { return }

        // A second person, Bob, in a temporary directory.
        let bobHome = FileManager.default.temporaryDirectory.appendingPathComponent("circles-snapshot-bob-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: bobHome) }
        guard let bob = try? await Account.create(home: bobHome, displayName: "Bob Marley") else { return }
        _ = try? await bob.addContact(invite: try await account.invite())

        // Add Bob through the People page, by pasting his invite.
        if let people = app.showPeople(), let invite = try? await bob.invite() {
            people.paste(invite: invite)
            check(await waitFor { people.model.state.people.map(\.name) == ["Bob Marley"] }, "pasting Bob's invite on the People page added him")
            await save(app, "2-people", in: directory)
            if let dialog = await people.pressRemove(bob.user) {
                await save(app, "2b-remove-confirmation", in: directory)
                adw_dialog_close(g(dialog)) // Cancel
                try? await Task.sleep(for: .milliseconds(300))
                check(people.model.state.people.count == 1, "cancelling the Remove confirmation kept Bob")
            } else {
                check(false, "the Remove button opened a confirmation")
            }
            app.back()
        }

        // Bob posts and syncs into the running app; the Stream updates by itself.
        let attachments = photo.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
            .map { [Attachment(data: Array($0), mediaType: "image/png")] } ?? []
        _ = try? await bob.post(RichText(plain: "Sunset from the ridge last night. Worth every step of the climb."),
                                to: .everyone, attachments: attachments)
        _ = try? await bob.sync(host: "127.0.0.1", port: port)
        check(await waitFor { app.streamModel?.state.cards.contains { $0.authorName == "Bob Marley" } == true },
              "an incoming sync from Bob updated the Stream without a refresh")
        await save(app, "3-stream-incoming", in: directory)

        app.showSettings()
        await save(app, "4-settings", in: directory)
        app.back()
    }

    private static func tour(_ app: AppController, directory: String) async {
        _ = await waitFor { app.streamModel?.state.phase == .idle }
        await save(app, "1-stream", in: directory)
        if let card = app.streamModel?.state.cards.first(where: { !$0.comments.isEmpty }) ?? app.streamModel?.state.cards.first {
            app.open(card.reference)
            await save(app, "2-post", in: directory)
            app.back()
        }
        app.showCircles()
        await save(app, "3-circles", in: directory)
        app.back()
        app.showPeople()
        await save(app, "4-people", in: directory)
        app.back()
        app.showSettings()
        await save(app, "5-settings", in: directory)
        app.back()
    }

    /// Real button activations: post from the composer, then +1.
    private static func interactions(_ app: AppController, directory: String) async {
        if let composer = app.compose() {
            await composer.model.perform(.load)
            composer.setText("Heading up the ridge this weekend. Who's in?")
            await save(app, "6-composer", in: directory)
            if let first = composer.model.state.circles.first {
                await composer.model.perform(.toggleCircle(first))
            } else {
                await composer.model.perform(.setShareWithEveryone(true))
            }
            composer.pressPost()
            check(await waitFor { app.streamModel?.state.cards.contains { $0.body.plainText.hasPrefix("Heading up the ridge") } == true },
                  "pressing Post published the post and it appeared in the Stream")
        }
        if let first = app.streamModel?.state.cards.first, let row = app.streamPage?.row(for: first.id) {
            let before = first.plusOnedByMe
            row.pressPlusOne()
            check(await waitFor { app.streamModel?.state.cards.first { $0.id == first.id }?.plusOnedByMe == !before },
                  "pressing +1 toggled the post's +1")
            await save(app, "7-after-interactions", in: directory)
        }
    }

    // MARK: Helpers

    private static var failures = 0

    private static func save(_ app: AppController, _ name: String, in directory: String) async {
        try? await Task.sleep(for: .milliseconds(700)) // let layout, images and transitions settle
        let path = directory + "/" + name + ".png"
        report(render(app.window, to: path) ? "saved \(path)" : "FAILED to render \(name)")
    }

    private static func check(_ condition: Bool, _ description: String) {
        report((condition ? "ok: " : "FAILED: ") + description)
        if !condition { failures += 1 }
    }

    private static func waitFor(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<80 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    /// Renders a widget to PNG through GTK's own renderer.
    static func render(_ widget: Widget, to path: String) -> Bool {
        let width = gtk_widget_get_width(widget), height = gtk_widget_get_height(widget)
        guard width > 0, height > 0, let paintable = gtk_widget_paintable_new(widget) else { return false }
        defer { g_object_unref(g(paintable)) }
        let snapshot = gtk_snapshot_new()!
        gdk_paintable_snapshot(paintable, snapshot, Double(width), Double(height))
        guard let node = gtk_snapshot_free_to_node(snapshot) else { return false }
        defer { gsk_render_node_unref(node) }
        guard let renderer = gtk_native_get_renderer(gtk_widget_get_native(widget)),
              let texture = gsk_renderer_render_texture(renderer, node, nil)
        else { return false }
        defer { g_object_unref(g(texture)) }
        return gdk_texture_save_to_png(texture, path) != 0
    }
}

/// Unbuffered, so progress survives a crash and shows up when piped.
func report(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}
