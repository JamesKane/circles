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

    public init(
        author: UserID,
        created: HLCTimestamp,
        body: RichText,
        attachments: [BlobRef] = [],
        reshareOf: ObjectRef? = nil,
        collection: CollectionID? = nil,
        replyPolicy: ReplyPolicy = ReplyPolicy(),
        supersedes: ContentID? = nil
    ) {
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

    public init(author: UserID, target: ObjectRef, kind: ReactionKind, created: HLCTimestamp) {
        self.author = author
        self.target = target
        self.kind = kind
        self.created = created
    }
}
