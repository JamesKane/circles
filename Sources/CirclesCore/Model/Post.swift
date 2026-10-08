/// Who may reply to or reshare a post. Google+ let authors turn off both.
public struct ReplyPolicy: Sendable, Hashable, Codable {
    public var commentsEnabled: Bool
    public var resharesEnabled: Bool

    public init(commentsEnabled: Bool = true, resharesEnabled: Bool = true) {
        self.commentsEnabled = commentsEnabled
        self.resharesEnabled = resharesEnabled
    }
}

/// A post (docs/DESIGN.md §9.1). Immutable once signed. An edit is a new
/// post that names the earlier one in `supersedes`.
public struct Post: Sendable, Hashable, Codable {
    public var author: UserID
    public var created: HLCTimestamp
    public var body: RichText
    public var attachments: [BlobRef]
    public var reshareOf: ObjectRef?
    public var collection: CollectionID?
    public var replyPolicy: ReplyPolicy
    public var supersedes: ContentID?
    /// The community this post was written for (docs/DESIGN.md §8.3), if any.
    /// Absent for ordinary posts (added in M5).
    public var community: UserID?

    public init(
        author: UserID,
        created: HLCTimestamp,
        body: RichText,
        attachments: [BlobRef] = [],
        reshareOf: ObjectRef? = nil,
        collection: CollectionID? = nil,
        replyPolicy: ReplyPolicy = ReplyPolicy(),
        supersedes: ContentID? = nil,
        community: UserID? = nil
    ) {
        self.community = community
        self.author = author
        self.created = created
        self.body = body
        self.attachments = attachments
        self.reshareOf = reshareOf
        self.collection = collection
        self.replyPolicy = replyPolicy
        self.supersedes = supersedes
    }
}

/// A comment on a post or on another comment (docs/DESIGN.md §9.4).
public struct Comment: Sendable, Hashable, Codable {
    public var author: UserID
    public var parent: ObjectRef
    public var created: HLCTimestamp
    public var body: RichText
    public var supersedes: ContentID?

    public init(author: UserID, parent: ObjectRef, created: HLCTimestamp, body: RichText, supersedes: ContentID? = nil) {
        self.author = author
        self.parent = parent
        self.created = created
        self.body = body
        self.supersedes = supersedes
    }
}

public enum ReactionKind: String, Sendable, Hashable, Codable, CaseIterable {
    case plusOne
    case rsvpYes
    case rsvpNo
    case rsvpMaybe
}

/// A +1 or an event RSVP. Withdrawing one is a tombstone (docs/DESIGN.md §9.4).
public struct Reaction: Sendable, Hashable, Codable {
    public var author: UserID
    public var target: ObjectRef
    public var kind: ReactionKind
    public var created: HLCTimestamp
    /// True when this withdraws an earlier reaction of the same kind. The
    /// latest reaction per (author, kind) wins. Absent means false.
    public var retracted: Bool?

    public init(author: UserID, target: ObjectRef, kind: ReactionKind, created: HLCTimestamp, retracted: Bool = false) {
        self.author = author
        self.target = target
        self.kind = kind
        self.created = created
        self.retracted = retracted ? true : nil
    }
}

/// The author's request that readers stop showing one of their posts, or a
/// comment in one of their threads (docs/DESIGN.md §3: deletion is a request,
/// not a guarantee). Readers honor it only from the post's author.
public struct Deletion: Sendable, Hashable, Codable {
    public var author: UserID
    /// The post's ID, or the ID of the comment's own signed object.
    public var target: ContentID
    public var created: HLCTimestamp

    public init(author: UserID, target: ContentID, created: HLCTimestamp) {
        self.author = author
        self.target = target
        self.created = created
    }
}
