import CGtk
import GtkKit
import CirclesCore
import CirclesKit
import CirclesPresentation

/// A navigation page with its own header bar, the libadwaita pattern.
@MainActor
func page(title: String, content: Widget, headerStart: [Widget] = [], headerEnd: [Widget] = []) -> Widget {
    let header = adw_header_bar_new()!
    for widget in headerStart { adw_header_bar_pack_start(g(header), widget) }
    for widget in headerEnd { adw_header_bar_pack_end(g(header), widget) }
    let toolbar = adw_toolbar_view_new()!
    adw_toolbar_view_add_top_bar(g(toolbar), header)
    adw_toolbar_view_set_content(g(toolbar), content)
    return UnsafeMutableRawPointer(adw_navigation_page_new(toolbar, title)!).assumingMemoryBound(to: GtkWidget.self)
}

@MainActor
func phaseText(_ phase: Phase) -> String? {
    switch phase {
    case .idle: nil
    case .loading: "Loading…"
    case .syncing: "Syncing with your circles…"
    case .failed(let reason): "Something went wrong: \(reason)"
    }
}

// MARK: - Stream

/// The Stream. Rows are keyed by post ID: existing rows update in place, new
/// ones are inserted, gone ones removed, so a sync doesn't rebuild the list.
@MainActor
final class StreamPage {
    let model: StreamScreenModel
    let widget: Widget
    private let list = UI.vbox(spacing: 12)
    private let status = UI.label("", classes: ["dim-label"], xalign: 0.5)
    private let empty = UI.label("Nothing here yet. Post something, or sync with your circles.", classes: ["dim-label"], wrap: true, xalign: 0.5)
    private let filter: Widget
    private var rows: [ContentID: PostView] = [:]
    private var order: [ContentID] = []
    private var filters: [StreamFilter] = []

    init(model: StreamScreenModel, media: MediaLoader, app: AppController) {
        self.model = model
        self.media = media
        self.app = app
        filter = gtk_drop_down_new_from_strings(nil)!
        let content = UI.vbox(spacing: 12, [status, empty, list])
        UI.setMargins(content, 12)
        widget = page(
            title: "Stream",
            content: UI.scrolled(UI.clamp(content)),
            headerStart: [
                UI.button(icon: "view-refresh-symbolic", tooltip: "Sync") { model.send(.sync) },
                filter,
            ],
            headerEnd: [
                UI.button(icon: "document-edit-symbolic", tooltip: "New post") { app.compose() },
                UI.button(icon: "system-users-symbolic", tooltip: "Circles") { app.showCircles() },
            ]
        )
        connect(filter, "notify::selected") { [unowned self] _ in
            let index = Int(gtk_drop_down_get_selected(g(filter)))
            guard filters.indices.contains(index), filters[index] != model.state.filter else { return }
            model.send(.selectFilter(filters[index]))
        }
        observe { [weak self] in self?.render() }
    }

    private let media: MediaLoader
    private unowned let app: AppController

    /// The rendered row for a post (snapshot self-test).
    func row(for id: ContentID) -> PostView? { rows[id] }

    private func render() {
        let state = model.state
        UI.setText(status, phaseText(state.phase) ?? "")
        UI.setVisible(status, phaseText(state.phase) != nil)
        UI.setVisible(empty, state.cards.isEmpty && state.phase == .idle)

        if state.availableFilters != filters {
            filters = state.availableFilters
            let names = filters.map { filter -> String in
                if case .circle(let name) = filter { return name } else { return "Everything" }
            }
            let list = gtk_string_list_new(nil)!
            for name in names { gtk_string_list_append(list, name) }
            gtk_drop_down_set_model(g(filter), g(list))
            g_object_unref(g(list))
        }
        if let index = filters.firstIndex(of: state.filter), gtk_drop_down_get_selected(g(filter)) != UInt32(index) {
            gtk_drop_down_set_selected(g(filter), UInt32(index))
        }

        // Keyed diff of the post list.
        let ids = state.cards.map(\.id)
        for gone in Set(order).subtracting(ids) {
            if let row = rows.removeValue(forKey: gone) { gtk_box_remove(g(list), row.root) }
        }
        var previous: Widget?
        for card in state.cards {
            let row = rows[card.id] ?? {
                let created = PostView(media: media, showThread: false,
                                       onPlusOne: { [model] card in model.send(.setPlusOne(card.reference, !card.plusOnedByMe)) },
                                       onOpen: { [unowned app] card in app.open(card.reference) },
                                       onReshare: { [unowned app] card in app.open(card.reference) })
                rows[card.id] = created
                gtk_box_append(g(list), created.root)
                return created
            }()
            row.update(card)
            gtk_box_reorder_child_after(g(list), row.root, previous)
            previous = row.root
        }
        order = ids
    }
}

