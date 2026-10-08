import Foundation
public import CirclesCore
public import CirclesCrypto
public import CirclesSync
import CirclesMLS
import CirclesStorage

// Communities (docs/DESIGN.md §8.3, "Community design for M5").
//
// A community is an identity of its own. Its owner's device holds the
// community key, is certified by it, and is the community's sequencer: the
// only writer of the community's log, whose order is the order MLS needs.
// Members send their posts to the sequencer through their own logs (sealed to
// its device), and read the community by processing its log in order.

/// What this account knows about one community.
struct CommunityState: Codable, Sendable {
    enum Role: String, Codable, Sendable { case owner, member, pending, removed }

    var community: UserID
    var role: Role
    /// The latest signed `CommunityProfile`.
    var profile: SignedObject
    /// Owner only: the community key.
    var communityKey: [UInt8]?
    /// Pending members of private communities: the KeyPackage and its secrets.
    var joinSecrets: CommunityGroup.JoinSecrets?
    var keyPackageReference: [UInt8]?
    /// An invite to present with our join request (invite-only communities).
    var invite: SignedObject?
    /// Owner, approval policy: requests waiting for a decision.
    var pendingRequests: [PendingRequest] = []
    /// Who's in, as the community log says.
    var roster: [UserID] = []
    /// Members: how far each of the community's device logs has been read.
    var cursor: [String: UInt64] = [:]
    /// Content read so far, in log order (decrypted, for private communities).
    var contents: [StoredContent] = []
    /// Owner: submissions already republished.
    var republished: [ContentID] = []

    struct PendingRequest: Codable, Sendable {
        var request: JoinRequest
        var name: String
    }

    struct StoredContent: Codable, Sendable {
        var content: CommunityContent
        var at: HLCTimestamp
    }

    var decodedProfile: CommunityProfile? {
        try? CBORDecoder().decode(CommunityProfile.self, from: profile.payload)
    }
}

/// A community as a UI shows it in a list.
public struct CommunitySummary: Sendable, Hashable, Identifiable {
    public enum Role: String, Sendable { case owner, member, pending, removed }
    public var community: UserID
    public var name: String
    public var description: String
    public var visibility: CommunityVisibility
    public var joinPolicy: JoinPolicy
    public var role: Role
    public var memberCount: Int
    /// Owner, approval policy: who's waiting.
    public var pendingRequests: [(user: UserID, name: String)]
    public var id: UserID { community }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.community == rhs.community && lhs.name == rhs.name && lhs.role == rhs.role && lhs.memberCount == rhs.memberCount
            && lhs.pendingRequests.map(\.user) == rhs.pendingRequests.map(\.user) && lhs.description == rhs.description
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(community) }
}

/// What one community member hands another to join: the community's
/// identity document and profile, and for invite-only communities a token.
public struct CommunityInviteText: Sendable, Codable {
    public var identityDocument: SignedObject
    public var profile: SignedObject
    public var invite: SignedObject?

    static let prefix = "circles-community:"

    public var text: String {
        get throws { Self.prefix + Base32.encode(try CBOREncoder().encode(self)) }
    }

    public init(text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(Self.prefix), let bytes = Base32.decode(trimmed.dropFirst(Self.prefix.count)) else {
            throw CommunityError.invalidInvite
        }
        self = try CBORDecoder().decode(CommunityInviteText.self, from: bytes)
    }

    init(identityDocument: SignedObject, profile: SignedObject, invite: SignedObject?) {
        self.identityDocument = identityDocument
        self.profile = profile
        self.invite = invite
    }
}

public enum CommunityError: Error, Sendable, Equatable {
    case unknownCommunity
    case notOwner
    case notAMember
    case invalidInvite
    case inviteRequired
    case inviteExpired
    case invalidRequest
    case unknownPost
}

extension Account {
    // MARK: State

    func loadCommunities() throws -> [CommunityState] {
        try files.load([CommunityState].self, from: files.communities) ?? []
    }

    func saveCommunities(_ states: [CommunityState]) throws {
        try files.save(states, to: files.communities, private: true)
    }

    func updateCommunity(_ community: UserID, _ change: (inout CommunityState) throws -> Void) throws {
        var states = try loadCommunities()
        guard let index = states.firstIndex(where: { $0.community == community }) else { throw CommunityError.unknownCommunity }
        try change(&states[index])
        try saveCommunities(states)
    }

