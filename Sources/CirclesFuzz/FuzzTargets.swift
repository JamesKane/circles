import Foundation
@_spi(Fuzzing) import CirclesCore
import CirclesCrypto
import CirclesSync
import CirclesDHT
import CirclesPush
import CirclesMLS
import CirclesKit

/// Fuzz targets (docs/DESIGN.md §12): each takes arbitrary bytes and must
/// neither crash nor hang, and checks invariants that must hold for any
/// input. Run by libFuzzer (`Fuzz/`) and by the seeded mutation test in the
/// regular suite, so every platform runs them.
public enum FuzzTargets {
    public static let all: [String: @Sendable ([UInt8]) -> Void] = [
        "cbor": cbor,
        "types": types,
        "verify": verify,
        "noise": noise,
        "texts": texts,
        "dht": dht,
        "push": push,
        "sync": sync,
        "mls": mls,
    ]

    /// Inputs a mutator can start from: valid encodings of each kind.
    public static func seeds() throws -> [String: [[UInt8]]] {
        let fixture = Fixture.shared
        let encoder = CBOREncoder()
        var seeds: [String: [[UInt8]]] = [:]
        let typed: [[UInt8]] = [
            try encoder.encode(fixture.identityDocument),
            try encoder.encode(fixture.logEntry.signed),
            try encoder.encode(SyncMessage.hello(.init(version: SyncMessage.protocolVersion, identity: fixture.identityDocument))),
            try encoder.encode(SyncMessage.wantBlobs([ContentID(hashing: [1])])),
            try encoder.encode(SyncMessage.entries(author: fixture.user, entries: [fixture.logEntry.signed])),
            try encoder.encode(DHTMessage.store(fixture.identityDocument, listenPort: 4000)),
            try encoder.encode(DHTMessage.nodes([DHTContact(key: fixture.agreementKey, host: "192.0.2.1", port: 1)], observed: "198.51.100.1")),
            try encoder.encode(PushMessage.register(platform: .test, token: "token", topic: nil)),
            try encoder.encode(PushMessage.ping([PushHandle.random()])),
            try encoder.encode(LogBody.community(.welcome([1, 2, 3], keyPackages: [[4]]))),
            try encoder.encode(fixture.envelope),
        ]
        for name in ["cbor", "types", "verify", "dht", "push"] { seeds[name] = typed }
        seeds["sync"] = typed.map { [UInt8(min($0.count, 255))] + $0 }
        seeds["noise"] = [fixture.noiseMessage1]
        seeds["texts"] = fixture.texts.map { Array($0.utf8) }
        seeds["mls"] = [[0] + fixture.mls.commit, [1] + fixture.mls.welcome, [2] + fixture.mls.application, [3] + fixture.mls.keyPackage]
        return seeds
    }

    // MARK: Targets

    /// Strict CBOR: anything that parses re-encodes to the same bytes.
    static func cbor(_ data: [UInt8]) {
        guard let again = CBORFuzzing.roundTrip(data) else { return }
        precondition(again == data, "CBOR that parsed didn't re-encode identically")
    }

    /// Every wire type: decoding never crashes, and whatever decodes
    /// survives encode → decode unchanged.
    static func types(_ data: [UInt8]) {
        check(SyncMessage.self, data)
        check(DHTMessage.self, data)
        check(PushMessage.self, data)
        check(LogBody.self, data)
        check(LogEntry.self, data)
        check(SignedObject.self, data)
        check(IdentityDocument.self, data)
        check(Envelope.self, data)
        check(CommunityRecord.self, data)
        check(CommunityContent.self, data)
        check(JoinRequest.self, data)
        check(Post.self, data)
        check(PodConfig.self, data)
        check(DHTContact.self, data)
    }

    static func check<T: Codable & Equatable>(_ type: T.Type, _ data: [UInt8]) {
        guard let value = try? CBORDecoder().decode(T.self, from: data) else { return }
        guard let encoded = try? CBOREncoder().encode(value) else { preconditionFailure("decoded \(T.self) didn't encode") }
        let again = try? CBORDecoder().decode(T.self, from: encoded)
        precondition(again == value, "\(T.self) changed through encode → decode")
    }