// MARK: - Post

@MainActor
final class PostPage {
    let model: PostScreenModel
    let widget: Widget
    private let status = UI.label("", classes: ["dim-label"], wrap: true)
    private let view: PostView
    private let entry = UI.entry(placeholder: "Add a comment…")
    private var send: Widget!
    private var alive = true

    init(model: PostScreenModel, media: MediaLoader) {
        self.model = model
        view = PostView(media: media, showThread: true,
                        onPlusOne: { _ in model.send(.togglePlusOne) },
                        onOpen: { _ in },
                        onReshare: { _ in model.send(.reshare(comment: "")) })
        UI.expand(entry)
        let content = UI.vbox(spacing: 12, [status, view.root])
        send = UI.button("Comment", classes: ["suggested-action"]) { model.send(.submitComment) }
        let composer = UI.hbox(spacing: 6, [entry, send])
        UI.append(content, composer)
        UI.setMargins(content, 12)
        widget = page(title: "Post", content: UI.scrolled(UI.clamp(content)))
        connect(entry, "changed") { [unowned self] in
            let text = UI.text(of: entry)
            if text != model.state.draft { model.send(.editDraft(text)) }
        }
        connect(entry, "activate") { model.send(.submitComment) }
        connect(widget, "hidden") { [unowned self] in alive = false }
        observe(while: { [weak self] in self?.alive ?? false }) { [weak self] in self?.render() }
        model.send(.load)
    }

    private func render() {
        let state = model.state
        if let card = state.card { view.update(card) }
        UI.setVisible(view.root, state.card != nil)
        UI.setText(status, phaseText(state.phase) ?? "")
        UI.setVisible(status, phaseText(state.phase) != nil)
        UI.setText(ofEditable: entry, state.draft)
        UI.setSensitive(send, state.canSubmitComment)
        UI.setSensitive(entry, state.card?.canComment ?? false)
    }
}

// MARK: - Circles

@MainActor
final class CirclesPage {
    let model: CirclesScreenModel
    let widget: Widget
    private let circles = UI.vbox(spacing: 6)
    private let contacts = UI.vbox(spacing: 6)
    private let newCircle = UI.entry(placeholder: "New circle name")
    private let status = UI.label("", classes: ["error"], wrap: true)

    init(model: CirclesScreenModel) {
        self.model = model
        UI.expand(newCircle)
        let create = UI.button("Create", classes: ["suggested-action"]) { [newCircle] in
            let name = UI.text(of: newCircle).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            model.send(.createCircle(name))
            gtk_editable_set_text(g(newCircle), "")
        }
        let content = UI.vbox(spacing: 12, [
            UI.label("Your circles", classes: ["title-4"]), circles,
            UI.hbox(spacing: 6, [newCircle, create]),
            UI.label("People", classes: ["title-4"]),
            UI.label("Toggle the circles each person is in. They never see your circles or their names.", classes: ["dim-label", "caption"], wrap: true),
            contacts, status,
        ])
        UI.setMargins(content, 12)
        widget = page(title: "Circles", content: UI.scrolled(UI.clamp(content)))
        observe { [weak self] in self?.render() }
        model.send(.load)
    }

    private func render() {
        let state = model.state
        UI.removeAllChildren(circles)
        for circle in state.circles {
            let members = circle.memberNames.isEmpty ? "No one yet" : circle.memberNames.joined(separator: ", ")
            let row = UI.vbox(spacing: 2, classes: ["card", "post-card"], [
                UI.label(circle.name, classes: ["heading"]),
                UI.label(members, classes: ["dim-label"], wrap: true),
            ])
            UI.append(circles, row)
        }
        UI.removeAllChildren(contacts)
        for contact in state.contacts {
            let toggles = UI.hbox(spacing: 4)
            for circle in state.circles {
                let toggle = gtk_toggle_button_new_with_label(circle.name)!
                gtk_toggle_button_set_active(g(toggle), contact.circles.contains(circle.name) ? 1 : 0)
                connect(toggle, "toggled") { [model] in
                    let active = gtk_toggle_button_get_active(g(toggle)) != 0
                    let member = model.state.contacts.first { $0.user == contact.user }?.circles.contains(circle.name) ?? false
                    guard active != member else { return }
                    model.send(active ? .add(contact.user, toCircle: circle.name) : .remove(contact.user, fromCircle: circle.name))
                }
                UI.append(toggles, toggle)
            }
            let avatar = adw_avatar_new(32, contact.name, 1)!
            UI.append(contacts, UI.hbox(spacing: 10, classes: ["card", "post-card"], [avatar, UI.label(contact.name, classes: ["heading"]), toggles]))
        }
        if case .failed(let reason) = state.phase { UI.setText(status, reason) } else { UI.setText(status, "") }
    }
}

import Foundation
