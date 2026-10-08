import CGtk
import GtkKit
import CirclesCore
import CirclesKit
import CirclesSync
import CirclesPresentation

/// A drop-down of fixed choices.
@MainActor
func dropDown(_ items: [String], selected: Int = 0) -> Widget {
    let list = gtk_string_list_new(nil)!
    for item in items { gtk_string_list_append(list, item) }
    let widget = gtk_drop_down_new(g(list), nil)!
    gtk_drop_down_set_selected(g(widget), UInt32(selected))
    return widget
}

@MainActor
func selectedIndex(_ dropDown: Widget) -> Int { Int(gtk_drop_down_get_selected(g(dropDown))) }

// MARK: - Communities

/// The communities we own, belong to or are joining.
@MainActor
final class CommunitiesPage {
    let model: CommunitiesScreenModel
    let widget: Widget
    private let list = UI.vbox(spacing: 6)
    private let status = UI.label("", classes: ["dim-label"], wrap: true)
    private let empty = UI.label("No communities yet. Create one, or join with an invite someone shared.",
                                 classes: ["dim-label"], wrap: true, xalign: 0.5)
    private unowned let app: AppController

    init(model: CommunitiesScreenModel, app: AppController) {
        self.model = model
        self.app = app
        let content = UI.vbox(spacing: 12, [status, empty, list])
        UI.setMargins(content, 12)
        widget = page(
            title: "Communities",
            content: UI.scrolled(UI.clamp(content)),
            headerStart: [UI.button(icon: "view-refresh-symbolic", tooltip: "Sync now") { model.send(.sync) }],
            headerEnd: [
                UI.button(icon: "list-add-symbolic", tooltip: "New community") { [unowned app] in Self.create(on: app.window, model) },
                UI.button("Join", tooltip: "Join with an invite") { [unowned app] in Self.join(on: app.window, model) },
            ]
        )
        // "hidden" also fires when a community is pushed on top, so this page
        // keeps observing, and reloads when it's shown again.
        connect(widget, "showing") { model.send(.load) }
        observe { [weak self] in self?.render() }
        model.send(.load)
    }

    private var opened: UserID?

    private func render() {
        let state = model.state
        UI.setText(status, phaseText(state.phase) ?? "")
        UI.setVisible(status, phaseText(state.phase) != nil)
        UI.setVisible(empty, state.communities.isEmpty && state.phase == .idle)
        UI.removeAllChildren(list)
        for row in state.communities {
            var lines = [UI.label(row.name, classes: ["heading"]),
                         UI.label("\(row.detail) · \(row.memberCount) member\(row.memberCount == 1 ? "" : "s")", classes: ["dim-label", "caption"])]
            if !row.description.isEmpty { lines.append(UI.label(row.description, wrap: true)) }
            let text = UI.vbox(spacing: 2, lines)
            UI.expand(text)
            var badge = row.roleLabel
            if row.pendingCount > 0 { badge += " · \(row.pendingCount) waiting" }
            let button = UI.button(classes: ["flat", "card", "post-card"]) { [unowned app] in app.showCommunity(row.community) }
            gtk_button_set_child(g(button), UI.hbox(spacing: 10, [adw_avatar_new(40, row.name, 1)!, text,
                                                               UI.label(badge, classes: ["dim-label", "caption"])]))
            UI.append(list, button)
        }
        // A community just created or joined opens straight away.
        if let id = state.opened, id != opened {
            opened = id
            app.showCommunity(id)
        }
    }

    static func create(on window: Widget, _ model: CommunitiesScreenModel) {
        let name = UI.entry(placeholder: "Name")
        let description = UI.entry(placeholder: "What it's about (optional)")
        let visibility = dropDown(["Private: members only, encrypted", "Public: anyone can read"])
        let policy = dropDown(["Approval needed", "Anyone can join", "Invite only"])
        let fields = UI.vbox(spacing: 8, [name, description, visibility, policy,
                                          UI.label(CommunityStrings.privateHistory, classes: ["dim-label", "caption"], wrap: true)])
        confirm(on: window, heading: "New community", body: "Your device runs it: keep Circles open, or add a pod, so members can reach it.",
                action: "Create", destructive: false, extra: fields) {
            let policies: [JoinPolicy] = [.approval, .open, .inviteOnly]
            model.send(.create(name: UI.text(of: name), description: UI.text(of: description),
                               visibility: selectedIndex(visibility) == 0 ? .private : .public,
                               joinPolicy: policies[selectedIndex(policy)]))
        }
    }

    static func join(on window: Widget, _ model: CommunitiesScreenModel) {
        let invite = UI.entry(placeholder: "circles-community:…")
        confirm(on: window, heading: "Join a community", body: "Paste the invite text someone shared with you.",
                action: "Ask to join", destructive: false, extra: invite) {
            model.send(.join(invite: UI.text(of: invite)))
        }
    }
}

// MARK: - One community

@MainActor
final class CommunityPage {
    let model: CommunityScreenModel
    let widget: Widget
    private let about = UI.label("", wrap: true)
    private let detail = UI.label("", classes: ["dim-label", "caption"], wrap: true)
    private let notice = UI.label("", classes: ["dim-label"], wrap: true)
    private let status = UI.label("", classes: ["dim-label"], wrap: true)
    private let invite = UI.label("", classes: ["success"], wrap: true)
    private let requestsTitle = UI.label("Waiting to join", classes: ["title-4"])
    private let requests = UI.vbox(spacing: 6)
    private let entry = UI.entry(placeholder: "Share something with the community…")
    private let composer: Widget
    private let list = UI.vbox(spacing: 12)
    private let empty = UI.label("No posts yet.", classes: ["dim-label"], xalign: 0.5)
    private let members = UI.vbox(spacing: 6)
    private var rows: [ContentID: PostView] = [:]
    private var order: [ContentID] = []
    private var alive = true
    private let media: MediaLoader
    private unowned let app: AppController

