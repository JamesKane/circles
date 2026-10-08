public import Foundation
public import CirclesCore
public import CirclesCrypto
public import CirclesSync

/// A `LogStore` on the file system:
///
///     <root>/logs/<author>/<device>/<sequence, zero-padded>.cbor
///     <root>/identities/<user>.cbor
///
/// Each file holds one encoded `SignedObject` exactly as received. Several
/// processes may share a root (e.g. `circles serve` while `circles post`
/// runs): nothing is cached, and appends use exclusive creation so two
/// writers can never both write the same sequence number.
public actor FileLogStore: LogStore {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    // MARK: Paths

    private static func component(_ user: UserID) -> String { Base32.encode(user.multicodecBytes) }
    private static func component(_ device: DeviceID) -> String { Base32.encode(device.multicodecBytes) }
    private static func fileName(_ sequence: UInt64) -> String {
        let digits = String(sequence)
        return String(repeating: "0", count: max(0, 20 - digits.count)) + digits + ".cbor"
    }

    private func authorDirectory(_ author: UserID) -> URL {
        root.appendingPathComponent("logs").appendingPathComponent(Self.component(author))
    }

    private func deviceDirectory(_ author: UserID, _ device: DeviceID) -> URL {
        authorDirectory(author).appendingPathComponent(Self.component(device))
    }

    private func identityURL(_ user: UserID) -> URL {
        root.appendingPathComponent("identities").appendingPathComponent(Self.component(user) + ".cbor")
    }

    private func lastSequence(_ author: UserID, _ device: DeviceID) -> UInt64 {
        FileIO.contents(of: deviceDirectory(author, device))
            .compactMap { $0.hasSuffix(".cbor") ? UInt64($0.dropLast(5)) : nil }
            .max() ?? 0
    }

    private func readEntry(_ author: UserID, _ device: DeviceID, _ sequence: UInt64) throws -> SignedObject? {
        guard let bytes = try FileIO.read(deviceDirectory(author, device).appendingPathComponent(Self.fileName(sequence))) else {
            return nil
        }
        return try CBORDecoder().decode(SignedObject.self, from: bytes)
    }

    // MARK: LogStore

    public func head(author: UserID, device: DeviceID) throws -> LogHead? {
        let sequence = lastSequence(author, device)
        guard sequence > 0, let entry = try readEntry(author, device, sequence) else { return nil }
        return LogHead(sequence: sequence, id: entry.contentID)
    }

    public func frontier(author: UserID) -> Frontier {
        var sequences: [DeviceID: UInt64] = [:]
        for name in FileIO.contents(of: authorDirectory(author)) {
            guard let bytes = Base32.decode(name), let device = try? DeviceID(multicodecBytes: bytes) else { continue }
            let last = lastSequence(author, device)
            if last > 0 { sequences[device] = last }
        }
        return Frontier(sequences)
    }

    public func append(_ entry: VerifiedLogEntry) throws {
        let (author, device) = (entry.entry.author, entry.entry.device)
        let head = try head(author: author, device: device)
        guard entry.entry.sequence == (head?.sequence ?? 0) + 1, entry.entry.previous == head?.id else {
            throw LogStoreError.notNextInSequence
        }
        let url = deviceDirectory(author, device).appendingPathComponent(Self.fileName(entry.entry.sequence))
        guard try FileIO.createExclusively(try CBOREncoder().encode(entry.signed), at: url) else {
            throw LogStoreError.notNextInSequence
        }
    }

    public func entries(author: UserID, device: DeviceID, after sequence: UInt64, limit: Int) throws -> [SignedObject] {
        var result: [SignedObject] = []
        var next = sequence + 1
        while result.count < limit, let entry = try readEntry(author, device, next) {
            result.append(entry)
            next += 1
        }
        return result
    }

    public func authors() -> [UserID] {
        FileIO.contents(of: root.appendingPathComponent("logs")).compactMap { name in
            Base32.decode(name).flatMap { try? UserID(multicodecBytes: $0) }
        }
    }

    public func identityDocument(for user: UserID) throws -> SignedObject? {
        try FileIO.read(identityURL(user)).map { try CBORDecoder().decode(SignedObject.self, from: $0) }
    }

    public func saveIdentityDocument(_ document: SignedObject, verified: VerifiedIdentity) throws {
        if let existing = try identityDocument(for: verified.user),
           let current = try? VerifiedIdentity(verifying: existing, for: verified.user),
           current.version >= verified.version {
            return
        }
        try FileIO.write(try CBOREncoder().encode(document), to: identityURL(verified.user))
    }
}
