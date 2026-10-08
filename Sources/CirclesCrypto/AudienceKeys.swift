public import CirclesCore
import Crypto

/// An opaque, random label for one epoch of one circle's key
/// (docs/DESIGN.md §8.1). Unrelated across epochs and circles, so envelopes
/// reveal neither the circle's name nor that two posts went to the same circle
/// under different epochs.
public struct AudienceKeyID: Sendable, Hashable {
    public let bytes: [UInt8]

    public init(bytes: [UInt8]) throws(IdentifierError) {
        guard bytes.count == 16 else { throw .invalidLength(expected: 16, actual: bytes.count) }
        self.bytes = bytes
    }

    public static func random() -> AudienceKeyID {
        var generator = SystemRandomNumberGenerator()
        return try! AudienceKeyID(bytes: (0..<16).map { _ in generator.next() })
    }
}

extension AudienceKeyID: Codable {
    public init(from decoder: any Decoder) throws {
        try self.init(bytes: decoder.singleValueContainer().decode([UInt8].self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(bytes)
    }
}

/// A symmetric key for one epoch of a circle. Copyable, unlike the identity
/// and device keys, because keyrings hold many of them. swift-crypto's
/// `SymmetricKey` zeroizes its own storage.
public struct AudienceKey: Sendable {
    public let id: AudienceKeyID
    public let epoch: UInt64
    let key: SymmetricKey

    public static func generate(epoch: UInt64) -> AudienceKey {
        AudienceKey(id: .random(), epoch: epoch, key: SymmetricKey(size: .bits256))
    }

    init(id: AudienceKeyID, epoch: UInt64, key: SymmetricKey) {
        self.id = id
        self.epoch = epoch
        self.key = key
    }

    /// Restores a key from storage.
    public init(id: AudienceKeyID, epoch: UInt64, rawKey: [UInt8]) throws(CryptoError) {
        guard rawKey.count == 32 else { throw .invalidKey }
        self.init(id: id, epoch: epoch, key: SymmetricKey(data: rawKey))
    }

    /// The 32-byte key, for the key store only.
    public func exportRawKey() -> [UInt8] {
        key.withUnsafeBytes { Array($0) }
    }
}

/// The owner's side of one circle's key (docs/DESIGN.md §8.1): the current
/// epoch key and the members who hold it. It decides when to rotate and who
/// needs a `KeyGrant`. The circle's name and identity live elsewhere and
/// never touch this type.
public struct CircleKeySchedule: Sendable {
    public private(set) var current: AudienceKey
    public private(set) var members: Set<UserID>
    /// Also rotate when members are added, so new members can't read posts
    /// from before they joined even if they obtain old envelopes.
    public var rotateOnAdd: Bool

    /// A key and the members who must be sent it.
    public struct Distribution: Sendable {
        public let key: AudienceKey
        public let recipients: Set<UserID>
    }

    public init(members: Set<UserID> = [], rotateOnAdd: Bool = false) {
        current = .generate(epoch: 0)
        self.members = members
        self.rotateOnAdd = rotateOnAdd
    }

    /// Restores a schedule from storage.
    public init(current: AudienceKey, members: Set<UserID>, rotateOnAdd: Bool) {
        self.current = current
        self.members = members
        self.rotateOnAdd = rotateOnAdd
    }

    /// The initial distribution: every member needs the current key.
    public var initialDistribution: Distribution {
        Distribution(key: current, recipients: members)
    }

    /// Adds members. Returns nil if nobody new was added.
    public mutating func add(_ users: Set<UserID>) -> Distribution? {
        let added = users.subtracting(members)
        guard !added.isEmpty else { return nil }
        members.formUnion(added)
        return rotateOnAdd ? rotate() : Distribution(key: current, recipients: added)
    }

    /// Removes members and rotates, so they can't read future posts. They
    /// keep posts they already received (docs/DESIGN.md §8.2).
    public mutating func remove(_ users: Set<UserID>) -> Distribution? {
        let removed = users.intersection(members)
        guard !removed.isEmpty else { return nil }
        members.subtract(removed)
        return rotate()
    }

    /// Starts a new epoch. Every remaining member needs the new key.
    @discardableResult
    public mutating func rotate() -> Distribution {
        current = .generate(epoch: current.epoch + 1)
        return Distribution(key: current, recipients: members)
    }
}

/// The audience keys a device holds: its own (to read its own posts) and
/// those granted by others. Keys are indexed by owner as well as ID, so an
/// envelope only opens with a key belonging to its claimed author.
public struct AudienceKeyring: Sendable {
    private struct Slot: Hashable {
        var owner: UserID
        var id: AudienceKeyID
    }

    private var keys: [Slot: AudienceKey] = [:]

    public init() {}

    public mutating func insert(_ key: AudienceKey, owner: UserID) {
        keys[Slot(owner: owner, id: key.id)] = key
    }

    public func key(owner: UserID, id: AudienceKeyID) -> AudienceKey? {
        keys[Slot(owner: owner, id: id)]
    }

    public var count: Int { keys.count }

    /// Every key with its owner, for persisting the keyring.
    public var allKeys: [(owner: UserID, key: AudienceKey)] {
        keys.map { ($0.key.owner, $0.value) }
    }
}
