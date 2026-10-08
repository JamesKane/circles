import Foundation
public import CirclesCore
import CirclesCrypto
import CirclesSync
import CirclesStorage

// Posting, comments, +1s, reshares, media, and assembling the Stream
// (docs/DESIGN.md §9.1, §9.3, §9.4).

extension Account {
    // MARK: Posting

    @discardableResult
    public func post(
        _ body: RichText, to audience: PostAudience, attachments: [Attachment] = [], replyPolicy: ReplyPolicy = ReplyPolicy()
    ) async throws -> ContentID {
        try reload()
        var references: [BlobRef] = []
        for attachment in attachments {
            // Never post where a photo was taken (LocationScrubber).
            let sealed = try MediaEncryption.seal(try LocationScrubber.scrub(attachment.data), mediaType: attachment.mediaType,
                                                  width: attachment.width, height: attachment.height)
            for chunk in sealed.chunks { try await store.putBlob(chunk) }
            references.append(sealed.reference)
        }
        let created = try tick()
        let post = Post(author: user, created: created, body: body, attachments: references, replyPolicy: replyPolicy)
        let item = ContentItem(kind: .post, object: try SignedObject(encoding: post, label: .post, with: device))
        try await publish(item, to: try audienceKeys(for: audience), created: created,
                          blobs: references.flatMap(\.chunks))
        return item.object.contentID
    }

    /// Reshares a public post, optionally with our own comment, to `audience`.
    /// The original and its author's identity document are embedded, so our
    /// audience can verify it without knowing the original author.
    @discardableResult
    public func reshare(_ original: ObjectRef, comment: RichText = RichText([]), to audience: PostAudience) async throws -> ContentID {
        guard let signed = try await publicPost(original),
              let authorDocument = try await original.author == user ? identityDocument : store.identityDocument(for: original.author)
        else { throw AccountError.unknownPost }
        let originalPost = try CBORDecoder().decode(Post.self, from: signed.payload)
        guard originalPost.replyPolicy.resharesEnabled else { throw AccountError.resharingNotAllowed }
        let created = try tick()
        let post = Post(author: user, created: created, body: comment, reshareOf: original)
        let item = ContentItem(kind: .post, object: try SignedObject(encoding: post, label: .post, with: device),
                               embedded: [signed, authorDocument])
        try await publish(item, to: try audienceKeys(for: audience), created: created)
        return item.object.contentID
    }

