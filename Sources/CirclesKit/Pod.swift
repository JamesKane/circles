public import Foundation
public import CirclesCore
public import CirclesCrypto
public import CirclesSync
import CirclesNet
public import CirclesStorage
public import CirclesDHT

/// Which contacts a pod serves and keeps logs for. Signed by one of the
/// owner's author devices and sent to the pod as a sync control message
/// (docs/DESIGN.md §5.1). A higher version replaces a lower one.
public struct PodConfig: Sendable, Codable, Equatable {
    public var owner: UserID
    public var version: UInt64
    public var contacts: [UserID]
    /// Communities the owner sequences, which the pod serves to their
    /// members (docs/DESIGN.md §8.3). Absent when none (added in M5).
    public var communities: [PodCommunity]?

    public init(owner: UserID, version: UInt64, contacts: [UserID], communities: [PodCommunity] = []) {
        self.owner = owner
        self.version = version
        self.contacts = contacts
        self.communities = communities.isEmpty ? nil : communities
    }
}

/// One community a pod serves: the community's identity document (which
/// must certify the pod) and its members, who may sync with it. The roster
/// of a private community is thereby visible to the owner's pod.
public struct PodCommunity: Sendable, Codable, Equatable {
    public var identityDocument: SignedObject
    public var members: [UserID]

    public init(identityDocument: SignedObject, members: [UserID]) {
        self.identityDocument = identityDocument
        self.members = members
    }

    var community: UserID? {
        try? CBORDecoder().decode(IdentityDocument.self, from: identityDocument.payload).user
    }
}

/// What a new pod shows so its owner can certify it.
public struct PodPairingCode: Sendable, Codable {
    public var device: DeviceID
    public var agreementKey: AgreementPublicKey
    public var host: String
    public var port: UInt16

    static let prefix = "circles-pod:"

    public var text: String {
        get throws { Self.prefix + Base32.encode(try CBOREncoder().encode(self)) }
    }

    public init(device: DeviceID, agreementKey: AgreementPublicKey, host: String, port: UInt16) {
        self.device = device
        self.agreementKey = agreementKey
        self.host = host
        self.port = port
    }

    public init(text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(Self.prefix), let bytes = Base32.decode(trimmed.dropFirst(Self.prefix.count)) else {
            throw AccountError.invalidInvite
        }
        self = try CBORDecoder().decode(PodPairingCode.self, from: bytes)
    }
}

/// What the owner hands back to the pod: the identity document that
/// certifies it.
public struct PodBundle: Sendable, Codable {
    public var identityDocument: SignedObject

    static let prefix = "circles-pod-bundle:"

    public var text: String {
        get throws { Self.prefix + Base32.encode(try CBOREncoder().encode(self)) }
    }

    public init(identityDocument: SignedObject) {
        self.identityDocument = identityDocument
    }

    public init(text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(Self.prefix), let bytes = Base32.decode(trimmed.dropFirst(Self.prefix.count)) else {
            throw AccountError.invalidInvite
        }
        self = try CBORDecoder().decode(PodBundle.self, from: bytes)
    }
}