    func community(_ community: UserID) throws -> CommunityState {
        guard let state = try loadCommunities().first(where: { $0.community == community }) else {
            throw CommunityError.unknownCommunity
        }
        return state
    }

    private func storageKey() throws -> [UInt8] {
        if let key = try FileIO.read(files.storageKey), key.count == 32 { return key }
        var generator = SystemRandomNumberGenerator()
        let key = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        try FileIO.write(key, to: files.storageKey, private: true)
        return key
    }

    func loadGroup(_ community: UserID) throws -> CommunityGroup? {
        guard let sealed = try FileIO.read(files.mlsState(community)) else { return nil }
        return try CommunityGroup.open(sealed: sealed, with: try storageKey())
    }

    func saveGroup(_ group: CommunityGroup, for community: UserID) throws {
        try FileIO.write(try group.sealed(with: try storageKey()), to: files.mlsState(community), private: true)
    }

    public func communities() throws -> [CommunitySummary] {
        try loadCommunities().compactMap { state in
            guard let profile = state.decodedProfile else { return nil }
            return CommunitySummary(
                community: state.community, name: profile.name, description: profile.description,
                visibility: profile.visibility, joinPolicy: profile.joinPolicy,
                role: CommunitySummary.Role(rawValue: state.role.rawValue) ?? .pending,
                memberCount: state.roster.count,
                pendingRequests: state.pendingRequests.map { ($0.request.user, $0.name) }
            )
        }
    }

    // MARK: Owning a community

    /// Creates a community owned by this account, with this device as its
    /// sequencer. Returns its ID (the community key's public key).
    @discardableResult
    public func createCommunity(name: String, description: String = "", visibility: CommunityVisibility,
                                joinPolicy: JoinPolicy) async throws -> UserID {
        try reload()
        let key = IdentityKeyPair()
        let community = key.userID
        let certificate = try DeviceCertificate.issue(for: device, by: key, capabilities: .author,
                                                      issuedMillis: wallClockMillis(), validForMillis: Self.certificateLifetime)
        var unsigned = try IdentityDocument(user: community, version: 1, certificates: [certificate], displayName: name)
        unsigned.endpoints = Self.communityEndpoints(from: endpoints, device: deviceID)
        let document = try unsigned.signed(by: key)
        try await store.saveIdentityDocument(document, verified: try VerifiedIdentity(verifying: document, for: community))
        let profile = CommunityProfile(community: community, version: 1, name: name, description: description,
                                       visibility: visibility, joinPolicy: joinPolicy, owner: user)
        let signedProfile = try SignedObject(signing: try CBOREncoder().encode(profile), label: .communityProfile, with: key)

        var states = try loadCommunities()
        states.append(CommunityState(community: community, role: .owner, profile: signedProfile,
                                     communityKey: key.exportRawRepresentation(), roster: []))
        try saveCommunities(states)
        if visibility == .private {
            try saveGroup(try CommunityGroup.create(identity: user.multicodecBytes, groupID: community.multicodecBytes), for: community)
        }
        try await refreshCommunityEndpoints()   // certifies our pods
        try await appendToLog(.community(.profile(signedProfile)), as: community)
        try await publish(.identities([identityDocument]), in: community)
        try await publish(.members(added: [user], removed: []), in: community)
        return community
    }

    /// Where members reach a community: our pods, its sequencer's direct
    /// address, and our relays.
    static func communityEndpoints(from mine: Endpoints, device: DeviceID) -> Endpoints? {
        var endpoints = Endpoints()
        endpoints.pods = mine.pods
        endpoints.direct = mine.direct.filter { $0.device == device }
        endpoints.relays = mine.relays
        return endpoints.isEmpty ? nil : endpoints
    }

