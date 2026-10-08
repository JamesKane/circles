public import Foundation
public import CirclesCore
public import CirclesCrypto
public import CirclesSync
public import CirclesNet
public import CirclesStorage

/// One user's node on one device: keys, contacts, circles, keyring and logs,
/// stored under a home directory:
///
///     <home>/account/keys.cbor       private keys (0600)
///     <home>/account/profile.cbor    display name, signed identity document
///     <home>/account/contacts.cbor
///     <home>/account/circles.cbor    circles with current keys (0600)
///     <home>/account/keyring.cbor    all audience keys held (0600)
///     <home>/account/clock.cbor      hybrid logical clock
///     <home>/circles.sqlite          logs, identity documents, media chunks
///
/// Private keys never leave the actor. Everything that needs one runs
/// synchronously inside it.
public actor Account {
    public nonisolated let home: URL
    public nonisolated let store: SQLiteLogStore
    public nonisolated let user: UserID
    public nonisolated let deviceID: DeviceID
    public private(set) var displayName: String
    public private(set) var identityDocument: SignedObject
    public private(set) var contacts: [Contact] = []
    public private(set) var circles: [CircleRecord] = []

    let identity: IdentityKeyPair
    let device: DeviceKeyPair
    var keyring = AudienceKeyring()
    private var clock = HybridLogicalClock()

    public static let certificateLifetime: UInt64 = 365 * 24 * 3600 * 1000

    // MARK: Lifecycle

    /// Creates a new identity and device in `home`.
    public static func create(home: URL, displayName: String) async throws -> Account {
        let files = Files(home: home)
        guard !FileManager.default.fileExists(atPath: files.keys.path) else { throw AccountError.alreadyExists }
        let identity = IdentityKeyPair()
        let device = DeviceKeyPair()
        let certificate = try DeviceCertificate.issue(
            for: device, by: identity, capabilities: .author,
            issuedMillis: wallClockMillis(), validForMillis: certificateLifetime
        )
        let document = try IdentityDocument(user: identity.userID, version: 1, certificates: [certificate],
                                            displayName: displayName).signed(by: identity)
        let deviceRaw = device.exportRawRepresentation()
        try files.save(StoredKeys(identity: identity.exportRawRepresentation(),
                                  deviceSigning: deviceRaw.signingKey, deviceAgreement: deviceRaw.agreementKey),
                       to: files.keys, private: true)
        try files.save(Profile(displayName: displayName, identityDocument: document), to: files.profile)
        return try await open(home: home)
    }

    /// Whether `home` holds an account.
    public static func exists(home: URL) -> Bool {
        FileManager.default.fileExists(atPath: Files(home: home).keys.path)
    }

    public static func open(home: URL) async throws -> Account {
        let files = Files(home: home)
        guard let keys = try files.load(StoredKeys.self, from: files.keys),
              let profile = try files.load(Profile.self, from: files.profile)
        else { throw AccountError.notFound }
        let store = try await openStore(home: home)
        return try Account(
            home: home,
            store: store,
            identity: IdentityKeyPair(rawRepresentation: keys.identity),
            device: DeviceKeyPair(signingKey: keys.deviceSigning, agreementKey: keys.deviceAgreement),
            profile: profile
        )
    }

    private init(home: URL, store: SQLiteLogStore, identity: consuming IdentityKeyPair, device: consuming DeviceKeyPair, profile: Profile) throws {
        self.home = home
        self.store = store
        user = identity.userID
        deviceID = device.deviceID
        displayName = profile.displayName
        identityDocument = profile.identityDocument
        let state = try Self.loadState(Files(home: home), user: user)
        (contacts, circles, keyring, clock) = (state.contacts, state.circles, state.keyring, state.clock)
        self.identity = identity
        self.device = device
    }

    var files: Files { Files(home: home) }

    /// Re-reads contacts, circles, keyring and clock, which another process
    /// sharing this home may have changed.
    public func reload() throws {
        let state = try Self.loadState(files, user: user)
        (contacts, circles, keyring) = (state.contacts, state.circles, state.keyring)
        // Never move the clock backwards.
        if state.clock.last > clock.last { clock = state.clock }
    }

    private static func loadState(_ files: Files, user: UserID) throws
        -> (contacts: [Contact], circles: [CircleRecord], keyring: AudienceKeyring, clock: HybridLogicalClock)
    {
        var keyring = AudienceKeyring()
        for stored in try files.load([StoredKey].self, from: files.keyring) ?? [] {
            keyring.insert(try stored.audienceKey, owner: stored.owner ?? user)
        }
        return (
            try files.load([Contact].self, from: files.contacts) ?? [],
            try files.load([CircleRecord].self, from: files.circles) ?? [],
            keyring,
            HybridLogicalClock(last: try files.load(HLCTimestamp.self, from: files.clock) ?? HLCTimestamp(millis: 0))
        )
    }

    func saveKeyring() throws {
        let stored = keyring.allKeys.map { StoredKey(owner: $0.owner, key: $0.key) }
        try files.save(stored, to: files.keyring, private: true)
    }

    func tick() throws -> HLCTimestamp {
        let timestamp = clock.now(physicalMillis: wallClockMillis())
        try files.save(timestamp, to: files.clock)
        return timestamp
    }

    // MARK: Contacts

    public func invite() throws -> String {
        try Invite(name: displayName, identityDocument: identityDocument).text
    }

    @discardableResult
    public func addContact(invite text: String, name: String? = nil) async throws -> Contact {
        let invite = try Invite(text: text)
        let claimed = try CBORDecoder().decode(IdentityDocument.self, from: invite.identityDocument.payload)
        let verified = try VerifiedIdentity(verifying: invite.identityDocument, for: claimed.user)
        try await store.saveIdentityDocument(invite.identityDocument, verified: verified)
        try reload()
        let contact = Contact(user: verified.user, name: name ?? invite.name)
        contacts.removeAll { $0.user == contact.user }
        contacts.append(contact)
        try files.save(contacts, to: files.contacts)
        return contact
    }

    /// Changes the local name for a contact. Names are petnames: they never
    /// leave this device.
    public func renameContact(_ user: UserID, to name: String) throws {
        try reload()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = contacts.firstIndex(where: { $0.user == user }) else {
            throw AccountError.unknownContact(name)
        }
        contacts[index].name = trimmed
        try files.save(contacts, to: files.contacts)
    }

    /// Removes a contact. They're taken out of every circle first, which
    /// rotates those circles' keys, so they can't read anything posted from
    /// now on. They keep what they already received (docs/DESIGN.md §8.2).
    public func removeContact(_ user: UserID) async throws {
        try reload()
        guard contacts.contains(where: { $0.user == user }) else { throw AccountError.unknownContact("\(user)") }
        for circle in circles where circle.members.contains(user) {
            try await removeFromCircle(circle.name, members: [user])
        }
        try reload()
        contacts.removeAll { $0.user == user }
        try files.save(contacts, to: files.contacts)
    }

    public func contact(named name: String) throws -> Contact {
        guard let contact = contacts.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw AccountError.unknownContact(name)
        }
        return contact
    }

    public func name(of user: UserID) -> String {
        user == self.user ? displayName : contacts.first { $0.user == user }?.name ?? String(user.description.prefix(20)) + "…"
    }

    // MARK: Circles

    public func createCircle(_ name: String) throws {
        try reload()
        guard !circles.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw AccountError.circleExists(name)
        }
        let schedule = CircleKeySchedule()
        keyring.insert(schedule.current, owner: user)
        circles.append(CircleRecord(name: name, schedule: schedule))
        try saveKeyring()
        try files.save(circles, to: files.circles, private: true)
    }

    /// Adds contacts to a circle and publishes key grants to them.
    public func addToCircle(_ circleName: String, members: [UserID]) async throws {
        try await changeCircle(circleName) { schedule in schedule.add(Set(members)) }
    }

    /// Removes members; the circle's key rotates so they can't read new posts.
    public func removeFromCircle(_ circleName: String, members: [UserID]) async throws {
        try await changeCircle(circleName) { schedule in schedule.remove(Set(members)) }
    }

    private func changeCircle(
        _ circleName: String,
        _ change: (inout CircleKeySchedule) -> CircleKeySchedule.Distribution?
    ) async throws {
        try reload()
        guard let index = circles.firstIndex(where: { $0.name.caseInsensitiveCompare(circleName) == .orderedSame }) else {
            throw AccountError.unknownCircle(circleName)
        }
        var schedule = try circles[index].schedule
        guard let distribution = change(&schedule) else { return }
        keyring.insert(distribution.key, owner: user)
        try saveKeyring()

        // One grant per author device of each recipient, published in our log.
        for recipient in distribution.recipients {
            guard let identity = try await store.verifiedIdentity(for: recipient) else { continue }
            for certificate in identity.certificates.values where certificate.capabilities.contains(.author) {
                let grant = try SealedKeyGrant.seal(distribution.key, owner: user, recipient: recipient,
                                                    to: certificate.agreementKey, signedBy: device)
                try await appendToLog(.keyGrant(grant))
            }
        }
        circles[index] = CircleRecord(name: circles[index].name, schedule: schedule)
        try files.save(circles, to: files.circles, private: true)
    }

    // MARK: Logging

    func appendToLog(_ body: LogBody, created: HLCTimestamp? = nil, blobs: [ContentID]? = nil) async throws {
        let created = try created ?? tick()
        let head = try await store.head(author: user, device: deviceID)
        let entry = LogEntry(author: user, device: deviceID, sequence: (head?.sequence ?? 0) + 1,
                             previous: head?.id, created: created, body: body, blobs: blobs)
        try await store.append(try VerifiedLogEntry(signing: entry, with: device))
    }

    // MARK: Reading

    /// Opens key grants addressed to this user and adds them to the keyring.
    /// Returns how many new keys were learned.
    @discardableResult
    public func absorbKeyGrants() async throws -> Int {
        try reload()
        var learned = 0
        for contact in contacts {
            guard let owner = try await store.verifiedIdentity(for: contact.user) else { continue }
            for signed in try await store.allEntries(author: contact.user) {
                guard let entry = try? CBORDecoder().decode(LogEntry.self, from: signed.payload),
                      case .keyGrant(let grant) = entry.body,
                      let key = try? grant.open(with: device, recipient: user, owner: owner,
                                                receivedAtMillis: entry.created.millis),
                      keyring.key(owner: contact.user, id: key.id) == nil
                else { continue }
                keyring.insert(key, owner: contact.user)
                learned += 1
            }
        }
        if learned > 0 { try saveKeyring() }
        return learned
    }

    /// Our own identity comes from the profile; others' from the store.
    func verifiedIdentity(for author: UserID) async throws -> VerifiedIdentity? {
        author == user
            ? try VerifiedIdentity(verifying: identityDocument, for: user)
            : try await store.verifiedIdentity(for: author)
    }

    // MARK: Networking

    public func makeHandshake(role: NoiseHandshake.Role) -> NoiseHandshake {
        NoiseHandshake(role: role, device: device)
    }

    public func advertisement(port: Int) -> ServiceAdvertisement {
        ServiceAdvertisement(instanceName: ServiceAdvertisement.instanceName(for: deviceID), port: port,
                             user: user, device: deviceID)
    }

    /// A sync engine that syncs with contacts and with this user's own other
    /// devices and pods, and wants their logs. Contacts are re-read from disk
    /// on each session. Our own pods are sent their configuration.
    public func syncEngine() -> SyncEngine {
        let me = user
        let contactsURL = files.contacts
        let currentContacts: @Sendable () -> [UserID] = {
            ((try? Files.loadStatic([Contact].self, from: contactsURL)) ?? []).map(\.user)
        }
        return SyncEngine(
            store: store,
            identityDocument: identityDocument,
            policy: SyncPolicy(
                isAllowed: { peer in peer.user == me || currentContacts().contains(peer.user) },
                interests: { currentContacts() + [me] },
                outgoingControl: { peer in
                    guard peer.user == me, peer.device?.capabilities.contains(.storeAndForward) == true,
                          let config = try? await self.signedPodConfig()
                    else { return [] }
                    return [config]
                }
            ),
            now: { wallClockMillis() }
        )
    }

    /// Signs an arbitrary value with this device, for tests only.
    func signForTesting(_ value: some Encodable, label: SignatureLabel) throws -> SignedObject {
        try SignedObject(encoding: value, label: label, with: device)
    }

    /// The current contact list for our pods, signed by this device.
    private func signedPodConfig() throws -> SignedObject {
        try reload()
        let config = PodConfig(owner: user, version: wallClockMillis(), contacts: contacts.map(\.user))
        return try SignedObject(encoding: config, label: .podConfig, with: device)
    }

    // MARK: Endpoints

    public var endpoints: Endpoints {
        (try? VerifiedIdentity(verifying: identityDocument, for: user).endpoints) ?? Endpoints()
    }

    /// Publishes a new version of our identity document after `change`.
    private func republish(_ change: (inout IdentityDocument) throws -> Void) async throws {
        var document = try VerifiedIdentity(verifying: identityDocument, for: user).document
        try change(&document)
        document.version += 1
        if document.endpoints?.isEmpty == true { document.endpoints = nil }
        let signed = try document.signed(by: identity)
        let verified = try VerifiedIdentity(verifying: signed, for: user)
        identityDocument = signed
        try files.save(Profile(displayName: displayName, identityDocument: signed), to: files.profile)
        try await store.saveIdentityDocument(signed, verified: verified)
    }

    /// Certifies a pod from its pairing code and lists it in our identity
    /// document. Returns the bundle to give the pod.
    public func addPod(_ code: PodPairingCode) async throws -> PodBundle {
        let certificate = try DeviceCertificate.issue(
            device: code.device, agreementKey: code.agreementKey, by: identity,
            capabilities: .storeAndForward, issuedMillis: wallClockMillis(), validForMillis: Self.certificateLifetime
        )
        try await republish { document in
            document.certificates.append(certificate)
            var endpoints = document.endpoints ?? Endpoints()
            endpoints.pods.removeAll { $0.device == code.device }
            endpoints.pods.append(PodEndpoint(device: code.device, host: code.host, port: code.port))
            document.endpoints = endpoints
        }
        return PodBundle(identityDocument: identityDocument)
    }

    /// Lists a relay our devices keep reservations on, so contacts can reach
    /// us through it.
    public func addRelay(_ relay: RelayEndpoint) async throws {
        try await republish { document in
            var endpoints = document.endpoints ?? Endpoints()
            endpoints.relays.removeAll { $0.host == relay.host && $0.port == relay.port }
            endpoints.relays.append(relay)
            document.endpoints = endpoints
        }
    }

    /// Publishes (or with nil, withdraws) this device's public address, e.g.
    /// from router port mapping. Opt-in: everyone who receives our identity
    /// document learns it.
    public func setDirectEndpoint(host: String?, port: Int) async throws {
        let me = deviceID
        try await republish { document in
            var endpoints = document.endpoints ?? Endpoints()
            endpoints.direct.removeAll { $0.device == me }
            if let host { endpoints.direct.append(DirectEndpoint(device: me, host: host, port: UInt16(port))) }
            document.endpoints = endpoints
        }
    }

    // MARK: Syncing

    /// Connects to a peer and syncs once.
    public func sync(host: String, port: Int) async throws -> SyncReport {
        let engine = syncEngine()
        let report = try await withNoiseConnection(host: host, port: port, handshake: makeHandshake(role: .initiator)) { session in
            try await engine.run(over: session)
        }
        try await absorbKeyGrants()
        return report
    }

    /// Connects to `target` through a relay and syncs once.
    public func sync(via relay: RelayEndpoint, to target: AgreementPublicKey) async throws -> SyncReport {
        let engine = syncEngine()
        let report = try await withRelayedConnection(
            via: RelayAddress(host: relay.host, port: Int(relay.port), key: relay.key), to: target,
            outer: makeHandshake(role: .initiator), inner: makeHandshake(role: .initiator)
        ) { session in
            try await engine.run(over: session)
        }
        try await absorbKeyGrants()
        return report
    }

    /// Keeps a reservation on `relay` and syncs with every peer that connects
    /// through it, until cancelled or the relay drops us.
    public func serveViaRelay(
        _ relay: RelayEndpoint,
        onReserved: @escaping @Sendable () -> Void = {},
        onSync: @escaping @Sendable (SyncReport) async -> Void = { _ in }
    ) async throws {
        let engine = syncEngine()
        try await CirclesNet.serveViaRelay(
            RelayAddress(host: relay.host, port: Int(relay.port), key: relay.key),
            outer: makeHandshake(role: .initiator), inner: makeHandshake(role: .responder),
            onReserved: onReserved
        ) { session in
            let report = try await engine.run(over: session)
            try await self.absorbKeyGrants()
            await onSync(report)
        }
    }

    /// One sync attempt, for reporting.
    public struct SyncAttempt: Sendable {
        public var route: String
        public var result: Result<SyncReport, any Error>
    }

    /// Syncs with everyone reachable, trying routes in order of preference:
    /// 1. peers found on the local network (mDNS);
    /// 2. our own pods, always;
    /// 3. for each contact not yet reached: their pods, then their published
    ///    direct addresses, then their devices through their relays.
    public func syncAll(discoveryTimeout: Duration = .seconds(2)) async -> [SyncAttempt] {
        try? reload()
        var attempts: [SyncAttempt] = []
        var reached: Set<UserID> = []
        let contactUsers = Set(contacts.map(\.user))

        func record(_ attempt: SyncAttempt) -> Bool {
            attempts.append(attempt)
            guard case .success(let report) = attempt.result else { return false }
            if let peer = report.peer { reached.insert(peer) }
            return true
        }

        let peers = (try? await MulticastDNS.browse(timeout: discoveryTimeout)) ?? []
        for peer in peers where peer.device != deviceID {
            guard let peerUser = peer.user, peerUser == user || contactUsers.contains(peerUser) else { continue }
            let route = "\(name(of: peerUser)) on the local network (\(peer.host):\(peer.port))"
            _ = record(await tryRoute(route) { try await self.sync(host: peer.host, port: peer.port) })
        }

        for pod in endpoints.pods {
            let route = "my pod at \(pod.host):\(pod.port)"
            _ = record(await tryRoute(route) { try await self.sync(host: pod.host, port: Int(pod.port)) })
        }

        for contact in contacts where !reached.contains(contact.user) {
            guard let identity = try? await store.verifiedIdentity(for: contact.user) else { continue }
            var done = false
            for pod in identity.endpoints.pods where !done {
                let route = "\(contact.name)'s pod at \(pod.host):\(pod.port)"
                done = record(await tryRoute(route) { try await self.sync(host: pod.host, port: Int(pod.port)) })
            }
            for direct in identity.endpoints.direct where !done {
                let route = "\(contact.name) at \(direct.host):\(direct.port)"
                done = record(await tryRoute(route) { try await self.sync(host: direct.host, port: Int(direct.port)) })
            }
            let devices = identity.certificates.values.filter { $0.capabilities.contains(.author) }
            for relay in identity.endpoints.relays where !done {
                for device in devices where !done {
                    let route = "\(contact.name) via relay \(relay.host):\(relay.port)"
                    done = record(await tryRoute(route) { try await self.sync(via: relay, to: device.agreementKey) })
                }
            }
        }
        return attempts
    }

    private func tryRoute(_ route: String, _ operation: @Sendable () async throws -> SyncReport) async -> SyncAttempt {
        do {
            return SyncAttempt(route: route, result: .success(try await operation()))
        } catch {
            return SyncAttempt(route: route, result: .failure(error))
        }
    }
}

