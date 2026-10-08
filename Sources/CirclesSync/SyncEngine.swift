public import CirclesCore
public import CirclesCrypto
import Synchronization

/// The authenticated peer of a session.
public struct PeerInfo: Sendable {
    public let user: UserID
    public let identity: VerifiedIdentity
    /// The certified device that connected, when the transport authenticated
    /// a static key (always, over Noise).
    public let device: DeviceCertificate?

    public init(user: UserID, identity: VerifiedIdentity, device: DeviceCertificate?) {
        self.user = user
        self.identity = identity
        self.device = device
    }
}

/// Who a node will sync with and whose logs it wants.
public struct SyncPolicy: Sendable {
    /// Whether to sync with an authenticated peer at all.
    public var isAllowed: @Sendable (PeerInfo) async -> Bool
    /// The authors whose logs this node wants, normally itself plus contacts.
    /// Asked after the peer's control messages have been handled.
    public var interests: @Sendable () async -> [UserID]
    /// Control messages to send this peer before `ready`.
    public var outgoingControl: @Sendable (PeerInfo) async -> [SignedObject]
    /// Handles a control message from the peer. Throwing records a rejection
    /// but doesn't end the session.
    public var handleControl: @Sendable (SignedObject, PeerInfo) async throws -> Void

    public init(
        isAllowed: @escaping @Sendable (PeerInfo) async -> Bool,
        interests: @escaping @Sendable () async -> [UserID],
        outgoingControl: @escaping @Sendable (PeerInfo) async -> [SignedObject] = { _ in [] },
        handleControl: @escaping @Sendable (SignedObject, PeerInfo) async throws -> Void = { _, _ in }
    ) {
        self.isAllowed = isAllowed
        self.interests = interests
        self.outgoingControl = outgoingControl
        self.handleControl = handleControl
    }

    /// Allows peers by user ID only.
    public init(allowing isAllowed: @escaping @Sendable (UserID) async -> Bool, interests: @escaping @Sendable () async -> [UserID]) {
        self.init(isAllowed: { await isAllowed($0.user) }, interests: interests)
    }
}

public struct SyncReport: Sendable {
    public var peer: UserID?
    /// Entries accepted, per author.
    public var received: [UserID: Int] = [:]
    public var sent = 0
    public var blobsReceived = 0
    public var blobsSent = 0
    /// Control messages handled without error, e.g. a join request reaching
    /// a community's owner. They change state as entries do.
    public var controlsAccepted = 0
    /// Human-readable reasons for entries or documents that were rejected.
    public var rejected: [String] = []
}

/// Runs one sync session over a channel.
public struct SyncEngine: Sendable {
    public let store: any LogStore
    /// This node's signed identity document.
    public let identityDocument: SignedObject
    public let policy: SyncPolicy
    /// Current wall time in Unix milliseconds.
    public let now: @Sendable () -> UInt64
    public var batchSize = 128
    /// The most media chunks to ask for in one session.
    public var maxBlobsPerSession = 1024
    /// At most this many entries kept per author, across their devices, so
    /// a contact can't fill our disk with their own log (docs/DESIGN.md §12).
    public var maxEntriesPerAuthor = 250_000
    /// At most this many media chunks listed by one entry (1 GiB at 256 KiB).
    public var maxBlobsPerEntry = 4096

    public init(store: any LogStore, identityDocument: SignedObject, policy: SyncPolicy, now: @escaping @Sendable () -> UInt64) {
        self.store = store
        self.identityDocument = identityDocument
        self.policy = policy
        self.now = now
    }

    /// Runs one session. An initiator may name the identity it wants to
    /// reach on the responder's device (`target`).
    public func run(over channel: some MessageChannel, target: UserID? = nil) async throws -> SyncReport {
        try await run(over: channel, target: target, received: nil)
    }

