import CGtk
import GtkKit
import Foundation
import CirclesPresentation
import CirclesCore

/// `--snapshot DIR`: drives the real app through its main screens and saves
/// each as a PNG, rendered by GTK itself (only this window, never the rest
/// of the screen). For checking the UI without screenshots.
@MainActor
enum Snapshot {
    static func run(_ app: AppController, into directory: String) async {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        func save(_ name: String) async {
            try? await Task.sleep(for: .milliseconds(700)) // let layout, images and transitions settle
            let path = directory + "/" + name + ".png"
            print(render(app.window, to: path) ? "saved \(path)" : "FAILED to render \(name)")
        }
        // Wait for the stream to load.
        for _ in 0..<50 where app.streamModel?.state.phase != .idle { try? await Task.sleep(for: .milliseconds(100)) }
        await save("1-stream")

        if let card = app.streamModel?.state.cards.first(where: { !$0.comments.isEmpty }) ?? app.streamModel?.state.cards.first {
            app.open(card.reference)
            await save("2-post")
            app.back()
        }
        app.showCircles()
        await save("3-circles")
        app.back()

        if let composer = app.compose() {
            await composer.model.perform(.load)
            composer.setText("Heading up the ridge this weekend. Who's in?")
            await save("4-composer-empty-audience")
            if let first = composer.model.state.circles.first { await composer.model.perform(.toggleCircle(first)) }
            await save("5-composer")

            // Self-test: real button activations must reach the shared models.
            composer.pressPost()
            let posted = await waitFor { app.streamModel?.state.cards.contains { $0.body.plainText.hasPrefix("Heading up the ridge") } == true }
            check(posted, "pressing Post published the post and it appeared in the Stream")
        }
        if let first = app.streamModel?.state.cards.first(where: { $0.authorName != "" }),
           let row = app.streamPage?.row(for: first.id) {
            let before = first.plusOnedByMe
            row.pressPlusOne()
            let toggled = await waitFor { app.streamModel?.state.cards.first { $0.id == first.id }?.plusOnedByMe == !before }
            check(toggled, "pressing +1 toggled the post's +1")
            await save("6-after-interactions")
        }
        print(failures == 0 ? "self-test passed" : "self-test FAILED (\(failures))")
        if failures > 0 { exit(1) }
    }

    private static var failures = 0

    private static func check(_ condition: Bool, _ description: String) {
        print((condition ? "ok: " : "FAILED: ") + description)
        if !condition { failures += 1 }
    }

    private static func waitFor(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<50 {
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