    /// The circle keys for an audience; nil means everyone.
    private func audienceKeys(for audience: PostAudience) throws -> [AudienceKey]? {
        guard case .circles(let names) = audience else { return nil }
        guard !names.isEmpty else { throw AccountError.emptyAudience }
        return try names.map { name in
            guard let circle = circles.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw AccountError.unknownCircle(name)
            }
            return try circle.current.audienceKey
        }
    }

    /// Appends content publicly (`keys == nil`) or sealed to circle keys.
    private func publish(_ item: ContentItem, to keys: [AudienceKey]?, created: HLCTimestamp? = nil, blobs: [ContentID] = []) async throws {
        if let keys {
            let envelope = try Envelope.seal(try CBOREncoder().encode(item), author: user, to: EnvelopeAudience(audienceKeys: keys))
            try await appendToLog(.sealedContent(envelope), created: created, blobs: blobs)
        } else {
            try await appendToLog(.publicContent(item), created: created, blobs: blobs)
        }
    }

    // MARK: Deleting

    /// Withdraws one of our posts. Published to the post's own audience, so
    /// nobody outside it learns the post existed. Readers who already have it
    /// hide it once they sync; they can't be forced to forget it.
    public func delete(post id: ContentID) async throws {
        try reload()
        guard let target = try await ownPostIndex()[id] else { throw AccountError.notYours }
        try await publishDeletion(of: id, to: target)
    }

    /// Removes a comment from the thread of one of our posts (moderation).
    public func removeComment(_ comment: ContentID, from post: ContentID) async throws {
        try reload()
        guard let target = try await ownPostIndex()[post] else { throw AccountError.notYours }
        try await publishDeletion(of: comment, to: target)
    }

    private func publishDeletion(of id: ContentID, to post: OwnPost) async throws {
        let deletion = Deletion(author: user, target: id, created: try tick())
        let item = ContentItem(kind: .deletion, object: try SignedObject(encoding: deletion, label: .deletion, with: device))
        try await publish(item, to: post.audienceKeys)
    }

    // MARK: Media

    /// An attachment's bytes, or nil if its chunks haven't arrived yet.
    public func attachmentData(_ reference: BlobRef) async throws -> [UInt8]? {
        var chunks: [[UInt8]] = []
        for id in reference.chunks {
            guard let chunk = try await store.blob(id) else { return nil }
            chunks.append(chunk)
        }
        return try MediaEncryption.open(reference, chunks: chunks)
    }

    // MARK: Comments and +1s

    public func comment(_ body: RichText, on post: ObjectRef) async throws {
        let comment = Comment(author: user, parent: post, created: try tick(), body: body)
        try await contribute(ContentItem(kind: .comment, object: try SignedObject(encoding: comment, label: .comment, with: device)),
                             to: post)
    }

    public func setPlusOne(_ on: Bool, on post: ObjectRef) async throws {
        let reaction = Reaction(author: user, target: post, kind: .plusOne, created: try tick(), retracted: !on)
        try await contribute(ContentItem(kind: .reaction, object: try SignedObject(encoding: reaction, label: .reaction, with: device)),
                             to: post)
    }

    /// Sends a contribution to the post's author (sealed to their devices and
    /// ours, in our log) or, on our own post, republishes it directly.
    private func contribute(_ item: ContentItem, to post: ObjectRef) async throws {
        try reload()
        if post.author == user {
            let index = try await ownPostIndex()
            guard let target = index[post.id] else { throw AccountError.unknownPost }
            if item.kind == .comment, !target.post.replyPolicy.commentsEnabled { throw AccountError.commentsDisabled }
            try await republish(item, contributorIdentity: identityDocument, on: target)
            try markRepublished(item.object.contentID)
            return
        }
        guard let author = try await store.verifiedIdentity(for: post.author) else { throw AccountError.unknownPost }
        let me = try VerifiedIdentity(verifying: identityDocument, for: user)
        let devices = (Array(author.certificates.values) + Array(me.certificates.values))
            .filter { $0.capabilities.contains(.author) }
            .map(\.agreementKey)
        let envelope = try Envelope.seal(try CBOREncoder().encode(item), author: user, to: EnvelopeAudience(devices: devices))
        try await appendToLog(.sealedContent(envelope))
    }

    /// Republishes contacts' comments and +1s on our posts into our log, to
    /// each post's audience. Returns how many were republished.
    @discardableResult
    public func processContributions() async throws -> Int {
        try reload()
        let index = try await ownPostIndex()
        guard !index.isEmpty else { return 0 }
        var done = Set(try files.load([ContentID].self, from: files.threads) ?? [])
        var republished = 0
        for contact in contacts {
            guard let identity = try await store.verifiedIdentity(for: contact.user),
                  let document = try await store.identityDocument(for: contact.user)
            else { continue }
            for signed in try await store.allEntries(author: contact.user) {
                guard let entry = try? CBORDecoder().decode(LogEntry.self, from: signed.payload),
                      case .sealedContent(let envelope) = entry.body,
                      let plaintext = try? envelope.open(keyring: AudienceKeyring(), device: device),
                      let item = try? CBORDecoder().decode(ContentItem.self, from: plaintext),
                      item.kind == .comment || item.kind == .reaction,
                      !done.contains(item.object.contentID),
                      let target = Self.target(of: item), target.author == user,
                      let post = index[target.id],
                      (try? identity.verify(item.object, label: item.kind.label, atMillis: entry.created.millis)) != nil
                else { continue }
                if item.kind == .comment, !post.post.replyPolicy.commentsEnabled { continue }
                try await republish(item, contributorIdentity: document, on: post)
                done.insert(item.object.contentID)
                republished += 1
            }
        }
        if republished > 0 { try files.save(Array(done), to: files.threads) }
        return republished
    }

    private func markRepublished(_ id: ContentID) throws {
        var done = try files.load([ContentID].self, from: files.threads) ?? []
        done.append(id)
        try files.save(done, to: files.threads)
    }

    private func republish(_ contribution: ContentItem, contributorIdentity: SignedObject, on target: OwnPost) async throws {
        let thread = ThreadItem(post: target.id, contribution: contribution, contributorIdentity: contributorIdentity)
        let item = ContentItem(kind: .threadItem, object: try SignedObject(encoding: thread, label: .threadItem, with: device))
        try await publish(item, to: target.audienceKeys)
    }

    struct OwnPost {
        var id: ContentID
        var post: Post
        /// nil for a public post.
        var audienceKeys: [AudienceKey]?
    }

    /// Our own posts by ID, with the keys each was sealed to.
    private func ownPostIndex() async throws -> [ContentID: OwnPost] {
        var index: [ContentID: OwnPost] = [:]
        for signed in try await store.allEntries(author: user) {
            guard let entry = try? CBORDecoder().decode(LogEntry.self, from: signed.payload) else { continue }
            switch entry.body {
            case .publicContent(let item) where item.kind == .post:
                if let post = try? CBORDecoder().decode(Post.self, from: item.object.payload) {
                    index[item.object.contentID] = OwnPost(id: item.object.contentID, post: post, audienceKeys: nil)
                }
            case .sealedContent(let envelope):
                guard let plaintext = try? envelope.open(keyring: keyring),
                      let item = try? CBORDecoder().decode(ContentItem.self, from: plaintext), item.kind == .post,
                      let post = try? CBORDecoder().decode(Post.self, from: item.object.payload)
                else { continue }
                let keys = envelope.audienceWraps.compactMap { keyring.key(owner: user, id: $0.keyID) }
                index[item.object.contentID] = OwnPost(id: item.object.contentID, post: post, audienceKeys: keys)
            default:
                continue
            }
        }
        return index
    }

    private func publicPost(_ reference: ObjectRef) async throws -> SignedObject? {
        for signed in try await store.allEntries(author: reference.author) {
            guard let entry = try? CBORDecoder().decode(LogEntry.self, from: signed.payload),
                  case .publicContent(let item) = entry.body, item.kind == .post,
                  item.object.contentID == reference.id
            else { continue }
            return item.object
        }
        return nil
    }

    static func target(of item: ContentItem) -> ObjectRef? {
        switch item.kind {
        case .comment: (try? CBORDecoder().decode(Comment.self, from: item.object.payload))?.parent
        case .reaction: (try? CBORDecoder().decode(Reaction.self, from: item.object.payload))?.target
        default: nil
        }
    }

    // MARK: The Stream

    /// Every post this user can read, newest first, decrypted and verified,
    /// with its comments and +1s.
    public func stream() async throws -> [StreamItem] {
        try await absorbKeyGrants()
        try await processContributions()

        var items: [StreamItem] = []
        var threads: [ContentID: [VerifiedContribution]] = [:]
        var mine: [VerifiedContribution] = []
        // Deletions count only from the post's author: their posts, and the
        // comments in their threads.
        var deleted: [UserID: Set<ContentID>] = [:]

        for author in [user] + contacts.map(\.user) {
            guard let identity = try await verifiedIdentity(for: author) else { continue }
            for signed in try await store.allEntries(author: author) {
                guard let entry = try? CBORDecoder().decode(LogEntry.self, from: signed.payload),
                      let (item, audience) = open(entry.body)
                else { continue }
                switch item.kind {
                case .post:
                    if let post = verifiedPost(item, author: author, identity: identity) {
                        items.append(streamItem(post, id: item.object.contentID, author: author, audience: audience, item: item))
                    }
                case .threadItem:
                    if let contribution = verifiedThreadItem(item, author: author, identity: identity, at: entry.created) {
                        threads[contribution.post, default: []].append(contribution)
                    }
                case .comment, .reaction:
                    // Our own contributions to others' posts, possibly not yet republished.
                    if author == user, let contribution = verifiedContribution(item, contributorIdentity: identityDocument, pending: true) {
                        mine.append(contribution)
                    }
                case .deletion:
                    if let claimed = try? CBORDecoder().decode(Deletion.self, from: item.object.payload), claimed.author == author,
                       (try? identity.verify(item.object, label: .deletion, atMillis: claimed.created.millis)) != nil {
                        deleted[author, default: []].insert(claimed.target)
                    }
                }
            }
        }

        items.removeAll { deleted[$0.author]?.contains($0.id) == true }
        for index in items.indices {
            let removed = deleted[items[index].author] ?? []
            var thread = (threads[items[index].id] ?? []).filter { !removed.contains($0.id) }
            let republished = Set(thread.map(\.id))
            // Our own not-yet-republished contributions show as pending, unless
            // the author has removed them.
            thread += mine.filter { $0.post == items[index].id && !republished.contains($0.id) && !removed.contains($0.id) }
            apply(thread, to: &items[index])
        }
        return items.sorted { $0.created > $1.created }
    }

    struct VerifiedContribution {
        var id: ContentID
        var post: ContentID
        var author: UserID
        var authorName: String
        var created: HLCTimestamp
        var comment: RichText?
        var plusOne: Bool?
        var pending: Bool
    }

    private func open(_ body: LogBody) -> (ContentItem, StreamItem.Audience)? {
        switch body {
        case .publicContent(let item):
            return (item, .everyone)
        case .sealedContent(let envelope):
            guard let plaintext = try? envelope.open(keyring: keyring, device: device),
                  let item = try? CBORDecoder().decode(ContentItem.self, from: plaintext)
            else { return nil }
            return (item, .limited)
        case .keyGrant:
            return nil
        }
    }

    private func verifiedPost(_ item: ContentItem, author: UserID, identity: VerifiedIdentity) -> Post? {
        guard let claimed = try? CBORDecoder().decode(Post.self, from: item.object.payload), claimed.author == author,
              let payload = try? identity.verify(item.object, label: .post, atMillis: claimed.created.millis)
        else { return nil }
        return try? CBORDecoder().decode(Post.self, from: payload)
    }

    private func streamItem(_ post: Post, id: ContentID, author: UserID, audience: StreamItem.Audience, item: ContentItem) -> StreamItem {
        StreamItem(
            id: id, author: author, authorName: name(of: author), created: post.created, body: post.body,
            audience: audience, attachments: post.attachments,
            reshared: post.reshareOf.flatMap { verifiedReshare(of: $0, embedded: item.embedded ?? []) },
            comments: [], plusOnes: 0, plusOnedByMe: false,
            commentsEnabled: post.replyPolicy.commentsEnabled, resharesEnabled: post.replyPolicy.resharesEnabled
        )
    }

    private func verifiedReshare(of reference: ObjectRef, embedded: [SignedObject]) -> ResharedPost? {
        guard let original = embedded.first(where: { $0.contentID == reference.id }),
              let document = embedded.first(where: { $0.signer == reference.author.publicKey }),
              let identity = try? VerifiedIdentity(verifying: document, for: reference.author),
              let post = verifiedPost(ContentItem(kind: .post, object: original), author: reference.author, identity: identity)
        else { return nil }
        return ResharedPost(id: reference.id, author: reference.author,
                            authorName: displayName(of: reference.author, identity: identity),
                            created: post.created, body: post.body, attachments: post.attachments)
    }

    /// A thread item, checked twice: the post author's signature (it's part
    /// of their thread), then the contributor's own signature.
    private func verifiedThreadItem(_ item: ContentItem, author: UserID, identity: VerifiedIdentity, at created: HLCTimestamp) -> VerifiedContribution? {
        guard let payload = try? identity.verify(item.object, label: .threadItem, atMillis: created.millis),
              let thread = try? CBORDecoder().decode(ThreadItem.self, from: payload),
              let target = Self.target(of: thread.contribution),
              target.author == author, target.id == thread.post
        else { return nil }
        return verifiedContribution(thread.contribution, contributorIdentity: thread.contributorIdentity, pending: false)
    }

    private func verifiedContribution(_ item: ContentItem, contributorIdentity document: SignedObject, pending: Bool) -> VerifiedContribution? {
        guard let target = Self.target(of: item) else { return nil }
        switch item.kind {
        case .comment:
            guard let claimed = try? CBORDecoder().decode(Comment.self, from: item.object.payload),
                  let identity = try? VerifiedIdentity(verifying: document, for: claimed.author),
                  (try? identity.verify(item.object, label: .comment, atMillis: claimed.created.millis)) != nil
            else { return nil }
            return VerifiedContribution(id: item.object.contentID, post: target.id, author: claimed.author,
                                        authorName: displayName(of: claimed.author, identity: identity),
                                        created: claimed.created, comment: claimed.body, pending: pending)
        case .reaction:
            guard let claimed = try? CBORDecoder().decode(Reaction.self, from: item.object.payload), claimed.kind == .plusOne,
                  let identity = try? VerifiedIdentity(verifying: document, for: claimed.author),
                  (try? identity.verify(item.object, label: .reaction, atMillis: claimed.created.millis)) != nil
            else { return nil }
            return VerifiedContribution(id: item.object.contentID, post: target.id, author: claimed.author,
                                        authorName: displayName(of: claimed.author, identity: identity),
                                        created: claimed.created, plusOne: claimed.retracted != true, pending: pending)
        default:
            return nil
        }
    }

    private func apply(_ thread: [VerifiedContribution], to item: inout StreamItem) {
        item.comments = thread.compactMap { contribution in
            contribution.comment.map {
                StreamComment(id: contribution.id, author: contribution.author, authorName: contribution.authorName,
                              created: contribution.created, body: $0, pending: contribution.pending)
            }
        }.sorted { $0.created < $1.created }
        // The latest +1 or retraction per person wins.
        var latest: [UserID: VerifiedContribution] = [:]
        for contribution in thread where contribution.plusOne != nil {
            if let existing = latest[contribution.author], existing.created >= contribution.created { continue }
            latest[contribution.author] = contribution
        }
        item.plusOnes = latest.values.filter { $0.plusOne == true }.count
        item.plusOnedByMe = latest[user]?.plusOne == true
    }

    /// A contact's petname; otherwise the name in their identity document.
    func displayName(of user: UserID, identity: VerifiedIdentity?) -> String {
        if user == self.user || contacts.contains(where: { $0.user == user }) { return name(of: user) }
        return identity?.document.displayName ?? name(of: user)
    }
}