    /// Re-signs our communities' identity documents when our own endpoints
    /// or pods change, so members can still find them: our pods are
    /// certified by each community as store-and-forward devices.
    func refreshCommunityEndpoints() async throws {
        let mine = try VerifiedIdentity(verifying: identityDocument, for: user)
        let pods = mine.certificates.values.filter { $0.capabilities.contains(.storeAndForward) }
        for state in try loadCommunities() where state.role == .owner {
            guard let rawKey = state.communityKey,
                  let signed = try await store.identityDocument(for: state.community)
            else { continue }
            let key = try IdentityKeyPair(rawRepresentation: rawKey)
            let current = try VerifiedIdentity(verifying: signed, for: state.community)
            var document = current.document
            let wanted = Self.communityEndpoints(from: endpoints, device: deviceID)
            let missing = pods.filter { current.certificates[$0.device] == nil }
            guard document.endpoints != wanted || !missing.isEmpty else { continue }
            for pod in missing {
                document.certificates.append(try DeviceCertificate.issue(
                    device: pod.device, agreementKey: pod.agreementKey, by: key, capabilities: .storeAndForward,
                    issuedMillis: wallClockMillis(), validForMillis: Self.certificateLifetime
                ))
            }
            document.endpoints = wanted
            document.version += 1
            let resigned = try document.signed(by: key)
            try await store.saveIdentityDocument(resigned, verified: try VerifiedIdentity(verifying: resigned, for: state.community))
        }
    }

    /// What our pods need to serve our communities while we're away: each
    /// community's identity document and who's in it.
    func podCommunities() async throws -> [PodCommunity] {
        var result: [PodCommunity] = []
        for state in try loadCommunities() where state.role == .owner {
            guard let document = try await store.identityDocument(for: state.community) else { continue }
            result.append(PodCommunity(identityDocument: document, members: state.roster))
        }
        return result
    }

