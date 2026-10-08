import Foundation
public import Observation
public import CirclesCore
public import CirclesKit

public struct PostState: Sendable, Equatable {
    public var card: PostCard?
    public var draft = ""
    public var phase: Phase = .idle
    /// We deleted this post; the UI should leave the screen.
    public var deleted = false

    public var canSubmitComment: Bool {
        card?.canComment == true && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public enum PostIntent: Sendable {
    case load
    case editDraft(String)
    case submitComment
    case togglePlusOne
    /// Reshares to everyone, with an optional comment.
    case reshare(comment: String)
    /// Deletes the post (ours only).
    case delete
    /// Removes a comment from our post's thread.
    case removeComment(ContentID)
}

/// One post with its thread.
@MainActor
@Observable
public final class PostScreenModel: ScreenModel {
    public private(set) var state = PostState()
    public let post: ObjectRef
    private let account: Account
    private let now: @Sendable () -> Date

    public init(post: ObjectRef, account: Account, now: @escaping @Sendable () -> Date = { Date() }) {
        self.post = post
        self.account = account
        self.now = now
    }

    public func perform(_ intent: PostIntent) async {
        switch intent {
        case .load:
            await reload()
        case .editDraft(let text):
            state.draft = text
        case .submitComment:
            guard state.canSubmitComment else { return }
            let text = state.draft.trimmingCharacters(in: .whitespacesAndNewlines)
            if await attempt({ try await self.account.comment(RichText(plain: text), on: self.post) }) {
                state.draft = ""
            }
            await reload()
        case .togglePlusOne:
            let on = !(state.card?.plusOnedByMe ?? false)
            await attempt { try await self.account.setPlusOne(on, on: self.post) }
            await reload()
        case .reshare(let comment):
            guard state.card?.canReshare == true else { return }
            await attempt { try await self.account.reshare(self.post, comment: RichText(plain: comment), to: .everyone) }
        case .delete:
            guard state.card?.canDelete == true else { return }
            if await attempt({ try await self.account.delete(post: self.post.id) }) {
                state.deleted = true
                state.card = nil
            }
        case .removeComment(let comment):
            guard state.card?.canDelete == true else { return }
            await attempt { try await self.account.removeComment(comment, from: self.post.id) }
            await reload()
        }
    }

    private func reload() async {
        do {
            let item = try await account.stream().first { $0.id == post.id && $0.author == post.author }
            state.card = item.map { PostCard($0, now: now(), me: account.user) }
            state.phase = item == nil ? .failed("This post isn't available.") : .idle
        } catch {
            state.phase = .failed(String(describing: error))
        }
    }

    @discardableResult
    private func attempt(_ operation: @escaping @Sendable () async throws -> Void) async -> Bool {
        do {
            try await operation()
            return true
        } catch {
            state.phase = .failed(String(describing: error))
            return false
        }
    }
}
