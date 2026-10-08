public import CirclesCore
public import CirclesCrypto

/// Who a node will sync with and whose logs it wants.
public struct SyncPolicy: Sendable {
    /// Whether to sync with an authenticated peer at all.
    public var isAllowed: @Sendable (UserID) async -> Bool
    /// The authors whose logs this node wants, normally itself plus contacts.
    public var interests: @Sendable () async -> [UserID]

    public init(isAllowed: @escaping @Sendable (UserID) async -> Bool, interests: @escaping @Sendable () async -> [UserID]) {
        self.isAllowed = isAllowed
        self.interests = interests
    }
}

public struct SyncReport: Sendable {
    public var peer: UserID?
    /// Entries accepted, per author.
    public var received: [UserID: Int] = [:]
    public var sent = 0
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

    public init(store: any LogStore, identityDocument: SignedObject, policy: SyncPolicy, now: @escaping @Sendable () -> UInt64) {
        self.store = store
        self.identityDocument = identityDocument
        self.policy = policy
        self.now = now
    }

    public func run(over channel: some MessageChannel) async throws -> SyncReport {
        var report = SyncReport()

        // Make sure our own identity document is served to peers who want it.
        let me = try CBORDecoder().decode(IdentityDocument.self, from: identityDocument.payload).user
        try await store.saveIdentityDocument(identityDocument, verified: VerifiedIdentity(verifying: identityDocument, for: me))

        try await send(.hello(.init(version: SyncMessage.protocolVersion, identity: identityDocument)), on: channel)
        guard let first = try await channel.receive() else { throw SyncError.connectionClosed }
        guard case .hello(let hello) = try decodeMessage(first) else {
            throw SyncError.protocolViolation("expected hello")
        }
        let peer = try await authenticate(hello, staticKey: channel.remoteStaticKey)
        report.peer = peer

        let interests = Set(await policy.interests())
        try await send(.want(try await wants(for: interests)), on: channel)

        let (peerWants, wantsContinuation) = AsyncStream.makeStream(of: [SyncMessage.Want].self)
        return try await withThrowingTaskGroup(of: Int.self) { group in
            // Answer the peer's want in a separate task, so a large response
            // never stops us reading what the peer sends meanwhile.
            group.addTask {
                var sent = 0
                for await wants in peerWants {
                    sent += try await respond(to: wants, on: channel)
                }
                try await send(.done, on: channel)
                return sent
            }

            var receivedWant = false
            var verifiedAuthors: [UserID: VerifiedIdentity] = [:]
            receiving: while true {
                guard let bytes = try await channel.receive() else {
                    wantsContinuation.finish()
                    throw SyncError.connectionClosed
                }
                switch try decodeMessage(bytes) {
                case .hello:
                    throw SyncError.protocolViolation("duplicate hello")
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
                wantsContinuation.finish()
                throw SyncError.protocolViolation("done before want")
            }
            for try await sent in group {
                report.sent += sent
            }
            return report
        }
    }

    // MARK: - Steps

    /// Checks the peer's identity document, that it certifies the key the
    /// peer connected with, and that policy allows the peer.
    private func authenticate(_ hello: SyncMessage.Hello, staticKey: AgreementPublicKey?) async throws -> UserID {
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
        if let staticKey {
            let time = now()
            let certified = verified.certificates.values.contains { certificate in
                certificate.agreementKey == staticKey
                    && (try? verified.certificate(for: certificate.device, atMillis: time, requiring: [])) != nil
            }
            guard certified else { throw SyncError.peerNotAuthenticated }
        }
        guard await policy.isAllowed(verified.user) else { throw SyncError.peerNotAllowed(verified.user) }
        try await store.saveIdentityDocument(hello.identity, verified: verified)
        return verified.user
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
        for signed in entries {
            guard let device = signed.signerDevice, !failedDevices.contains(device) else { continue }
            let head = try await store.head(author: author.user, device: device)
            do {
                let verified = try VerifiedLogEntry(verifying: signed, author: author, after: head)
                try await store.append(verified)
                accepted += 1
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