// MARK: - Files

/// Opens `<home>/circles.sqlite`, first importing an M2/M3 file-based store
/// if one is present. The old directories are renamed, not deleted.
func openStore(home: URL) async throws -> SQLiteLogStore {
    let store = try SQLiteLogStore(path: home.appendingPathComponent("circles.sqlite"))
    let logs = home.appendingPathComponent("logs"), identities = home.appendingPathComponent("identities")
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: logs.path) || fileManager.fileExists(atPath: identities.path) {
        _ = try await store.importLegacyFiles(from: home)
        for directory in [logs, identities] where fileManager.fileExists(atPath: directory.path) {
            try fileManager.moveItem(at: directory, to: directory.appendingPathExtension("pre-m4"))
        }
    }
    return store
}

struct Files {
    let home: URL

    var account: URL { home.appendingPathComponent("account") }
    var keys: URL { account.appendingPathComponent("keys.cbor") }
    var profile: URL { account.appendingPathComponent("profile.cbor") }
    var contacts: URL { account.appendingPathComponent("contacts.cbor") }
    var circles: URL { account.appendingPathComponent("circles.cbor") }
    var keyring: URL { account.appendingPathComponent("keyring.cbor") }
    var clock: URL { account.appendingPathComponent("clock.cbor") }
    var preferences: URL { account.appendingPathComponent("preferences.cbor") }
    /// IDs of contributions already republished into our threads.
    var threads: URL { account.appendingPathComponent("threads.cbor") }

    func save(_ value: some Encodable, to url: URL, private isPrivate: Bool = false) throws {
        try FileIO.write(try CBOREncoder().encode(value), to: url, private: isPrivate)
    }

    func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        try Self.loadStatic(type, from: url)
    }

    static func loadStatic<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        try FileIO.read(url).map { try CBORDecoder().decode(type, from: $0) }
    }
}

func wallClockMillis() -> UInt64 {
    UInt64(Date().timeIntervalSince1970 * 1000)
}