/// A pod: an always-on node that stores and forwards one owner's logs and
/// their contacts' logs. It holds ciphertext only. It has no identity key,
/// isn't in any circle, and can't decrypt or author anything.
///
///     <home>/pod/device.cbor   device keys (0600)
///     <home>/pod/state.cbor    address, owner, current config
///     <home>/circles.sqlite    logs, identity documents, media chunks
public actor PodNode {
    public nonisolated let home: URL
    public nonisolated let store: SQLiteLogStore
    public nonisolated let deviceID: DeviceID
    public nonisolated let agreementKey: AgreementPublicKey
    public private(set) var host: String
    public private(set) var port: UInt16
    public private(set) var owner: UserID?
    public private(set) var config: PodConfig?
    /// The pod's DHT node: always on and reachable, so a good one.
    public nonisolated let dht: DHTNode

    private let device: DeviceKeyPair

    struct State: Codable {
        var host: String
        var port: UInt16
        var owner: UserID?
        var config: PodConfig?
    }

    private struct StoredDevice: Codable {
        var signing: [UInt8]
        var agreement: [UInt8]
    }

    private static func files(_ home: URL) -> (device: URL, state: URL, dhtNodes: URL) {
        let pod = home.appendingPathComponent("pod")
        return (pod.appendingPathComponent("device.cbor"), pod.appendingPathComponent("state.cbor"),
                pod.appendingPathComponent("dht-nodes.cbor"))
    }

    /// Creates a pod reachable at `host:port`, returning it and its pairing code.
    public static func create(home: URL, host: String, port: UInt16) async throws -> (PodNode, PodPairingCode) {
        let files = files(home)
        guard !FileManager.default.fileExists(atPath: files.device.path) else { throw AccountError.alreadyExists }
        let device = DeviceKeyPair()
        let raw = device.exportRawRepresentation()
        try FileIO.write(try CBOREncoder().encode(StoredDevice(signing: raw.signingKey, agreement: raw.agreementKey)),
                         to: files.device, private: true)
        try FileIO.write(try CBOREncoder().encode(State(host: host, port: port)), to: files.state)
        let pod = try await open(home: home)
        return (pod, PodPairingCode(device: pod.deviceID, agreementKey: pod.agreementKey, host: host, port: port))
    }

    public static func open(home: URL) async throws -> PodNode {
        let files = files(home)
        guard let deviceBytes = try FileIO.read(files.device), let stateBytes = try FileIO.read(files.state) else {
            throw AccountError.notFound
        }
        let stored = try CBORDecoder().decode(StoredDevice.self, from: deviceBytes)
        let state = try CBORDecoder().decode(State.self, from: stateBytes)
        return PodNode(home: home, store: try await openStore(home: home),
                       device: try DeviceKeyPair(signingKey: stored.signing, agreementKey: stored.agreement), state: state)
    }

    private init(home: URL, store: SQLiteLogStore, device: consuming DeviceKeyPair, state: State) {
        self.home = home
        self.store = store
        deviceID = device.deviceID
        agreementKey = device.agreementPublicKey
        host = state.host
        port = state.port
        owner = state.owner
        config = state.config
        let reference = WeakPod()
        dht = DHTNode(key: device.agreementPublicKey, listenPort: state.port,
                      transport: NoiseDHTTransport { await reference.pod?.makeHandshake(role: .initiator) },
                      now: { wallClockMillis() })
        self.device = device
        reference.pod = self
    }

    /// Updates the address the pod reports in its pairing code, e.g. once the
    /// real port is known.
    public func setAddress(host: String, port: UInt16) async throws {
        self.host = host
        self.port = port
        try saveState()
        await dht.setListenPort(port)
    }

    public var pairingCode: PodPairingCode {
        PodPairingCode(device: deviceID, agreementKey: agreementKey, host: host, port: port)
    }

    private func saveState() throws {
        try FileIO.write(try CBOREncoder().encode(State(host: host, port: port, owner: owner, config: config)),
                         to: Self.files(home).state)
    }

    /// Accepts the owner's bundle: an identity document that certifies this
    /// pod as a store-and-forward device.
    public func pair(_ bundle: PodBundle) async throws -> UserID {
        let claimed = try CBORDecoder().decode(IdentityDocument.self, from: bundle.identityDocument.payload)
        let verified = try VerifiedIdentity(verifying: bundle.identityDocument, for: claimed.user)
        guard let certificate = verified.certificates[deviceID], certificate.agreementKey == agreementKey,
              certificate.capabilities.contains(.storeAndForward)
        else { throw PodError.notCertified }
        try await store.saveIdentityDocument(bundle.identityDocument, verified: verified)
        owner = verified.user
        try saveState()
        return verified.user
    }

    public func makeHandshake(role: NoiseHandshake.Role) -> NoiseHandshake {
        NoiseHandshake(role: role, device: device)
    }

    /// A sync engine that speaks for the owner as their pod: it serves and
    /// stores the owner's and the owner's contacts' logs, and accepts
    /// configuration only from the owner's author devices.
    public func syncEngine() async throws -> SyncEngine {
        guard let owner, let document = try await store.identityDocument(for: owner) else { throw PodError.notPaired }
        let contacts = config?.contacts ?? []
        return SyncEngine(
            store: store,
            identityDocument: document,
            policy: SyncPolicy(
                isAllowed: { peer in peer.user == owner || contacts.contains(peer.user) },
                // The owner brings its communities' logs and collected
                // submissions too.
                interests: {
                    let config = await self.config
                    let communities = config?.communities ?? []
                    return [owner] + (config?.contacts ?? []) + communities.compactMap(\.community) + communities.flatMap(\.members)
                },
                handleControl: { control, peer in try await self.accept(control, from: peer) }
            ),
            now: { wallClockMillis() }
        )
    }

    /// A sync engine that serves one of the owner's communities to its
    /// members: it hands out the community's log and keeps members' logs,
    /// where their submissions wait for the owner. Join requests still go
    /// to the owner.
    public func communityEngine(_ community: UserID) async throws -> SyncEngine {
        guard let entry = config?.communities?.first(where: { $0.community == community }),
              let document = try await store.identityDocument(for: community)
        else { throw PodError.notServing }
        let members = entry.members
        return SyncEngine(
            store: store,
            identityDocument: document,
            policy: SyncPolicy(
                isAllowed: { peer in members.contains(peer.user) },
                interests: { [community] + members }
            ),
            now: { wallClockMillis() }
        )
    }

    /// Answers an incoming session: a DHT request, or sync as the owner or as
    /// one of its communities, whichever the peer asked for.
    @discardableResult
    public func respond(over channel: some MessageChannel) async throws -> SyncReport? {
        guard let first = try await channel.receive() else { return nil }
        if DHTMessage.isDHT(first) {
            try await answerDHT(first, over: channel, node: dht)
            return nil
        }
        return try await SyncEngine.respond(over: channel, first: first) { target in
            guard let target, target != (await self.owner) else { return try await self.syncEngine() }
            return try await self.communityEngine(target)
        }
    }

    /// Rejoins the DHT through `seeds` and the nodes it knew last time, and
    /// keeps the owner's identity document (and its communities') published,
    /// so others can find the owner while the owner's devices are away.
    @discardableResult
    public func maintainDHT(seeds: [DHTContact] = []) async -> (nodes: Int, stored: Int) {
        let files = Self.files(home)
        let remembered = (try? FileIO.read(files.dhtNodes)).flatMap { $0 }.flatMap { try? CBORDecoder().decode([DHTContact].self, from: $0) } ?? []
        let known = await dht.bootstrap(seeds + remembered)
        var stored = 0
        var documents: [SignedObject] = []
        if let owner, let document = try? await store.identityDocument(for: owner) { documents.append(document) }
        for community in config?.communities ?? [] { documents.append(community.identityDocument) }
        for document in documents { stored += await dht.publish(document) }
        if let bytes = try? CBOREncoder().encode(await dht.contacts) { try? FileIO.write(bytes, to: files.dhtNodes) }
        return (known, stored)
    }

    private func accept(_ control: SignedObject, from peer: PeerInfo) async throws {
        guard let owner, peer.user == owner,
              let device = peer.device, device.capabilities.contains(.author),
              control.signer == device.device.publicKey
        else { throw PodError.notFromOwner }
        let payload = try peer.identity.verify(control, label: .podConfig, atMillis: wallClockMillis())
        var config = try CBORDecoder().decode(PodConfig.self, from: payload)
        guard config.owner == owner else { throw PodError.notFromOwner }
        if let current = self.config, current.version >= config.version { return }
        var served: [PodCommunity] = []
        for community in config.communities ?? [] {
            // Serve only communities whose documents certify this pod.
            guard let user = community.community,
                  let verified = try? VerifiedIdentity(verifying: community.identityDocument, for: user),
                  verified.certificates[deviceID]?.capabilities.contains(DeviceCapabilities.storeAndForward) == true,
                  verified.certificates[deviceID]?.agreementKey == agreementKey
            else { continue }
            try await store.saveIdentityDocument(community.identityDocument, verified: verified)
            served.append(community)
        }
        config.communities = served.isEmpty ? nil : served
        self.config = config
        try saveState()
    }
}

final class WeakPod: @unchecked Sendable {
    weak var pod: PodNode?
}

public enum PodError: Error, Sendable, Equatable {
    case notCertified
    case notPaired
    case notFromOwner
    case notServing
}
