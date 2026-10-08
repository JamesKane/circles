import CGtk
import GtkKit
import Foundation
import CirclesCore
import CirclesKit
import CirclesPresentation

/// Adds a heading and rows to a vertical box, libadwaita "boxed list" style.
@MainActor
func section(_ title: String, _ rows: [Widget], footer: String? = nil) -> Widget {
    let list = UI.vbox(spacing: 6)
    for row in rows { UI.append(list, row) }
    var children = [UI.label(title, classes: ["heading"]), list]
    if let footer { children.append(UI.label(footer, classes: ["dim-label", "caption"], wrap: true)) }
    return UI.vbox(spacing: 8, children)
}

@MainActor
func cardRow(_ children: [Widget]) -> Widget {
    UI.hbox(spacing: 10, classes: ["card", "post-card"], children)
}

// MARK: - Alert dialogs

/// The most recently presented alert (snapshot self-test).
@MainActor var lastAlert: Widget?

/// A libadwaita alert with Cancel and one action.
@MainActor
@discardableResult
func confirm(on parent: Widget, heading: String, body: String, action: String, destructive: Bool,
             extra: Widget? = nil, _ onConfirm: @escaping @MainActor () -> Void) -> Widget {
    let dialog = adw_alert_dialog_new(heading, body)!
    adw_alert_dialog_add_response(g(dialog), "cancel", "Cancel")
    adw_alert_dialog_add_response(g(dialog), "confirm", action)
    adw_alert_dialog_set_response_appearance(g(dialog), "confirm", destructive ? ADW_RESPONSE_DESTRUCTIVE : ADW_RESPONSE_SUGGESTED)
    adw_alert_dialog_set_default_response(g(dialog), "confirm")
    adw_alert_dialog_set_close_response(g(dialog), "cancel")
    if let extra { adw_alert_dialog_set_extra_child(g(dialog), extra) }
    connect(dialog, "response") { (response: UnsafeMutableRawPointer?) in
        guard let response, String(cString: response.assumingMemoryBound(to: CChar.self)) == "confirm" else { return }
        onConfirm()
    }
    adw_dialog_present(g(dialog), parent)
    lastAlert = g(dialog)
    return g(dialog)
}

// MARK: - Onboarding

@MainActor
final class OnboardingPage {
    let model: OnboardingScreenModel
    let widget: Widget
    private let entry = UI.entry(placeholder: "Your name")
    private var create: Widget!
    private let status = UI.label("", classes: ["error"], wrap: true, xalign: 0.5)

    /// Types a name and presses Create, as a user would (snapshot self-test).
    func fill(name: String) {
        gtk_editable_set_text(g(entry), name)
        _ = gtk_widget_activate(create)
    }

    init(model: OnboardingScreenModel, onDone: @escaping @MainActor (Account) -> Void) {
        self.model = model
        let page = adw_status_page_new()!
        adw_status_page_set_icon_name(g(page), "system-users-symbolic")
        adw_status_page_set_title(g(page), "Welcome to Circles")
        adw_status_page_set_description(g(page), "Share with the people a post is for. Your identity lives on this device, not on anyone's server.")
        create = UI.button("Create my identity", classes: ["suggested-action", "pill"]) { model.send(.create) }
        let form = UI.vbox(spacing: 12, [entry, create, status])
        gtk_widget_set_halign(form, GTK_ALIGN_CENTER)
        gtk_widget_set_size_request(entry, 320, -1)
        adw_status_page_set_child(g(page), form)
        widget = page
        connect(entry, "changed") { [unowned self] in
            let text = UI.text(of: entry)
            if text != model.state.name { model.send(.editName(text)) }
        }
        connect(entry, "activate") { model.send(.create) }
        observe { [weak self] in
            guard let self else { return }
            UI.setSensitive(create, model.state.canCreate)
            if case .failed(let reason) = model.state.phase { UI.setText(status, reason) }
            if model.state.phase == .done, let account = model.account { onDone(account) }
        }
    }
}

// MARK: - People

@MainActor
final class PeoplePage {
    let model: PeopleScreenModel
    let widget: Widget
    private let invite = UI.label("", classes: ["caption", "monospace", "dim-label"], wrap: true)
    private let entry = UI.entry(placeholder: "Paste someone's invite or user ID (circles:…)")
    private var add: Widget!
    private let notice = UI.label("", classes: ["success"], wrap: true)
    private let error = UI.label("", classes: ["error"], wrap: true)
    private let people = UI.vbox(spacing: 6)
    private let window: Widget
    private var removeButtons: [UserID: Widget] = [:]

    /// Presses a person's Remove button (snapshot self-test). Returns the
    /// confirmation dialog it opened. GTK 4 animates an activated button's
    /// press and emits "clicked" a moment later, so this waits for it.
    func pressRemove(_ user: UserID) async -> Widget? {
        guard let button = removeButtons[user] else { return nil }
        return await pressForAlert(button)
    }

    /// Pastes an invite and presses Add (snapshot self-test).
    func paste(invite: String) {
        gtk_editable_set_text(g(entry), invite)
        _ = gtk_widget_activate(add)
    }