    /// Answers an incoming session as whichever identity the initiator asked
    /// for: reads its hello first, then runs the engine `select` returns.
    /// `first` is the session's first frame, when the caller already read it
    /// (e.g. to tell sync from DHT requests).
    public static func respond(
        over channel: some MessageChannel,
        first: [UInt8]? = nil,
        select: @Sendable (UserID?) async throws -> SyncEngine?
    ) async throws -> SyncReport {
        var frame = first
        if frame == nil { frame = try await channel.receive() }
        guard let first = frame else { throw SyncError.connectionClosed }
        let message: SyncMessage
        do {
            message = try CBORDecoder().decode(SyncMessage.self, from: first)
        } catch {
            throw SyncError.malformedMessage(error)
        }
        guard case .hello(let hello) = message else {
            throw SyncError.protocolViolation("expected hello")
        }
        guard let engine = try await select(hello.target) else {
            throw SyncError.protocolViolation("no such identity here")
        }
        return try await engine.run(over: channel, target: nil, received: hello)
    }

    private func run(over channel: some MessageChannel, target: UserID?, received: SyncMessage.Hello?) async throws -> SyncReport {
        var report = SyncReport()

        // Make sure our own identity document is served to peers who want it.
        let me = try CBORDecoder().decode(IdentityDocument.self, from: identityDocument.payload).user
        try await store.saveIdentityDocument(identityDocument, verified: VerifiedIdentity(verifying: identityDocument, for: me))

        try await send(.hello(.init(version: SyncMessage.protocolVersion, identity: identityDocument, target: target)), on: channel)
        let hello: SyncMessage.Hello
        if let received {
            hello = received
        } else {
            guard let first = try await channel.receive() else { throw SyncError.connectionClosed }
            guard case .hello(let message) = try decodeMessage(first) else {
                throw SyncError.protocolViolation("expected hello")
            }
            hello = message
        }
        let peer = try await authenticate(hello, staticKey: channel.remoteStaticKey)
        report.peer = peer.user

        for control in await policy.outgoingControl(peer) {
            try await send(.control(control), on: channel)
        }
        try await send(.ready, on: channel)
        readying: while true {
            guard let bytes = try await channel.receive() else { throw SyncError.connectionClosed }
            switch try decodeMessage(bytes) {
            case .control(let control):
                do {
                    try await policy.handleControl(control, peer)
                    report.controlsAccepted += 1
                } catch {
                    report.rejected.append("control message: \(error)")
                }
            case .ready:
                break readying
            default:
                throw SyncError.protocolViolation("expected control or ready")
            }
        }

        let interests = Set(await policy.interests())
        try await send(.want(try await wants(for: interests)), on: channel)

        let (peerWants, wantsContinuation) = AsyncStream.makeStream(of: [SyncMessage.Want].self)
        let (peerEntriesDone, entriesDoneContinuation) = AsyncStream.makeStream(of: Void.self)
        let (peerBlobWants, blobWantsContinuation) = AsyncStream.makeStream(of: [ContentID].self)
        let requestedBlobs = RequestedBlobs()
        let store = self.store, maxBlobs = maxBlobsPerSession
        return try await withThrowingTaskGroup(of: (entries: Int, blobs: Int).self) { group in
            // Everything we send after `want` comes from this one task, in a
            // fixed order, so `done` always follows our own `wantBlobs`. (The
            // peer stops reading at `done`.) It runs apart from the reading
            // below, so a large response never stops us reading meanwhile.
            group.addTask {
                var sent = 0, blobsSent = 0
                for await wants in peerWants {
                    sent += try await respond(to: wants, on: channel)
                }
                try await send(.entriesDone, on: channel)
                // Ask for chunks only once the peer's entries are all stored.
                for await _ in peerEntriesDone {}
                let needed = try await store.neededBlobs(limit: maxBlobs)
                requestedBlobs.set(needed)
                try await send(.wantBlobs(needed), on: channel)
                for await ids in peerBlobWants {
                    for id in ids {
                        guard let bytes = try await store.blob(id) else { continue }
                        try await send(.blob(id, bytes), on: channel)
                        blobsSent += 1
                    }
                }
                try await send(.done, on: channel)
                return (sent, blobsSent)
            }
            defer {
                wantsContinuation.finish()
                entriesDoneContinuation.finish()
                blobWantsContinuation.finish()
            }

            var receivedWant = false
            var verifiedAuthors: [UserID: VerifiedIdentity] = [:]
            receiving: while true {
                guard let bytes = try await channel.receive() else {
                    throw SyncError.connectionClosed
                }
                switch try decodeMessage(bytes) {
                case .hello, .control, .ready:
                    throw SyncError.protocolViolation("hello, control or ready after want")
                case .entriesDone:
                    entriesDoneContinuation.finish()
                case .wantBlobs(let ids):
                    blobWantsContinuation.yield(Array(ids.prefix(maxBlobsPerSession)))
                    blobWantsContinuation.finish()
                case .blob(let id, let bytes):
                    // Only what we asked for, and only if the bytes match the hash.
                    guard requestedBlobs.take(id), ContentID(hashing: bytes) == id else {
                        report.rejected.append("unrequested or corrupt blob \(id)")
                        continue
                    }
                    try await store.putBlob(bytes)
                    report.blobsReceived += 1
                case .want(let wants):
                    guard !receivedWant else { throw SyncError.protocolViolation("duplicate want") }
                    receivedWant = true
                    wantsContinuation.yield(wants)
                    wantsContinuation.finish()
                case .identity(let document):
                    do {
                        let verified = try await saveIdentity(document, interests: interests)
                        verifiedAuthors[verified.user] = verified
                    } catch {
                        report.rejected.append("identity document: \(error)")
                    }
                case .entries(let author, let entries):
                    guard interests.contains(author) else {
                        report.rejected.append("\(entries.count) unrequested entries for \(author)")
                        continue
                    }
                    if verifiedAuthors[author] == nil {
                        verifiedAuthors[author] = try await store.verifiedIdentity(for: author)
                    }
                    guard let identity = verifiedAuthors[author] else {
                        report.rejected.append("entries for \(author): \(SyncError.unknownAuthor(author))")
                        continue
                    }
                    let accepted = try await ingest(entries, author: identity, report: &report)
                    if accepted > 0 { report.received[author, default: 0] += accepted }
                case .done:
                    break receiving
                }
            }
            if !receivedWant {
                throw SyncError.protocolViolation("done before want")
            }
            blobWantsContinuation.finish()
            for try await sent in group {
                report.sent += sent.entries
                report.blobsSent += sent.blobs
            }
            return report
        }
    }