    /// Signature and certificate checking on arbitrary signed objects.
    static func verify(_ data: [UInt8]) {
        let fixture = Fixture.shared
        guard let signed = try? CBORDecoder().decode(SignedObject.self, from: data) else { return }
        if let claimed = try? CBORDecoder().decode(IdentityDocument.self, from: signed.payload) {
            _ = try? VerifiedIdentity(verifying: signed, for: claimed.user)
        }
        _ = try? VerifiedLogEntry(verifying: signed, author: fixture.identity, after: nil)
        _ = try? fixture.identity.verify(signed, label: .post, atMillis: 1)
        if let envelope = try? CBORDecoder().decode(Envelope.self, from: data) {
            _ = try? fixture.openEnvelope(envelope)
        }
    }

    /// The Noise responder reading an arbitrary first message, and the
    /// initiator reading an arbitrary second one.
    static func noise(_ data: [UInt8]) {
        var responder = NoiseHandshake(role: .responder, device: DeviceKeyPair())
        _ = try? responder.readMessage(data)
        var initiator = NoiseHandshake(role: .initiator, device: DeviceKeyPair())
        _ = try? initiator.writeMessage()
        _ = try? initiator.readMessage(data)
    }

    /// Every pasteable text: invites, community invites, pod codes, relay
    /// and DHT node addresses, user IDs.
    static func texts(_ data: [UInt8]) {
        let text = String(decoding: data, as: UTF8.self)
        _ = try? Invite(text: text)
        _ = try? CommunityInviteText(text: text)
        _ = try? PodPairingCode(text: text)
        _ = try? PodBundle(text: text)
        _ = try? RelayIdentity.parse(address: text)
        _ = try? PushClient.parse(address: text)
        _ = try? DHTNodeText.contact(from: text)
        _ = UserID(text)
        _ = ContentID(text)
    }

    /// A DHT node answering an arbitrary request.
    static func dht(_ data: [UInt8]) {
        guard let request = try? CBORDecoder().decode(DHTMessage.self, from: data) else { return }
        blocking {
            let node = DHTNode(key: Fixture.shared.agreementKey, listenPort: 1, transport: NoTransport(), now: { 1 })
            _ = await node.handle(request, from: DHTContact(key: Fixture.shared.agreementKey, host: "192.0.2.9", port: 9),
                                  observedHost: "192.0.2.9")
        }
    }

    /// The push relay answering an arbitrary request.
    static func push(_ data: [UInt8]) {
        guard let request = try? CBORDecoder().decode(PushMessage.self, from: data) else { return }
        blocking {
            guard let relay = try? PushRelay(senders: [.test: RecordingSender()], file: nil) else { return }
            _ = await relay.handle(request, from: Fixture.shared.agreementKey)
        }
    }

    /// A sync session: a valid hello from a known peer, then arbitrary
    /// frames (each a length byte and that many bytes), then the peer
    /// hangs up. The engine must finish (or fail) without crashing.
    static func sync(_ data: [UInt8]) {
        var frames: [[UInt8]] = []
        var index = 0
        while index < data.count {
            let length = Int(data[index])
            let end = min(data.count, index + 1 + length)
            frames.append(Array(data[(index + 1)..<end]))
            index = end
        }
        let sent = frames
        blocking {
            let fixture = Fixture.shared
            let store = MemoryLogStore()
            let engine = SyncEngine(store: store, identityDocument: fixture.serverDocument,
                                    policy: SyncPolicy(allowing: { _ in true }, interests: { [fixture.user] }), now: { 2 })
            let (ours, theirs) = MemoryChannel.pair()
            let session = Task { _ = try? await engine.run(over: ours) }
            let hello = SyncMessage.hello(.init(version: SyncMessage.protocolVersion, identity: fixture.identityDocument))
            try? await theirs.send(try CBOREncoder().encode(hello))
            for frame in sent { try? await theirs.send(frame) }
            await theirs.close()
            await session.value
        }
    }

    /// swift-mls parsing untrusted commits, Welcomes, application messages
    /// and KeyPackages. The first byte picks which.
    static func mls(_ data: [UInt8]) {
        guard let kind = data.first else { return }
        let payload = Array(data.dropFirst())
        let fixture = Fixture.shared.mls
        var group = fixture.member
        switch kind % 4 {
        case 0: _ = try? group.process(commit: payload)
        case 1: _ = try? CommunityGroup.join(welcome: payload, secrets: fixture.joiner)
        case 2: _ = try? group.decrypt(payload)
        default: _ = try? CommunityGroup.inspect(keyPackage: payload)
        }
    }
}