    /// The text to share so others can join. For invite-only communities,
    /// includes a token (for one person, or anyone holding it).
    public func communityInvite(_ community: UserID, for invitee: UserID? = nil,
                                validFor: Duration = .seconds(7 * 24 * 3600)) async throws -> String {
        let state = try self.community(community)
        guard let document = try await store.identityDocument(for: community) else { throw CommunityError.unknownCommunity }
        var token: SignedObject?
        if state.decodedProfile?.joinPolicy == .inviteOnly {
            guard let rawKey = state.communityKey else { throw CommunityError.notOwner }
            let key = try IdentityKeyPair(rawRepresentation: rawKey)
            let millis = UInt64(validFor.components.seconds) * 1000
            var generator = SystemRandomNumberGenerator()
            let invite = CommunityInvite(community: community, invitee: invitee, expiresMillis: wallClockMillis() + millis,
                                         nonce: (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
            token = try SignedObject(signing: try CBOREncoder().encode(invite), label: .communityInvite, with: key)
        }
        return try CommunityInviteText(identityDocument: document, profile: state.profile, invite: token).text
    }

    /// A sync engine that serves one of our communities: it presents the
    /// community's identity, accepts join requests by policy, and wants
    /// members' logs (where their submissions are).
    public func communityEngine(_ community: UserID) async throws -> SyncEngine {
        guard try self.community(community).role == .owner,
              let document = try await store.identityDocument(for: community)
        else { throw CommunityError.notOwner }
        let communitiesURL = files.communities
        let roster: @Sendable () -> [UserID] = {
            ((try? Files.loadStatic([CommunityState].self, from: communitiesURL)) ?? [])
                .first { $0.community == community }?.roster ?? []
        }
        return SyncEngine(
            store: store,
            identityDocument: document,
            policy: SyncPolicy(
                // Anyone may connect: members to sync, others to ask to join.
                isAllowed: { _ in true },
                interests: { [community] + roster() },
                handleControl: { control, peer in try await self.receiveJoinRequest(control, from: peer, for: community) }
            ),
            now: { wallClockMillis() }
        )
    }

    /// Checks a join request and acts on it by the community's policy.
    func receiveJoinRequest(_ control: SignedObject, from peer: PeerInfo, for community: UserID) async throws {
        let payload = try peer.identity.verify(control, label: .communityJoin, atMillis: wallClockMillis())
        let request = try CBORDecoder().decode(JoinRequest.self, from: payload)
        guard request.community == community, request.user == peer.user else { throw CommunityError.invalidRequest }
        let state = try self.community(community)
        guard let profile = state.decodedProfile, !state.roster.contains(request.user) else { return }
        if profile.visibility == .private {
            guard let keyPackage = request.keyPackage,
                  try CommunityGroup.inspect(keyPackage: keyPackage).identity == request.user.multicodecBytes
            else { throw CommunityError.invalidRequest }
        }
        switch profile.joinPolicy {
        case .open:
            try await admit([request], to: community)
        case .inviteOnly:
            guard let invite = request.invite else { throw CommunityError.inviteRequired }
            let token = try CBORDecoder().decode(CommunityInvite.self,
                                                 from: try invite.verifiedPayload(label: .communityInvite, signer: community.publicKey))
            guard token.community == community, token.invitee == nil || token.invitee == request.user else {
                throw CommunityError.invalidInvite
            }
            guard token.expiresMillis > wallClockMillis() else { throw CommunityError.inviteExpired }
            try await admit([request], to: community)
        case .approval:
            let name = peer.identity.document.displayName ?? String(request.user.description.prefix(20))
            try updateCommunity(community) { state in
                state.pendingRequests.removeAll { $0.request.user == request.user }
                state.pendingRequests.append(.init(request: request, name: name))
            }
        }
    }

    /// Approves a waiting join request (approval policy).
    public func approveJoin(_ user: UserID, in community: UserID) async throws {
        guard let pending = try self.community(community).pendingRequests.first(where: { $0.request.user == user }) else {
            throw CommunityError.invalidRequest
        }
        try await admit([pending.request], to: community)
    }

    public func rejectJoin(_ user: UserID, in community: UserID) throws {
        try updateCommunity(community) { $0.pendingRequests.removeAll { $0.request.user == user } }
    }

    private func admit(_ requests: [JoinRequest], to community: UserID) async throws {
        let state = try self.community(community)
        guard state.role == .owner, let profile = state.decodedProfile else { throw CommunityError.notOwner }
        let users = requests.map(\.user)
        if profile.visibility == .private, var group = try loadGroup(community) {
            let keyPackages = requests.compactMap(\.keyPackage)
            let commit = try group.add(keyPackages: keyPackages)
            try saveGroup(group, for: community) // persist before publishing (MLS contract)
            try await appendToLog(.community(.commit(commit.message)), as: community)
            if let welcome = commit.welcome {
                let references = try keyPackages.map { try CommunityGroup.inspect(keyPackage: $0).reference }
                try await appendToLog(.community(.welcome(welcome, keyPackages: references)), as: community)
            }
        }
        try updateCommunity(community) { $0.pendingRequests.removeAll { users.contains($0.request.user) } }
        // New members of a private community can't read earlier roster
        // changes, so the announcement names everyone.
        let added = profile.visibility == .private ? state.roster + users.filter { !state.roster.contains($0) } : users
        var documents: [SignedObject] = []
        for member in added {
            if member == user { documents.append(identityDocument) }
            else if let document = try await store.identityDocument(for: member) { documents.append(document) }
        }
        if !documents.isEmpty { try await publish(.identities(documents), in: community) }
        try await publish(.members(added: added, removed: []), in: community)
    }

    /// Removes members (owner only). In private communities this rotates the
    /// group's keys, so they can't read what follows.
    public func removeFromCommunity(_ users: [UserID], in community: UserID) async throws {
        let state = try self.community(community)
        guard state.role == .owner, let profile = state.decodedProfile else { throw CommunityError.notOwner }
        let removing = users.filter { state.roster.contains($0) && $0 != user }
        guard !removing.isEmpty else { return }
        if profile.visibility == .private, var group = try loadGroup(community) {
            let commit = try group.remove(identities: removing.map(\.multicodecBytes))
            try saveGroup(group, for: community)
            try await appendToLog(.community(.commit(commit.message)), as: community)
        }
        try await publish(.members(added: [], removed: removing), in: community)
    }

    /// Removes an item from the community (owner moderation).
    public func removeCommunityItem(_ id: ContentID, from community: UserID) async throws {
        guard try self.community(community).role == .owner else { throw CommunityError.notOwner }
        try await publish(.deletion(id), in: community)
    }

    /// Publishes content in our community's log: open for public communities,
    /// MLS-encrypted for private ones. The owner can't decrypt its own MLS
    /// messages, so it records the plaintext as it publishes.
    func publish(_ content: CommunityContent, in community: UserID, blobs: [ContentID]? = nil) async throws {
        let state = try self.community(community)
        guard let profile = state.decodedProfile else { throw CommunityError.unknownCommunity }
        let created = try tick()
        if profile.visibility == .private {
            guard var group = try loadGroup(community) else { throw CommunityError.notOwner }
            let message = try group.encrypt(try CBOREncoder().encode(content))
            try saveGroup(group, for: community)
            try await appendToLog(.community(.sealed(message)), as: community, created: created, blobs: blobs)
        } else {
            try await appendToLog(.community(.open(content)), as: community, created: created, blobs: blobs)
        }
        try updateCommunity(community) { state in
            Self.apply(content, at: created, to: &state)
        }
    }

    static func apply(_ content: CommunityContent, at: HLCTimestamp, to state: inout CommunityState) {
        if case .members(let added, let removed) = content {
            state.roster.removeAll { removed.contains($0) }
            state.roster += added.filter { !state.roster.contains($0) }
        }
        state.contents.append(.init(content: content, at: at))
    }

    /// Republishes members' submissions to our communities. Returns how many.
    @discardableResult
    func processSubmissions(for community: UserID) async throws -> Int {
        let state = try self.community(community)
        guard state.role == .owner else { return 0 }
        let posts = Set(state.contents.compactMap { stored -> ContentID? in
            guard case .item(let item) = stored.content, item.contribution.kind == .post else { return nil }
            return item.contribution.object.contentID
        })
        var done = Set(state.republished)
        var count = 0
        for member in state.roster where member != user {
            guard let identity = try await store.verifiedIdentity(for: member),
                  let document = try await store.identityDocument(for: member)
            else { continue }
            for signed in try await store.allEntries(author: member) {
                guard let entry = try? CBORDecoder().decode(LogEntry.self, from: signed.payload),
                      case .sealedContent(let envelope) = entry.body,
                      let plaintext = try? envelope.open(keyring: AudienceKeyring(), device: device),
                      let item = try? CBORDecoder().decode(ContentItem.self, from: plaintext),
                      !done.contains(item.object.contentID),
                      Self.belongs(item, to: community, posts: posts),
                      (try? identity.verify(item.object, label: item.kind.label, atMillis: entry.created.millis)) != nil
                else { continue }
                try await publish(.item(CommunityItem(contribution: item, contributorIdentity: document)), in: community,
                                  blobs: entry.blobs)
                done.insert(item.object.contentID)
                count += 1
            }
        }
        if count > 0 { try updateCommunity(community) { $0.republished = Array(done) } }
        return count
    }

    /// A post written for the community, or a comment/+1 on one of its posts.
    static func belongs(_ item: ContentItem, to community: UserID, posts: Set<ContentID>) -> Bool {
        switch item.kind {
        case .post:
            (try? CBORDecoder().decode(Post.self, from: item.object.payload))?.community == community
        case .comment, .reaction:
            target(of: item).map { posts.contains($0.id) } ?? false
        default:
            false
        }
    }

    // MARK: Joining a community

    /// Accepts a community invite: stores the community, and for private
    /// communities prepares an MLS KeyPackage. The join request goes out on
    /// the next sync with the community.
    @discardableResult
    public func joinCommunity(invite text: String) async throws -> UserID {
        let invite = try CommunityInviteText(text: text)
        let claimed = try CBORDecoder().decode(IdentityDocument.self, from: invite.identityDocument.payload)
        let community = claimed.user
        let verified = try VerifiedIdentity(verifying: invite.identityDocument, for: community)
        let profileBytes = try invite.profile.verifiedPayload(label: .communityProfile, signer: community.publicKey)
        let profile = try CBORDecoder().decode(CommunityProfile.self, from: profileBytes)
        guard profile.community == community else { throw CommunityError.invalidInvite }
        if profile.joinPolicy == .inviteOnly, invite.invite == nil { throw CommunityError.inviteRequired }
        try await store.saveIdentityDocument(invite.identityDocument, verified: verified)

        var states = try loadCommunities()
        guard !states.contains(where: { $0.community == community && $0.role != .removed }) else { return community }
        states.removeAll { $0.community == community }
        var state = CommunityState(community: community, role: .pending, profile: invite.profile, invite: invite.invite)
        if profile.visibility == .private {
            let secrets = try CommunityGroup.makeKeyPackage(identity: user.multicodecBytes)
            state.joinSecrets = secrets
            state.keyPackageReference = try CommunityGroup.inspect(keyPackage: secrets.keyPackage).reference
        }
        states.append(state)
        try saveCommunities(states)
        return community
    }

    /// Our join request for a community we're pending in, signed by this device.
    func joinRequest(for community: UserID) throws -> SignedObject? {
        guard let state = try loadCommunities().first(where: { $0.community == community }), state.role == .pending else { return nil }
        let request = JoinRequest(community: community, user: user, keyPackage: state.joinSecrets?.keyPackage,
                                  invite: state.invite, createdMillis: wallClockMillis())
        return try SignedObject(encoding: request, label: .communityJoin, with: device)
    }

    /// Reads new entries of every community we belong to (or are joining),
    /// strictly in log order, and for owners republishes members'
    /// submissions. Call after syncing.
    public func processCommunities() async throws {
        for state in try loadCommunities() {
            switch state.role {
            case .owner:
                try await processSubmissions(for: state.community)
            case .member, .pending:
                try await readCommunityLog(state.community)
            case .removed:
                continue
            }
        }
    }

    private func readCommunityLog(_ community: UserID) async throws {
        guard try await store.verifiedIdentity(for: community) != nil else { return }
        var state = try self.community(community)
        var group = try loadGroup(community)
        let frontier = try await store.frontier(author: community)
        for device in frontier.sequences.keys.sorted(by: { $0.description < $1.description }) {
            let key = device.description
            for signed in try await store.entries(author: community, device: device, after: state.cursor[key] ?? 0, limit: .max) {
                guard let entry = try? CBORDecoder().decode(LogEntry.self, from: signed.payload) else { break }
                state.cursor[key] = entry.sequence
                guard case .community(let record) = entry.body else { continue }
                switch record {
                case .profile(let signedProfile):
                    if let bytes = try? signedProfile.verifiedPayload(label: .communityProfile, signer: community.publicKey),
                       let profile = try? CBORDecoder().decode(CommunityProfile.self, from: bytes),
                       profile.version >= state.decodedProfile?.version ?? 0 {
                        state.profile = signedProfile
                    }
                case .open(let content):
                    Self.apply(content, at: entry.created, to: &state)
                    if state.role == .pending, state.roster.contains(user), state.joinSecrets == nil { state.role = .member }
                    if state.role == .member, !state.roster.contains(user) { state.role = .removed }
                case .welcome(let welcome, let references):
                    guard state.role == .pending, let secrets = state.joinSecrets,
                          let reference = state.keyPackageReference, references.contains(reference),
                          let joined = try? CommunityGroup.join(welcome: welcome, secrets: secrets)
                    else { continue }
                    group = joined
                    state.role = .member
                    state.joinSecrets = nil
                case .commit(let commit):
                    guard state.role == .member, var current = group else { continue }
                    if try current.process(commit: commit) == .removed {
                        state.role = .removed
                        group = nil
                    } else {
                        group = current
                    }
                case .sealed(let message):
                    guard state.role == .member, var current = group,
                          let (plaintext, _) = try? current.decrypt(message),
                          let content = try? CBORDecoder().decode(CommunityContent.self, from: plaintext)
                    else { continue }
                    group = current
                    Self.apply(content, at: entry.created, to: &state)
                }
            }
        }
        // MLS state first, then our reading position (MLS contract: persist
        // before acting on what was decrypted).
        if let group { try saveGroup(group, for: community) } else if state.role == .removed {
            try? FileManager.default.removeItem(at: files.mlsState(community))
        }
        let updated = state
        try updateCommunity(community) { $0 = updated }
    }

    // MARK: Posting in a community

    /// Posts to a community. The owner publishes directly; members send the
    /// post to the sequencer (sealed to its device, in our log), and it
    /// appears for everyone once republished.
    @discardableResult
    public func post(_ body: RichText, toCommunity community: UserID, attachments: [Attachment] = []) async throws -> ContentID {
        let state = try self.community(community)
        guard state.role == .owner || state.role == .member else { throw CommunityError.notAMember }
        var references: [BlobRef] = []
        for attachment in attachments {
            let sealed = try MediaEncryption.seal(try LocationScrubber.scrub(attachment.data), mediaType: attachment.mediaType,
                                                  width: attachment.width, height: attachment.height)
            for chunk in sealed.chunks { try await store.putBlob(chunk) }
            references.append(sealed.reference)
        }
        let post = Post(author: user, created: try tick(), body: body, attachments: references, community: community)
        let item = ContentItem(kind: .post, object: try SignedObject(encoding: post, label: .post, with: device))
        try await submit(item, to: community, blobs: references.flatMap(\.chunks))
        return item.object.contentID
    }

    public func comment(_ body: RichText, on post: ObjectRef, inCommunity community: UserID) async throws {
        let comment = Comment(author: user, parent: post, created: try tick(), body: body)
        try await submit(ContentItem(kind: .comment, object: try SignedObject(encoding: comment, label: .comment, with: device)),
                         to: community)
    }

    public func setPlusOne(_ on: Bool, on post: ObjectRef, inCommunity community: UserID) async throws {
        let reaction = Reaction(author: user, target: post, kind: .plusOne, created: try tick(), retracted: !on)
        try await submit(ContentItem(kind: .reaction, object: try SignedObject(encoding: reaction, label: .reaction, with: device)),
                         to: community)
    }

    private func submit(_ item: ContentItem, to community: UserID, blobs: [ContentID] = []) async throws {
        let state = try self.community(community)
        if state.role == .owner {
            try await publish(.item(CommunityItem(contribution: item, contributorIdentity: identityDocument)), in: community,
                              blobs: blobs.isEmpty ? nil : blobs)
            return
        }
        guard state.role == .member, let sequencer = try await store.verifiedIdentity(for: community) else {
            throw CommunityError.notAMember
        }
        let devices = sequencer.certificates.values.filter { $0.capabilities.contains(.author) }.map(\.agreementKey)
        let envelope = try Envelope.seal(try CBOREncoder().encode(item), author: user, to: EnvelopeAudience(devices: devices))
        try await appendToLog(.sealedContent(envelope), blobs: blobs.isEmpty ? nil : blobs)
    }

    // MARK: Reading a community

    /// A community's posts, newest first, with comments and +1s, verified
    /// against each contributor's own signature.
    public func communityFeed(_ community: UserID) throws -> [StreamItem] {
        let state = try self.community(community)
        var removed: Set<ContentID> = []
        var posts: [StreamItem] = []
        var thread: [ContentID: [VerifiedContribution]] = [:]
        for stored in state.contents {
            switch stored.content {
            case .deletion(let id):
                removed.insert(id)
            case .members, .identities:
                continue
            case .item(let item):
                let contribution = item.contribution
                switch contribution.kind {
                case .post:
                    guard let claimed = try? CBORDecoder().decode(Post.self, from: contribution.object.payload),
                          claimed.community == community,
                          let identity = try? VerifiedIdentity(verifying: item.contributorIdentity, for: claimed.author),
                          let post = verifiedPost(contribution, author: claimed.author, identity: identity)
                    else { continue }
                    var entry = streamItem(post, id: contribution.object.contentID, author: claimed.author,
                                           audience: state.decodedProfile?.visibility == .public ? .everyone : .limited, item: contribution)
                    entry.authorName = displayName(of: claimed.author, identity: identity)
                    posts.append(entry)
                case .comment, .reaction:
                    if let verified = verifiedContribution(contribution, contributorIdentity: item.contributorIdentity, pending: false) {
                        thread[verified.post, default: []].append(verified)
                    }
                default:
                    continue
                }
            }
        }
        posts.removeAll { removed.contains($0.id) }
        for index in posts.indices {
            apply((thread[posts[index].id] ?? []).filter { !removed.contains($0.id) }, to: &posts[index])
        }
        return posts.sorted { $0.created > $1.created }
    }

    /// The account that owns a community.
    public func communityOwner(_ community: UserID) throws -> UserID? {
        try self.community(community).decodedProfile?.owner
    }

    /// Who's in a community, by name where we know it.
    public func communityMembers(_ community: UserID) async throws -> [(user: UserID, name: String)] {
        let state = try self.community(community)
        // Identity documents the community published, newest last.
        var published: [UserID: VerifiedIdentity] = [:]
        for stored in state.contents {
            guard case .identities(let documents) = stored.content else { continue }
            for document in documents {
                guard let claimed = try? CBORDecoder().decode(IdentityDocument.self, from: document.payload),
                      let verified = try? VerifiedIdentity(verifying: document, for: claimed.user)
                else { continue }
                published[claimed.user] = verified
            }
        }
        var members: [(UserID, String)] = []
        for member in state.roster {
            let stored = (try? await store.verifiedIdentity(for: member)) ?? nil
            members.append((member, displayName(of: member, identity: stored ?? published[member])))
        }
        return members
    }
}