    // MARK: - Steps

    /// Checks the peer's identity document, that it certifies the key the
    /// peer connected with, and that policy allows the peer.
    private func authenticate(_ hello: SyncMessage.Hello, staticKey: AgreementPublicKey?) async throws -> PeerInfo {
        guard hello.version == SyncMessage.protocolVersion else {
            throw SyncError.unsupportedProtocolVersion(hello.version)
        }
        let claimed: IdentityDocument
        do {
            claimed = try CBORDecoder().decode(IdentityDocument.self, from: hello.identity.payload)
        } catch {
            throw SyncError.malformedMessage(error)
        }
        let verified: VerifiedIdentity
        do {
            verified = try VerifiedIdentity(verifying: hello.identity, for: claimed.user)
        } catch {
            throw SyncError.verificationFailed(error)
        }
        // A peer could present an old document that predates a revocation;
        // judge it by the newest version we know.
        var current = verified
        if let stored = try await store.verifiedIdentity(for: claimed.user), stored.version > verified.version {
            current = stored
        }
        var device: DeviceCertificate?
        if let staticKey {
            device = current.device(withAgreementKey: staticKey, atMillis: now())
            guard device != nil else { throw SyncError.peerNotAuthenticated }
        }
        let peer = PeerInfo(user: current.user, identity: current, device: device)
        guard await policy.isAllowed(peer) else { throw SyncError.peerNotAllowed(verified.user) }
        try await store.saveIdentityDocument(hello.identity, verified: verified)
        return peer
    }

