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
}

public enum StreamIntent: Sendable {
    case refresh
    /// Syncs with everyone reachable, then refreshes.
    case sync
    case selectFilter(StreamFilter)
    case setPlusOne(ObjectRef, Bool)
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
            state.cards = visible.map { PostCard($0, now: date) }
            state.phase = .idle
        } catch {
            state.phase = .failed(String(describing: error))
        }
    }

    private func run(_ operation: @escaping @Sendable () async throws -> Void) async {
        do {
            try await operation()
        } catch {
            state.phase = .failed(String(describing: error))
        }
    }
}
