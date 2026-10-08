import CGtk
import GtkKit
import CirclesCore
import CirclesKit
import CirclesPresentation

/// The composer, as a libadwaita dialog.
@MainActor
final class ComposerDialog {
    let model: ComposerScreenModel
    let dialog: Widget
    private let buffer: UnsafeMutablePointer<GtkTextBuffer>
    private let everyone = gtk_switch_new()!
    private let circles = UI.hbox(spacing: 4)
    private let attachments = UI.vbox(spacing: 4)
    private let audience = UI.label("", classes: ["dim-label"])
    private let status = UI.label("", classes: ["error"], wrap: true)
    private let allowComments = gtk_switch_new()!
    private let allowResharing = gtk_switch_new()!
    private var post: Widget!
    private var circleNames: [String] = []

    init(model: ComposerScreenModel, onPosted: @escaping @MainActor () -> Void) {
        self.model = model
        dialog = g(adw_dialog_new()!)
        adw_dialog_set_title(g(dialog), "New post")
        adw_dialog_set_content_width(g(dialog), 520)

        let textView = gtk_text_view_new()!
        gtk_text_view_set_wrap_mode(g(textView), GTK_WRAP_WORD_CHAR)
        gtk_widget_set_size_request(textView, -1, 120)
        UI.setMargins(textView, 8)
        buffer = gtk_text_view_get_buffer(g(textView))!
        let frame = gtk_frame_new(nil)!
        gtk_frame_set_child(g(frame), textView)

        let attach = UI.button("Add photo", icon: "image-x-generic-symbolic") { model.send(.pickImage) }
        post = UI.button("Post", classes: ["suggested-action"]) { model.send(.post) }

        let content = UI.vbox(spacing: 12, [
            frame,
            UI.hbox(spacing: 8, [UI.label("Share publicly"), everyone]),
            audience,
            UI.label("Share with circles:", classes: ["caption", "dim-label"]), circles,
            UI.hbox(spacing: 8, [attach]), attachments,
            UI.hbox(spacing: 8, [UI.label("Allow comments"), allowComments, UI.label("Allow resharing"), allowResharing]),
            status,
        ])
        UI.setMargins(content, 16)
        let header = adw_header_bar_new()!
        adw_header_bar_pack_end(g(header), post)
        let toolbar = adw_toolbar_view_new()!
        adw_toolbar_view_add_top_bar(g(toolbar), header)
        adw_toolbar_view_set_content(g(toolbar), content)
        adw_dialog_set_child(g(dialog), toolbar)

        connect(buffer, "changed") { [unowned self] in
            var start = GtkTextIter(), end = GtkTextIter()
            gtk_text_buffer_get_bounds(buffer, &start, &end)
            let text = String(cString: gtk_text_buffer_get_text(buffer, &start, &end, 0))
            if text != model.state.text { model.send(.editText(text)) }
        }
        connect(everyone, "notify::active") { [unowned self] _ in
            let on = gtk_switch_get_active(g(everyone)) != 0
            if on != model.state.shareWithEveryone { model.send(.setShareWithEveryone(on)) }
        }
        connect(allowComments, "notify::active") { [unowned self] _ in
            let on = gtk_switch_get_active(g(allowComments)) != 0
            if on != model.state.allowComments { model.send(.setAllowComments(on)) }
        }
        connect(allowResharing, "notify::active") { [unowned self] _ in
            let on = gtk_switch_get_active(g(allowResharing)) != 0
            if on != model.state.allowResharing { model.send(.setAllowResharing(on)) }
        }
        observe { [weak self] in
            guard let self else { return }
            render()
            if model.state.status == .posted {
                adw_dialog_close(g(dialog))
                onPosted()
            }
        }
        model.send(.load)
    }

    private func render() {
        let state = model.state
        if gtk_switch_get_active(g(everyone)) != (state.shareWithEveryone ? 1 : 0) {
            gtk_switch_set_active(g(everyone), state.shareWithEveryone ? 1 : 0)
        }
        if gtk_switch_get_active(g(allowComments)) != (state.allowComments ? 1 : 0) {
            gtk_switch_set_active(g(allowComments), state.allowComments ? 1 : 0)
        }
        if gtk_switch_get_active(g(allowResharing)) != (state.allowResharing ? 1 : 0) {
            gtk_switch_set_active(g(allowResharing), state.allowResharing ? 1 : 0)
        }
        UI.setText(audience, state.audienceSummary)
        if state.circles != circleNames {
            circleNames = state.circles
            UI.removeAllChildren(circles)
            for name in state.circles {
                let toggle = gtk_toggle_button_new_with_label(name)!
                gtk_widget_set_name(toggle, name)
                connect(toggle, "toggled") { [unowned self] in
                    let active = gtk_toggle_button_get_active(g(toggle)) != 0
                    if active != model.state.selectedCircles.contains(name) { model.send(.toggleCircle(name)) }
                }
                UI.append(circles, toggle)
            }
        }
        var child = gtk_widget_get_first_child(circles)
        while let toggle = child {
            let name = String(cString: gtk_widget_get_name(toggle))
            let active: gboolean = state.selectedCircles.contains(name) ? 1 : 0
            if gtk_toggle_button_get_active(g(toggle)) != active { gtk_toggle_button_set_active(g(toggle), active) }
            child = gtk_widget_get_next_sibling(toggle)
        }
        UI.removeAllChildren(attachments)
        for attachment in state.attachments {
            let remove = UI.button(icon: "window-close-symbolic", classes: ["flat", "circular"]) { [model] in
                model.send(.removeAttachment(id: attachment.id))
            }
            UI.append(attachments, UI.hbox(spacing: 6, [UI.label("📷 \(attachment.mediaType) · \(attachment.sizeLabel)"), remove]))
        }
        UI.setSensitive(post, state.canPost)
        if case .failed(let reason) = state.status { UI.setText(status, reason) } else { UI.setText(status, "") }
    }

    /// Activates the Post button as a click would (snapshot self-test).
    func pressPost() { _ = gtk_widget_activate(post) }

    func setText(_ text: String) {
        gtk_text_buffer_set_text(buffer, text, -1)
    }
}
