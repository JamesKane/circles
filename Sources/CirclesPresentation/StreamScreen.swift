import Foundation
public import Observation
public import CirclesCore
public import CirclesKit

public enum StreamFilter: Sendable, Hashable {
    case everything
    /// Posts by members of one of our circles, as on Google+.
    case circle(String)
}

public struct StreamState: Sendable, Equatable {
    public var filter: StreamFilter = .everything
    public var availableFilters: [StreamFilter] = [.everything]
    public var cards: [PostCard] = []
    public var phase: Phase = .idle
    /// Things worth telling the user about since the previous refresh: new
    /// posts from others, and others' comments on our posts. Empty after the
    /// first load. UIs decide whether to notify (e.g. only when unfocused).
    public var arrivals: [Arrival] = []
    /// Goes up with each refresh that produced arrivals.
    public var arrivalGeneration = 0
}

/// Something new, phrased for a notification.
public struct Arrival: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case post, comment }
    public var kind: Kind
    public var title: String
    public var body: String
    public var post: ObjectRef
}

public enum StreamIntent: Sendable {
    case refresh
    /// Syncs with everyone reachable, then refreshes.
    case sync
    case selectFilter(StreamFilter)
    case setPlusOne(ObjectRef, Bool)
    /// Deletes one of our posts.
    case delete(ObjectRef)
}

@MainActor
@Observable
public final class StreamScreenModel: ScreenModel {
    public private(set) var state = StreamState()
    private let account: Account
    private let now: @Sendable () -> Date

    public init(account: Account, now: @escaping @Sendable () -> Date = { Date() }) {
        self.account = account
        self.now = now
    }

    public func perform(_ intent: StreamIntent) async {
        switch intent {
        case .refresh:
            await reload()
        case .sync:
            state.phase = .syncing
            _ = await account.syncAll()
            await reload()
        case .selectFilter(let filter):
            state.filter = filter
            await reload()
        case .setPlusOne(let post, let on):
            await run { try await self.account.setPlusOne(on, on: post) }
            await reload()
        case .delete(let post):
            await run { try await self.account.delete(post: post.id) }
            await reload()
        }
    }

    private func reload() async {
        if state.cards.isEmpty { state.phase = .loading }
        do {
            let items = try await account.stream()
            let circles = await account.circles
            state.availableFilters = [.everything] + circles.map { .circle($0.name) }
            var visible = items
            if case .circle(let name) = state.filter, let circle = circles.first(where: { $0.name == name }) {
                let members = Set(circle.members)
                visible = items.filter { members.contains($0.author) }
            }
            let date = now()
            noteArrivals(in: items)
            state.cards = visible.map { PostCard($0, now: date, me: account.user) }
            state.phase = .idle
        } catch {
            state.phase = .failed(String(describing: error))
        }
    }

    /// What we'd already seen, to tell what's new. Nil before the first load.
    private var seen: (posts: Set<ContentID>, comments: Set<ContentID>)?

    private func noteArrivals(in items: [StreamItem]) {
        let me = account.user
        let posts = Set(items.map(\.id))
        let comments = Set(items.flatMap { $0.comments.map(\.id) })
        defer { seen = (posts, comments) }
        guard let seen else { return } // the first load isn't news
        var arrivals: [Arrival] = []
        for item in items where item.author != me && !seen.posts.contains(item.id) {
            arrivals.append(Arrival(kind: .post, title: "\(item.authorName) posted",
                                    body: Arrival.preview(item.body), post: item.reference))
        }
        for item in items where item.author == me {
            for comment in item.comments where comment.author != me && !comment.pending && !seen.comments.contains(comment.id) {
                arrivals.append(Arrival(kind: .comment, title: "\(comment.authorName) commented on your post",
                                        body: Arrival.preview(comment.body), post: item.reference))
            }
        }
        state.arrivals = arrivals
        if !arrivals.isEmpty { state.arrivalGeneration += 1 }
    }

    private func run(_ operation: @escaping @Sendable () async throws -> Void) async {
        do {
            try await operation()
        } catch {
            state.phase = .failed(String(describing: error))
        }
    }
}

extension Arrival {
    /// The first line or so of a post, for a notification body.
    static func preview(_ text: RichText) -> String {
        let plain = text.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        return plain.count > 120 ? String(plain.prefix(119)) + "…" : plain
    }
}
