public import CirclesCore
public import CirclesCrypto

/// Persistent storage for logs and identity documents. Implementations must
/// be safe to call concurrently. In practice they're actors.
public protocol LogStore: Sendable {
    func head(author: UserID, device: DeviceID) async throws -> LogHead?
    func frontier(author: UserID) async throws -> Frontier
    /// Appends an entry that must directly follow the current head.
    func append(_ entry: VerifiedLogEntry) async throws
    /// Entries with sequence numbers greater than `sequence`, in order.
    func entries(author: UserID, device: DeviceID, after sequence: UInt64, limit: Int) async throws -> [SignedObject]
    func authors() async throws -> [UserID]

    /// The newest stored identity document for `user`, as received.
    func identityDocument(for user: UserID) async throws -> SignedObject?
    /// Stores a verified identity document if it's newer than the stored one.
    func saveIdentityDocument(_ document: SignedObject, verified: VerifiedIdentity) async throws

    /// A stored blob (an encrypted media chunk), by the hash of its bytes.
    func blob(_ id: ContentID) async throws -> [UInt8]?
    /// Stores a blob under the hash of its bytes, and returns that ID.
    @discardableResult
    func putBlob(_ bytes: [UInt8]) async throws -> ContentID
    /// Blobs referenced by stored entries but not stored yet.
    func neededBlobs(limit: Int) async throws -> [ContentID]
}

extension LogStore {
    /// Every verified entry for `author`, device by device, in sequence order.
    public func allEntries(author: UserID) async throws -> [SignedObject] {
        var result: [SignedObject] = []
        for device in try await frontier(author: author).sequences.keys {
            result += try await entries(author: author, device: device, after: 0, limit: .max)
        }
        return result
    }

    public func verifiedIdentity(for user: UserID) async throws -> VerifiedIdentity? {
        guard let document = try await identityDocument(for: user) else { return nil }
        return try VerifiedIdentity(verifying: document, for: user)
    }
}

public enum LogStoreError: Error, Sendable, Equatable {
    case notNextInSequence
}

/// An in-memory `LogStore`, for tests and short-lived nodes.
public actor MemoryLogStore: LogStore {
    private var logs: [UserID: [DeviceID: [VerifiedLogEntry]]] = [:]
    private var identities: [UserID: (document: SignedObject, version: UInt64)] = [:]
    private var blobs: [ContentID: [UInt8]] = [:]
    private var needed: [ContentID] = []

    public init() {}

    public func head(author: UserID, device: DeviceID) -> LogHead? {
        guard let last = logs[author]?[device]?.last else { return nil }
        return LogHead(sequence: last.entry.sequence, id: last.id)
    }

    public func frontier(author: UserID) -> Frontier {
        Frontier((logs[author] ?? [:]).compactMapValues { $0.last?.entry.sequence })
    }

    public func append(_ entry: VerifiedLogEntry) throws {
        let head = head(author: entry.entry.author, device: entry.entry.device)
        guard entry.entry.sequence == (head?.sequence ?? 0) + 1, entry.entry.previous == head?.id else {
            throw LogStoreError.notNextInSequence
        }
        logs[entry.entry.author, default: [:]][entry.entry.device, default: []].append(entry)
        for id in entry.entry.blobs ?? [] where blobs[id] == nil && !needed.contains(id) {
            needed.append(id)
        }
    }

    public func entries(author: UserID, device: DeviceID, after sequence: UInt64, limit: Int) -> [SignedObject] {
        guard let log = logs[author]?[device], sequence < UInt64(log.count) else { return [] }
        return log[Int(sequence)...].prefix(limit).map(\.signed)
    }

    public func authors() -> [UserID] {
        Array(logs.keys)
    }

    public func identityDocument(for user: UserID) -> SignedObject? {
        identities[user]?.document
    }

    public func saveIdentityDocument(_ document: SignedObject, verified: VerifiedIdentity) {
        if let existing = identities[verified.user], existing.version >= verified.version { return }
        identities[verified.user] = (document, verified.version)
        // Drop entries past a revoked device's last standing one.
        for (device, last) in verified.lastSequences {
            logs[verified.user]?[device]?.removeAll { $0.entry.sequence > last }
        }
    }

    public func blob(_ id: ContentID) -> [UInt8]? {
        blobs[id]
    }

    public func putBlob(_ bytes: [UInt8]) -> ContentID {
        let id = ContentID(hashing: bytes)
        blobs[id] = bytes
        needed.removeAll { $0 == id }
        return id
    }

    public func neededBlobs(limit: Int) -> [ContentID] {
        Array(needed.prefix(limit))
    }
}

extension LogStore {
    /// Creates, signs and appends the next entry in this device's own log.
    @discardableResult
    public func appendLocal(
        _ body: LogBody,
        author: UserID,
        device: borrowing DeviceKeyPair,
        created: HLCTimestamp,
        blobs: [ContentID]? = nil
    ) async throws -> VerifiedLogEntry {
        let deviceID = device.deviceID
        let head = try await head(author: author, device: deviceID)
        let entry = LogEntry(
            author: author, device: deviceID, sequence: (head?.sequence ?? 0) + 1,
            previous: head?.id, created: created, body: body, blobs: blobs
        )
        let verified = try VerifiedLogEntry(signing: entry, with: device)
        try await append(verified)
        return verified
    }
}
