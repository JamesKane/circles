import CirclesCore
import CirclesCrypto
import CirclesSync

let issued: UInt64 = 1_000_000
let now: UInt64 = issued + 60_000

/// A user with one device, a published identity document, a store and a
/// set of contacts. A class so it can hold non-copyable keys.
final class Node: @unchecked Sendable {
    let identity: IdentityKeyPair
    let device: DeviceKeyPair
    let document: SignedObject
    let store = MemoryLogStore()
    var contacts: Set<UserID> = []
    var clock = HybridLogicalClock()

    init() throws {
        let identity = IdentityKeyPair()
        let device = DeviceKeyPair()
        let certificate = try DeviceCertificate.issue(
            for: device, by: identity, capabilities: .author, issuedMillis: issued, validForMillis: 1 << 40
        )
        document = try IdentityDocument(user: identity.userID, version: 1, certificates: [certificate]).signed(by: identity)
        self.identity = identity
        self.device = device
    }

    var user: UserID { identity.userID }

    /// Stores our own identity document, as a node does at setup.
    func bootstrap() async throws {
        try await store.saveIdentityDocument(document, verified: VerifiedIdentity(verifying: document, for: user))
    }

    /// Learns a contact the way an invite would: user ID plus identity document.
    func meet(_ other: Node) async throws {
        contacts.insert(other.user)
        try await store.saveIdentityDocument(other.document, verified: VerifiedIdentity(verifying: other.document, for: other.user))
    }

    func follow(_ user: UserID) {
        contacts.insert(user)
    }

    @discardableResult
    func post(_ text: String) async throws -> VerifiedLogEntry {
        let created = clock.now(physicalMillis: now)
        let post = Post(author: user, created: created, body: RichText(plain: text))
        let item = ContentItem(kind: .post, object: try SignedObject(encoding: post, label: .post, with: device))
        return try await store.appendLocal(.publicContent(item), author: user, device: device, created: created)
    }

    func engine(allowing allowed: (@Sendable (UserID) -> Bool)? = nil) -> SyncEngine {
        let contacts = self.contacts, me = user
        return SyncEngine(
            store: store,
            identityDocument: document,
            policy: SyncPolicy(
                allowing: { allowed?($0) ?? contacts.contains($0) },
                interests: { Array(contacts) + [me] }
            ),
            now: { now }
        )
    }

    func postTexts(by author: UserID) async throws -> [String] {
        try await store.allEntries(author: author).map { signed in
            let entry = try CBORDecoder().decode(LogEntry.self, from: signed.payload)
            guard case .publicContent(let item) = entry.body else { return "?" }
            return try CBORDecoder().decode(Post.self, from: item.object.payload).body.plainText
        }
    }
}

/// Runs both sides of a sync session over an in-memory channel.
func sync(
    _ a: Node, _ b: Node,
    engines: (SyncEngine, SyncEngine)? = nil,
    staticKeys: (AgreementPublicKey?, AgreementPublicKey?)? = nil
) async throws -> (SyncReport, SyncReport) {
    let (ea, eb) = engines ?? (a.engine(), b.engine())
    let (ca, cb) = MemoryChannel.pair(staticKeys: staticKeys ?? (a.device.agreementPublicKey, b.device.agreementPublicKey))
    async let ra = runAndClose(ea, ca)
    async let rb = runAndClose(eb, cb)
    return try await (ra, rb)
}

/// Closes the channel when the engine finishes or fails, as a real
/// transport does, so the other side never waits forever.
private func runAndClose(_ engine: SyncEngine, _ channel: MemoryChannel) async throws -> SyncReport {
    do {
        let report = try await engine.run(over: channel)
        await channel.close()
        return report
    } catch {
        await channel.close()
        throw error
    }
}