    init(model: PeopleScreenModel, window: Widget) {
        self.model = model
        self.window = window
        gtk_label_set_selectable(g(invite), 1)
        gtk_label_set_lines(g(invite), 2)
        gtk_label_set_ellipsize(g(invite), PANGO_ELLIPSIZE_MIDDLE)
        UI.expand(entry)
        let copy = UI.button("Copy my invite", icon: "edit-copy-symbolic") { model.send(.copyMyInvite) }
        add = UI.button("Add", classes: ["suggested-action"]) { model.send(.addContact) }
        let content = UI.vbox(spacing: 18, [
            section("Your invite", [invite, copy], footer: "Send this to someone you want in your circles. They add it, you add theirs, and you can sync."),
            section("Add someone", [UI.hbox(spacing: 6, [entry, add]), notice, error]),
            section("People", [people]),
        ])
        UI.setMargins(content, 12)
        widget = page(title: "People", content: UI.scrolled(UI.clamp(content)))
        connect(entry, "changed") { [unowned self] in
            let text = UI.text(of: entry)
            if text != model.state.inviteDraft { model.send(.editInvite(text)) }
        }
        connect(entry, "activate") { model.send(.addContact) }
        observe { [weak self] in self?.render() }
        model.send(.load)
    }

    private func render() {
        let state = model.state
        UI.setText(invite, state.myInvite)
        UI.setText(ofEditable: entry, state.inviteDraft)
        UI.setSensitive(add, state.canAdd)
        UI.setText(notice, state.notice ?? "")
        UI.setVisible(notice, state.notice != nil)
        if case .failed(let reason) = state.phase { UI.setText(error, reason) } else { UI.setText(error, "") }
        UI.removeAllChildren(people)
        removeButtons = [:]
        if state.people.isEmpty { UI.append(people, UI.label("No one yet.", classes: ["dim-label"])) }
        for person in state.people {
            let circles = person.circles.isEmpty ? "Not in any circle" : person.circles.joined(separator: ", ")
            let text = UI.vbox(spacing: 2, [UI.label(person.name, classes: ["heading"]),
                                            UI.label(circles, classes: ["dim-label", "caption"])])
            UI.expand(text)
            let rename = UI.button(icon: "document-edit-symbolic", classes: ["flat"], tooltip: "Rename") { [unowned self] in
                let entry = UI.entry(placeholder: "Name")
                gtk_editable_set_text(g(entry), person.name)
                confirm(on: window, heading: "Rename \(person.name)", body: "Only you see this name.",
                        action: "Rename", destructive: false, extra: entry) { [model] in
                    model.send(.rename(person.user, to: UI.text(of: entry)))
                }
            }
            let remove = UI.button(icon: "user-trash-symbolic", classes: ["flat"], tooltip: "Remove") { [unowned self] in
                confirm(on: window, heading: "Remove \(person.name)?",
                        body: "They'll be taken out of all your circles and won't see anything you post from now on. They keep what they've already seen.",
                        action: "Remove", destructive: true) { [model] in
                    model.send(.remove(person.user))
                }
            }
            removeButtons[person.user] = remove
            UI.append(people, cardRow([adw_avatar_new(32, person.name, 1)!, text, rename, remove]))
        }
    }
}

// MARK: - Settings

@MainActor
final class SettingsPage {
    let settings: SettingsScreenModel
    let network: NetworkModel
    let widget: Widget
    private let name = UI.label("", classes: ["title-4"])
    private let userID = UI.label("", classes: ["caption", "monospace", "dim-label"], wrap: true)
    private let status = UI.label("", wrap: true)
    private let advertise = gtk_switch_new()!
    private let mapPort = gtk_switch_new()!
    private let publish = gtk_switch_new()!
    private let pods = UI.vbox(spacing: 4)
    private let podEntry = UI.entry(placeholder: "Pod pairing code (circles-pod:…)")
    private let bundle = UI.vbox(spacing: 6)
    private let relays = UI.vbox(spacing: 4)
    private let relayEntry = UI.entry(placeholder: "Relay address (host:port#key)")
    private let notice = UI.label("", classes: ["success"], wrap: true)
    private let error = UI.label("", classes: ["error"], wrap: true)
    private let activity = UI.vbox(spacing: 2)
    private var alive = true