    private func wants(for authors: Set<UserID>) async throws -> [SyncMessage.Want] {
        var result: [SyncMessage.Want] = []
        for author in authors {
            let version = try await store.verifiedIdentity(for: author)?.version ?? 0
            result.append(.init(author: author, identityVersion: version, frontier: try await store.frontier(author: author)))
        }
        return result
    }

    /// Sends newer identity documents and log entries for each wanted author.
    private func respond(to wants: [SyncMessage.Want], on channel: some MessageChannel) async throws -> Int {
        var sent = 0
        for want in wants {
            guard let document = try await store.identityDocument(for: want.author),
                  let identity = try? VerifiedIdentity(verifying: document, for: want.author)
            else { continue }
            if identity.version > want.identityVersion {
                try await send(.identity(document), on: channel)
            }
            for (device, ours) in try await store.frontier(author: want.author).sequences where ours > want.frontier[device] {
                var after = want.frontier[device]
                while after < ours {
                    let batch = try await store.entries(author: want.author, device: device, after: after, limit: batchSize)
                    guard !batch.isEmpty else { break }
                    try await send(.entries(author: want.author, entries: batch), on: channel)
                    after += UInt64(batch.count)
                    sent += batch.count
                }
            }
        }
        return sent
    }

    private func saveIdentity(_ document: SignedObject, interests: Set<UserID>) async throws -> VerifiedIdentity {
        let claimed = try CBORDecoder().decode(IdentityDocument.self, from: document.payload)
        guard interests.contains(claimed.user) else { throw SyncError.unknownAuthor(claimed.user) }
        let verified = try VerifiedIdentity(verifying: document, for: claimed.user)
        try await store.saveIdentityDocument(document, verified: verified)
        return try await store.verifiedIdentity(for: claimed.user) ?? verified
    }

    /// Verifies and appends entries in order. Stops at the first bad entry
    /// for a device, since everything after it would be out of sequence.
    private func ingest(_ entries: [SignedObject], author: VerifiedIdentity, report: inout SyncReport) async throws -> Int {
        var accepted = 0
        var failedDevices: Set<DeviceID> = []
        var stored = try await store.frontier(author: author.user).sequences.values.reduce(0) { $0 + Int(min($1, UInt64(Int.max / 2))) }
        for signed in entries {
            guard let device = signed.signerDevice, !failedDevices.contains(device) else { continue }
            guard stored < maxEntriesPerAuthor else {
                report.rejected.append("entries for \(author.user): over the quota of \(maxEntriesPerAuthor)")
                break
            }
            let head = try await store.head(author: author.user, device: device)
            do {
                let verified = try VerifiedLogEntry(verifying: signed, author: author, after: head)
                guard (verified.entry.blobs?.count ?? 0) <= maxBlobsPerEntry else {
                    report.rejected.append("entry for \(author.user) lists too many media chunks")
                    failedDevices.insert(device) // the log can't continue past it
                    continue
                }
                try await store.append(verified)
                accepted += 1
                stored += 1
            } catch SyncError.outOfSequence(_, let expected, let got) where got < expected {
                continue // already have it
            } catch {
                failedDevices.insert(device)
                report.rejected.append("entry from \(device): \(error)")
            }
        }
        return accepted
    }

    // MARK: - Encoding

    private func send(_ message: SyncMessage, on channel: some MessageChannel) async throws {
        try await channel.send(try CBOREncoder().encode(message))
    }

    private func decodeMessage(_ bytes: [UInt8]) throws -> SyncMessage {
        do {
            return try CBORDecoder().decode(SyncMessage.self, from: bytes)
        } catch {
            throw SyncError.malformedMessage(error)
        }
    }
}

/// The media chunks this side asked for in a session, shared between the
/// task that asks and the loop that receives.
private final class RequestedBlobs: Sendable {
    private let ids = Mutex<Set<ContentID>>([])

    func set(_ new: [ContentID]) {
        ids.withLock { $0 = Set(new) }
    }

    /// Removes `id`, returning whether it had been requested.
    func take(_ id: ContentID) -> Bool {
        ids.withLock { $0.remove(id) != nil }
    }
}
