import CGtk
import GtkKit
import CirclesCore
import CirclesKit
import CirclesPresentation

/// Renders one `PostCard`. Built once per post and updated in place, so the
/// stream can diff by post ID instead of rebuilding rows.
@MainActor
final class PostView {
    let root: Widget
    private let avatar: Widget
    private let author = UI.label("", classes: ["heading"])
    private let meta = UI.label("", classes: ["caption", "dim-label"])
    private let audience = UI.label("", classes: ["caption"])
    private let body = UI.label("", classes: ["post-body"], wrap: true)
    private let reshared = UI.vbox(spacing: 4, classes: ["reshared"])
    private let attachments = UI.vbox(spacing: 6)
    private let comments = UI.vbox(spacing: 2)
    private var plusOne: Widget!
    private var commentsButton: Widget!
    private let commentsContent = adw_button_content_new()!
    private var reshare: Widget!
    private var card: PostCard?
    private var loadedAttachments: [ContentID] = []

    private let media: MediaLoader
    private let showThread: Bool

    init(media: MediaLoader, showThread: Bool,
         onPlusOne: @escaping @MainActor (PostCard) -> Void,
         onOpen: @escaping @MainActor (PostCard) -> Void,
         onReshare: @escaping @MainActor (PostCard) -> Void) {
        self.media = media
        self.showThread = showThread
        avatar = adw_avatar_new(40, "", 1)!
        gtk_label_set_selectable(g(body), 1)
        root = UI.vbox(spacing: 10, classes: ["card", "post-card"])
        let header = UI.hbox(spacing: 10, [avatar, UI.vbox(spacing: 2, [author, UI.hbox(spacing: 6, [meta, audience])])])
        plusOne = UI.button("+1") { [unowned self] in if let card { onPlusOne(card) } }
        commentsButton = UI.button(classes: ["flat"], tooltip: "Comments") { [unowned self] in
            if let card { onOpen(card) }
        }
        // Icon and count together (a plain button holds one or the other).
        adw_button_content_set_icon_name(g(commentsContent), "circles-comment-symbolic")
        gtk_button_set_child(g(commentsButton), commentsContent)
        reshare = UI.button(icon: "media-playlist-repeat-symbolic", classes: ["flat"], tooltip: "Reshare publicly") { [unowned self] in
            if let card { onReshare(card) }
        }
        let actions = UI.hbox(spacing: 6, [plusOne, commentsButton, reshare])
        for child in [header, body, reshared, attachments, comments, actions] { UI.append(root, child) }
    }

    /// Activates the +1 button as a click would (snapshot self-test).
    func pressPlusOne() { _ = gtk_widget_activate(plusOne) }

    func update(_ card: PostCard) {
        guard card != self.card else { return }
        self.card = card
        adw_avatar_set_text(g(avatar), card.authorName)
        UI.setText(author, card.authorName)
        UI.setText(meta, card.timestamp + " ·")
        UI.setText(audience, card.audienceLabel)
        for token in [DesignToken.audiencePublic, .audienceLimited] {
            for name in Style.classes(for: token) { gtk_widget_remove_css_class(audience, name) }
        }
        UI.addClasses(audience, Style.classes(for: card.audienceToken))
        UI.setMarkup(body, Style.markup(card.body))
        UI.setVisible(body, !card.body.plainText.isEmpty)

        UI.removeAllChildren(reshared)
        if let original = card.reshared {
            UI.append(reshared, UI.label("↻ \(original.authorName) · \(original.timestamp)", classes: ["caption", "dim-label"]))
            let text = UI.label("", wrap: true)
            UI.setMarkup(text, Style.markup(original.body))
            UI.append(reshared, text)
        }
        UI.setVisible(reshared, card.reshared != nil)

        let attachmentIDs = card.attachments.map(\.id)
        if attachmentIDs != loadedAttachments {
            loadedAttachments = attachmentIDs
            UI.removeAllChildren(attachments)
            for preview in card.attachments { UI.append(attachments, attachmentView(preview)) }
        }

        gtk_button_set_label(g(plusOne), card.plusOnes > 0 ? "+1  \(card.plusOnes)" : "+1")
        for name in Style.classes(for: .plusOneActive) {
            if card.plusOnedByMe { gtk_widget_add_css_class(plusOne, name) } else { gtk_widget_remove_css_class(plusOne, name) }
        }
        adw_button_content_set_label(g(commentsContent), card.comments.isEmpty ? "Comment" : "\(card.comments.count)")
        UI.setVisible(reshare, card.canReshare)

        UI.removeAllChildren(comments)
        if showThread {
            for comment in card.comments { UI.append(comments, commentView(comment)) }
            if !card.canComment { UI.append(comments, UI.label("Comments are turned off.", classes: ["dim-label", "caption"])) }
        }
        UI.setVisible(comments, showThread)
    }

    private func commentView(_ comment: CommentRow) -> Widget {
        let name = UI.label(comment.authorName + "  ·  " + comment.timestamp, classes: ["caption", "heading"])
        let text = UI.label("", wrap: true)
        UI.setMarkup(text, Style.markup(comment.body))
        let row = UI.vbox(spacing: 2, classes: ["comment"], [name, text])
        if comment.pending {
            UI.append(row, UI.label(Strings.pending, classes: ["caption"] + Style.classes(for: .pending)))
        }
        return row
    }

    /// A placeholder, replaced by the picture once the bytes load (if they
    /// decode as an image) or by a description if they don't.
    private func attachmentView(_ preview: AttachmentPreview) -> Widget {
        let container = UI.vbox()
        let placeholder = UI.label("\(preview.mediaType) · \(preview.sizeLabel)", classes: ["caption", "dim-label"])
        UI.append(container, placeholder)
        Task { @MainActor [media] in
            guard preview.mediaType.hasPrefix("image/"), let bytes = try? await media.data(for: preview) else {
                if (try? await media.data(for: preview)) == nil { UI.setText(placeholder, "\(preview.mediaType) · \(preview.sizeLabel) · not synced yet") }
                return
            }
            let gbytes = bytes.withUnsafeBytes { g_bytes_new($0.baseAddress, gsize($0.count)) }
            var error: UnsafeMutablePointer<GError>?
            guard let texture = gdk_texture_new_from_bytes(gbytes, &error) else {
                g_error_free(error)
                g_bytes_unref(gbytes)
                return
            }
            g_bytes_unref(gbytes)
            let picture = gtk_picture_new_for_paintable(g(texture))!
            g_object_unref(g(texture))
            gtk_picture_set_content_fit(g(picture), GTK_CONTENT_FIT_COVER)
            gtk_widget_set_size_request(picture, -1, 280)
            UI.addClasses(picture, ["attachment"])
            gtk_widget_set_overflow(picture, GTK_OVERFLOW_HIDDEN)
            UI.removeAllChildren(container)
            UI.append(container, picture)
        }
        return container
    }
}
