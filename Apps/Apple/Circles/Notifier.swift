import Foundation
import UserNotifications
import CirclesCore
import CirclesPresentation

/// Notifications for arrivals (new posts, comments on ours), sent only while
/// the app isn't active, as in the GNOME app. Each carries its post, so
/// clicking it opens the post (AppDelegate handles the click).
enum Notifier {
    static func notify(_ arrivals: [Arrival], appIsActive: Bool) {
        guard !appIsActive, !arrivals.isEmpty else { return }
        if arrivals.count > 3, let first = arrivals.first {
            send(title: "\(arrivals.count) new things in Circles", body: first.title, post: first.post, id: "circles-summary")
        } else {
            for arrival in arrivals {
                send(title: arrival.title, body: arrival.body, post: arrival.post, id: "post-\(arrival.post.id)")
            }
        }
    }

    private static func send(title: String, body: String, post: ObjectRef, id: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = ["author": post.author.description, "post": post.id.description]
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }

    /// The post a clicked notification refers to.
    nonisolated static func post(from userInfo: [AnyHashable: Any]) -> ObjectRef? {
        guard let author = (userInfo["author"] as? String).flatMap(UserID.init),
              let id = (userInfo["post"] as? String).flatMap(ContentID.init)
        else { return nil }
        return ObjectRef(author: author, id: id)
    }
}