/// Runs async work to completion from a synchronous fuzz entry point.
func blocking(_ work: @escaping @Sendable () async -> Void) {
    let done = DispatchSemaphore(value: 0)
    Task {
        await work()
        done.signal()
    }
    done.wait()
}

struct NoTransport: DHTTransport {
    func send(_ request: DHTMessage, to contact: DHTContact) async throws -> DHTMessage { throw DHTError.unexpectedResponse }
}

/// Keys, documents and MLS state the targets reuse, made once.
final class Fixture: Sendable {
    static let shared = Fixture()

    let user: UserID
    let device: DeviceID
    let agreementKey: AgreementPublicKey
    let identityDocument: SignedObject
    let serverDocument: SignedObject
    let identity: VerifiedIdentity
    let logEntry: VerifiedLogEntry
    let envelope: Envelope
    let noiseMessage1: [UInt8]
    let texts: [String]
    let mls: MLSFixture
    private let deviceKeys: DeviceKeyPair

    struct MLSFixture: Sendable {
        var member: CommunityGroup
        var joiner: CommunityGroup.JoinSecrets
        var commit: [UInt8]
        var welcome: [UInt8]
        var application: [UInt8]
        var keyPackage: [UInt8]
    }

    private init() {
        do {
            let identityKeys = IdentityKeyPair()
            let device = DeviceKeyPair()
            let certificate = try DeviceCertificate.issue(for: device, by: identityKeys, capabilities: .author,
                                                          issuedMillis: 0, validForMillis: 1 << 50)
            identityDocument = try IdentityDocument(user: identityKeys.userID, version: 1, certificates: [certificate],
                                                    displayName: "Fuzz").signed(by: identityKeys)
            user = identityKeys.userID
            self.device = device.deviceID
            agreementKey = device.agreementPublicKey
            identity = try VerifiedIdentity(verifying: identityDocument, for: user)
            let post = Post(author: user, created: HLCTimestamp(millis: 1), body: RichText(plain: "hello"))
            let item = ContentItem(kind: .post, object: try SignedObject(encoding: post, label: .post, with: device))
            logEntry = try VerifiedLogEntry(signing: LogEntry(author: user, device: device.deviceID, sequence: 1, previous: nil,
                                                              created: HLCTimestamp(millis: 1), body: .publicContent(item)),
                                            with: device)
            envelope = try Envelope.seal(try CBOREncoder().encode(item), author: user,
                                         to: EnvelopeAudience(devices: [device.agreementPublicKey]))
            var initiator = NoiseHandshake(role: .initiator, device: device)
            noiseMessage1 = try initiator.writeMessage()

            let serverKeys = IdentityKeyPair(), serverDevice = DeviceKeyPair()
            let serverCertificate = try DeviceCertificate.issue(for: serverDevice, by: serverKeys, capabilities: .author,
                                                                issuedMillis: 0, validForMillis: 1 << 50)
            serverDocument = try IdentityDocument(user: serverKeys.userID, version: 1, certificates: [serverCertificate],
                                                  displayName: "Server").signed(by: serverKeys)

            var sequencer = try CommunityGroup.create(identity: Array("owner".utf8), groupID: Array("fuzz".utf8))
            let memberSecrets = try CommunityGroup.makeKeyPackage(identity: Array("member".utf8))
            let joiner = try CommunityGroup.makeKeyPackage(identity: Array("joiner".utf8))
            let added = try sequencer.add(keyPackages: [memberSecrets.keyPackage])
            let member = try CommunityGroup.join(welcome: added.welcome!, secrets: memberSecrets)
            let next = try sequencer.add(keyPackages: [joiner.keyPackage])
            mls = MLSFixture(member: member, joiner: joiner, commit: next.message, welcome: next.welcome!,
                             application: try sequencer.encrypt(Array("hi".utf8)), keyPackage: joiner.keyPackage)
            texts = ["circles-invite:aaaa", "circles-community:aaaa", "circles-pod:aaaa", "127.0.0.1:7466#aaaa",
                     try DHTNodeText.text(for: DHTContact(key: device.agreementPublicKey, host: "192.0.2.1", port: 7)), user.description]
            deviceKeys = device
        } catch {
            fatalError("fuzz fixture: \(error)")
        }
    }

    func openEnvelope(_ envelope: Envelope) throws -> [UInt8] {
        try envelope.open(keyring: AudienceKeyring(), device: deviceKeys)
    }
}