    init(model: CommunityScreenModel, media: MediaLoader, app: AppController) {
        self.model = model
        self.media = media
        self.app = app
        UI.expand(entry)
        let post = UI.button("Post", classes: ["suggested-action"]) { [entry] in
            model.send(.post(UI.text(of: entry)))
            gtk_editable_set_text(g(entry), "")
        }
        composer = UI.hbox(spacing: 6, [entry, post])
        let content = UI.vbox(spacing: 12, [
            about, detail, notice, status, invite,
            requestsTitle, requests,
            composer, empty, list,
            UI.label("Members", classes: ["title-4"]), members,
        ])
        UI.setMargins(content, 12)
        widget = page(
            title: "Community",
            content: UI.scrolled(UI.clamp(content)),
            headerStart: [UI.button(icon: "view-refresh-symbolic", tooltip: "Sync now") { model.send(.sync) }],
            headerEnd: [UI.button("Invite", tooltip: "Copy invite text") { model.send(.makeInvite) }]
        )
        connect(entry, "activate") { [entry] in
            model.send(.post(UI.text(of: entry)))
            gtk_editable_set_text(g(entry), "")
        }
        connect(widget, "hidden") { [unowned self] in alive = false }
        observe(while: { [weak self] in self?.alive ?? false }) { [weak self] in self?.render() }
        model.send(.refresh)
    }

    /// The rendered row for a post (snapshot self-test).
    func row(for id: ContentID) -> PostView? { rows[id] }

    private func render() {
        let state = model.state
        if let header = state.header {
            adw_navigation_page_set_title(g(widget), header.name)
            UI.setText(about, header.description)
            UI.setVisible(about, !header.description.isEmpty)
            UI.setText(detail, "\(header.detail) · \(header.roleLabel)")
        }
        UI.setText(notice, state.notice ?? "")
        UI.setVisible(notice, state.notice != nil)
        UI.setText(status, phaseText(state.phase) ?? "")
        UI.setVisible(status, phaseText(state.phase) != nil)
        UI.setText(invite, "Invite copied. Paste it to someone you'd like to join; they use Join on their Communities page.")
        UI.setVisible(invite, state.invite != nil)
        UI.setVisible(composer, state.canPost)
        UI.setVisible(empty, state.cards.isEmpty && state.phase == .idle && state.canPost)

        UI.setVisible(requestsTitle, !state.requests.isEmpty)
        UI.removeAllChildren(requests)
        for request in state.requests {
            let name = UI.label(request.name, classes: ["heading"])
            UI.expand(name)
            UI.append(requests, UI.hbox(spacing: 8, classes: ["card", "post-card"], [
                adw_avatar_new(32, request.name, 1)!, name,
                UI.button("Turn down", classes: ["flat"]) { [model] in model.send(.reject(request.user)) },
                UI.button("Let in", classes: ["suggested-action"]) { [model] in model.send(.approve(request.user)) },
            ]))
        }

        UI.removeAllChildren(members)
        for member in state.members {
            let name = UI.label(member.name + (member.isOwner ? " (owner)" : ""), classes: ["heading"])
            UI.expand(name)
            let row = UI.hbox(spacing: 8, classes: ["card", "post-card"], [adw_avatar_new(32, member.name, 1)!, name])
            if state.isOwner && !member.isOwner {
                UI.append(row, UI.button(icon: "user-trash-symbolic", classes: ["flat"], tooltip: "Remove from the community") { [unowned app, model] in
                    confirm(on: app.window, heading: "Remove \(member.name)?",
                            body: "They stop receiving the community's posts. In a private community, they can't read anything posted afterwards.",
                            action: "Remove", destructive: true) { model.send(.removeMember(member.user)) }
                })
            }
            UI.append(members, row)
        }

        // Keyed diff of the posts, as in the Stream.
        let ids = state.cards.map(\.id)
        for gone in Set(order).subtracting(ids) {
            if let row = rows.removeValue(forKey: gone) { gtk_box_remove(g(list), row.root) }
        }
        var previous: Widget?
        for card in state.cards {
            let row = rows[card.id] ?? {
                let created = PostView(
                    media: media, showThread: true,
                    onPlusOne: { [model] card in model.send(.setPlusOne(card.reference, !card.plusOnedByMe)) },
                    onOpen: { [unowned app, model] card in Self.comment(on: card, window: app.window, model) },
                    onReshare: { _ in },
                    onDelete: { [unowned app, model] card in
                        confirm(on: app.window, heading: "Remove \(card.authorName)'s post?",
                                body: "It disappears from the community for everyone once they sync.",
                                action: "Remove", destructive: true) { model.send(.removeItem(card.id)) }
                    },
                    onRemoveComment: { [unowned app, model] comment in
                        confirm(on: app.window, heading: "Remove \(comment.authorName)'s comment?",
                                body: "It disappears from the community for everyone once they sync.",
                                action: "Remove", destructive: true) { model.send(.removeItem(comment.id)) }
                    })
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

    static func comment(on card: PostCard, window: Widget, _ model: CommunityScreenModel) {
        let entry = UI.entry(placeholder: "Your comment")
        confirm(on: window, heading: "Comment on \(card.authorName)'s post", body: "", action: "Comment",
                destructive: false, extra: entry) {
            model.send(.comment(on: card.reference, UI.text(of: entry)))
        }
    }
}