    init(settings: SettingsScreenModel, network: NetworkModel) {
        self.settings = settings
        self.network = network
        gtk_label_set_selectable(g(userID), 1)
        UI.expand(podEntry)
        UI.expand(relayEntry)
        let copyID = UI.button("Copy user ID", icon: "edit-copy-symbolic", classes: ["flat"]) { settings.send(.copyUserID) }
        let addPod = UI.button("Add pod") { settings.send(.addPod) }
        let addRelay = UI.button("Add relay") { settings.send(.addRelay) }
        func switchRow(_ title: String, _ subtitle: String, _ toggle: Widget) -> Widget {
            let text = UI.vbox(spacing: 2, [UI.label(title), UI.label(subtitle, classes: ["dim-label", "caption"], wrap: true)])
            UI.expand(text)
            gtk_widget_set_valign(toggle, GTK_ALIGN_CENTER)
            return cardRow([text, toggle])
        }
        let content = UI.vbox(spacing: 18, [
            section("You", [name, userID, copyID]),
            section("Network", [
                status,
                switchRow("Discoverable on the local network", "Contacts on the same network find this device automatically.", advertise),
                switchRow("Ask the router to forward a port", "Makes this device reachable from outside (PCP, NAT-PMP or UPnP).", mapPort),
                switchRow("Publish the public address", "Lists it in your identity, so contacts can connect directly. Everyone who gets your identity learns it.", publish),
            ]),
            section("Pods", [pods, UI.hbox(spacing: 6, [podEntry, addPod]), bundle],
                    footer: "A pod is an always-on machine you run that keeps your posts available while this device is offline. It can't read them."),
            section("Relays", [relays, UI.hbox(spacing: 6, [relayEntry, addRelay])],
                    footer: "Relays let contacts reach you behind a firewall. They only ever see encrypted data."),
            notice, error,
            section("Recent activity", [activity]),
        ])
        UI.setMargins(content, 12)
        widget = page(title: "Settings", content: UI.scrolled(UI.clamp(content)))

        connect(podEntry, "changed") { [unowned self] in
            let text = UI.text(of: podEntry)
            if text != settings.state.podCodeDraft { settings.send(.editPodCode(text)) }
        }
        connect(relayEntry, "changed") { [unowned self] in
            let text = UI.text(of: relayEntry)
            if text != settings.state.relayDraft { settings.send(.editRelay(text)) }
        }
        for (toggle, keyPath) in [(advertise, \NodePreferences.advertiseOnLocalNetwork), (mapPort, \.mapRouterPort), (publish, \.publishPublicAddress)] {
            onNotify(toggle, property: "active") {
                let on = gtk_switch_get_active(g(toggle)) != 0
                var preferences = network.state.preferences
                guard preferences[keyPath: keyPath] != on else { return }
                preferences[keyPath: keyPath] = on
                network.send(.setPreferences(preferences))
            }
        }
        connect(widget, "hidden") { [unowned self] in alive = false }
        observe(while: { [weak self] in self?.alive ?? false }) { [weak self] in self?.render() }
        settings.send(.load)
    }

    private func render() {
        let state = settings.state, net = network.state
        UI.setText(name, state.displayName)
        UI.setText(userID, state.userID)
        UI.setText(status, net.summary())
        for (toggle, on) in [(advertise, net.preferences.advertiseOnLocalNetwork), (mapPort, net.preferences.mapRouterPort),
                             (publish, net.preferences.publishPublicAddress)] {
            if (gtk_switch_get_active(g(toggle)) != 0) != on { gtk_switch_set_active(g(toggle), on ? 1 : 0) }
        }
        UI.setSensitive(publish, net.preferences.mapRouterPort)

        UI.removeAllChildren(pods)
        if state.pods.isEmpty { UI.append(pods, UI.label("No pods yet.", classes: ["dim-label"])) }
        for pod in state.pods { UI.append(pods, cardRow([UI.label(pod)])) }
        UI.setText(ofEditable: podEntry, state.podCodeDraft)
        UI.removeAllChildren(bundle)
        if state.podBundle != nil {
            UI.append(bundle, UI.label("On the pod, run the pairing command:", classes: ["caption"]))
            UI.append(bundle, UI.button("Copy pairing command", icon: "edit-copy-symbolic", classes: ["suggested-action"]) { [settings] in
                settings.send(.copyPodBundle)
            })
        }

        UI.removeAllChildren(relays)
        if state.relays.isEmpty { UI.append(relays, UI.label("No relays yet.", classes: ["dim-label"])) }
        for relay in state.relays {
            let reachable = net.relays[relay] == true
            UI.append(relays, cardRow([UI.label(relay), UI.label(reachable ? "reachable" : "not connected",
                                                                 classes: ["caption", reachable ? "success" : "dim-label"])]))
        }
        UI.setText(ofEditable: relayEntry, state.relayDraft)
        UI.setText(notice, state.notice ?? "")
        UI.setVisible(notice, state.notice != nil)
        if case .failed(let reason) = state.phase { UI.setText(error, reason) } else { UI.setText(error, "") }

        UI.removeAllChildren(activity)
        if net.activity.isEmpty { UI.append(activity, UI.label("Nothing yet.", classes: ["dim-label", "caption"])) }
        for line in net.activity.prefix(15) { UI.append(activity, UI.label(line, classes: ["caption", "dim-label"], wrap: true)) }
    }
}

/// Activates a button and waits for the alert it opens. GTK 4 animates an
/// activated button's press and emits "clicked" a moment later.
@MainActor
func pressForAlert(_ button: Widget) async -> Widget? {
    lastAlert = nil
    _ = gtk_widget_activate(button)
    for _ in 0..<30 where lastAlert == nil { try? await Task.sleep(for: .milliseconds(50)) }
    return lastAlert
}
