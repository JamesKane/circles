import Foundation
public import CirclesCore
public import CirclesKit

/// A post ready to render. Everything a backend needs is here, already
/// formatted, so backends contain layout and nothing else.
public struct PostCard: Sendable, Equatable, Identifiable {
    public var id: ContentID
    public var reference: ObjectRef
    public var authorName: String
    public var authorInitials: String
    public var timestamp: String
    public var audienceLabel: String
    public var audienceToken: DesignToken
    public var body: RichText
    public var attachments: [AttachmentPreview]
    public var reshared: ResharedCard?
    public var plusOnes: Int
    public var plusOnedByMe: Bool
    public var comments: [CommentRow]
    public var canComment: Bool
    public var canReshare: Bool
    /// Our own post: we can delete it, and remove comments from its thread.
    public var canDelete: Bool

    init(_ item: StreamItem, now: Date, me: UserID) {
        id = item.id
        reference = item.reference
        authorName = item.authorName
        authorInitials = Format.initials(item.authorName)
        timestamp = Format.relativeTime(item.created, now: now)
        audienceLabel = item.audience == .everyone ? Strings.everyone : Strings.limited
        audienceToken = item.audience == .everyone ? .audiencePublic : .audienceLimited
        body = item.body
        attachments = item.attachments.map(AttachmentPreview.init)
        reshared = item.reshared.map { ResharedCard($0, now: now) }
        plusOnes = item.plusOnes
        plusOnedByMe = item.plusOnedByMe
        let ours = item.author == me
        comments = item.comments.map { CommentRow($0, now: now, removable: ours && !$0.pending) }
        canComment = item.commentsEnabled
        canDelete = ours
        // Only public posts can be reshared (docs/DESIGN.md §9.4).
        canReshare = item.resharesEnabled && item.audience == .everyone
    }
}

public struct CommentRow: Sendable, Equatable, Identifiable {
    public var id: ContentID
    public var authorName: String
    public var timestamp: String
    public var body: RichText
    /// Shown with `DesignToken.pending` and `Strings.pending`.
    public var pending: Bool
    /// The thread is ours, so we can remove this comment (moderation).
    public var canRemove: Bool

    init(_ comment: StreamComment, now: Date, removable: Bool) {
        id = comment.id
        authorName = comment.authorName
        timestamp = Format.relativeTime(comment.created, now: now)
        body = comment.body
        pending = comment.pending
        canRemove = removable
    }
}

public struct ResharedCard: Sendable, Equatable {
    public var authorName: String
    public var timestamp: String
    public var body: RichText
    public var attachments: [AttachmentPreview]

    init(_ post: ResharedPost, now: Date) {
        authorName = post.authorName
        timestamp = Format.relativeTime(post.created, now: now)
        body = post.body
        attachments = post.attachments.map(AttachmentPreview.init)
    }
}

/// An attachment as a placeholder until its bytes are loaded through
/// `MediaLoader`.
public struct AttachmentPreview: Sendable, Equatable, Identifiable {
    public var reference: BlobRef
    public var mediaType: String
    public var sizeLabel: String
    public var width: UInt32?
    public var height: UInt32?

    public var id: ContentID { reference.digest }

    init(_ reference: BlobRef) {
        self.reference = reference
        mediaType = reference.mediaType
        sizeLabel = Format.byteCount(reference.byteCount)
        width = reference.width
        height = reference.height
    }
}

/// Fetches attachment bytes. Backends turn the bytes into native images.
public struct MediaLoader: Sendable {
    let account: Account

    public init(account: Account) {
        self.account = account
    }

    /// The decrypted bytes, or nil if the chunks haven't synced yet.
    public func data(for preview: AttachmentPreview) async throws -> [UInt8]? {
        try await account.attachmentData(preview.reference)
    }
}
