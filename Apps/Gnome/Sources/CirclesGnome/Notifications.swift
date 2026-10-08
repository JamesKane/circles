import CGtk
import GtkKit
import CirclesCore
import CirclesPresentation

/// Desktop notifications for arrivals (new posts, comments on ours), sent
/// only while the window isn't focused. Clicking one opens its post through
/// the "app.open-post" action.
@MainActor
final class Notifier {
    private let application: UnsafeMutablePointer<AdwApplication>
    /// In self-test runs, notifications are recorded instead of shown.
    var deliver = true
    private(set) var sent: [(title: String, target: String)] = []

    init(application: UnsafeMutablePointer<AdwApplication>, open: @escaping @MainActor (ObjectRef) -> Void) {
        self.application = application
        let action = g_simple_action_new("open-post", g_variant_type_new("s"))!
        connect(action, "activate") { (parameter: UnsafeMutableRawPointer?) in
            guard let parameter, let target = g_variant_get_string(g(parameter), nil),
                  let post = Notifier.decode(String(cString: target))
            else { return }
            open(post)
        }
        g_action_map_add_action(g(application), g(action))
        g_object_unref(g(action))
    }

    func notify(_ arrivals: [Arrival], windowIsActive: Bool) {
        guard !windowIsActive, !arrivals.isEmpty else { return }
        if arrivals.count > 3, let first = arrivals.first {
            send(title: "\(arrivals.count) new things in Circles", body: first.title, post: first.post, id: "circles-summary")
        } else {
            for arrival in arrivals {
                send(title: arrival.title, body: arrival.body, post: arrival.post, id: "post-" + arrival.post.id.description)
            }
        }
    }

    private func send(title: String, body: String, post: ObjectRef, id: String) {
        let target = Self.encode(post)
        sent.append((title, target))
        guard deliver else { return }
        let notification = g_notification_new(title)!
        g_notification_set_body(notification, body)
        g_notification_set_default_action_and_target_value(notification, "app.open-post", g_variant_new_string(target))
        g_application_send_notification(g(application), id, notification)
        g_object_unref(g(notification))
    }

    /// Fires the "app.open-post" action, as clicking a notification does.
    func activate(target: String) {
        g_action_group_activate_action(g(application), "open-post", g_variant_new_string(target))
    }

    static func encode(_ post: ObjectRef) -> String { "\(post.author)|\(post.id)" }

    static func decode(_ text: String) -> ObjectRef? {
        let parts = text.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let author = UserID(parts[0]), let id = ContentID(parts[1]) else { return nil }
        return ObjectRef(author: author, id: id)
    }
}
