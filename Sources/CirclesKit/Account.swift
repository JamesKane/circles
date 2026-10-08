public import Foundation
public import CirclesCore
public import CirclesCrypto
public import CirclesSync
public import CirclesNet
public import CirclesStorage
public import CirclesDHT

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
    /// Our node in the DHT (docs/DESIGN.md §7.2).
    public nonisolated let dht: DHTNode

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
        let reference = WeakAccount()
        dht = DHTNode(key: device.agreementPublicKey, listenPort: nil,
                      transport: NoiseDHTTransport { await reference.account?.makeHandshake(role: .initiator) },
                      now: { wallClockMillis() })
        self.identity = identity
        self.device = device
        reference.account = self
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
        return try saveContact(Contact(user: verified.user, name: name ?? invite.name))
    }

    /// Adds or replaces a contact.
    func saveContact(_ contact: Contact) throws -> Contact {
        try reload()
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

    /// Appends to this device's log for `author`: ourselves, or a community
    /// this device sequences (docs/DESIGN.md §8.3).
    func appendToLog(_ body: LogBody, as author: UserID? = nil, created: HLCTimestamp? = nil, blobs: [ContentID]? = nil) async throws {
        let author = author ?? user
        let created = try created ?? tick()
        let head = try await store.head(author: author, device: deviceID)
        let entry = LogEntry(author: author, device: deviceID, sequence: (head?.sequence ?? 0) + 1,
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
        let communitiesURL = files.communities
        let currentContacts: @Sendable () -> [UserID] = {
            ((try? Files.loadStatic([Contact].self, from: contactsURL)) ?? []).map(\.user)
        }
        // Communities we belong to (or asked to join) are synced like contacts:
        // we talk to their serving devices and want their logs.
        let currentCommunities: @Sendable () -> [UserID] = {
            ((try? Files.loadStatic([CommunityState].self, from: communitiesURL)) ?? [])
                .filter { $0.role == .member || $0.role == .pending }.map(\.community)
        }
        // Communities we sequence: our pods keep their logs and members'
        // submissions, so with our own devices we exchange those too.
        let ownedLogs: @Sendable () -> [UserID] = {
            ((try? Files.loadStatic([CommunityState].self, from: communitiesURL)) ?? [])
                .filter { $0.role == .owner }.flatMap { [$0.community] + $0.roster }
        }
        return SyncEngine(
            store: store,
            identityDocument: identityDocument,
            policy: SyncPolicy(
                isAllowed: { peer in
                    peer.user == me || currentContacts().contains(peer.user) || currentCommunities().contains(peer.user)
                },
                interests: { currentContacts() + currentCommunities() + ownedLogs() + [me] },
                outgoingControl: { peer in
                    if currentCommunities().contains(peer.user) {
                        return (try? await self.joinRequest(for: peer.user)).map { [$0] } ?? []
                    }
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
    private func signedPodConfig() async throws -> SignedObject {
        try reload()
        let config = PodConfig(owner: user, version: wallClockMillis(), contacts: contacts.map(\.user),
                               communities: try await podCommunities(), push: pushTargets())
        return try SignedObject(encoding: config, label: .podConfig, with: device)
    }

    // MARK: Endpoints

    public var endpoints: Endpoints {
        (try? VerifiedIdentity(verifying: identityDocument, for: user).endpoints) ?? Endpoints()
    }

    /// Publishes a new version of our identity document after `change`.
    func republish(_ change: (inout IdentityDocument) throws -> Void) async throws {
        var document = try VerifiedIdentity(verifying: identityDocument, for: user).document
        try change(&document)
        document.version += 1
        if document.endpoints?.isEmpty == true { document.endpoints = nil }
        let signed = try document.signed(by: identity)
        let verified = try VerifiedIdentity(verifying: signed, for: user)
        identityDocument = signed
        try files.save(Profile(displayName: displayName, identityDocument: signed), to: files.profile)
        try await store.saveIdentityDocument(signed, verified: verified)
        try await refreshCommunityEndpoints()
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
    /// `target` names the identity to reach on that device, e.g. a community
    /// its owner serves.
    public func sync(host: String, port: Int, target: UserID? = nil) async throws -> SyncReport {
        let engine = syncEngine()
        let report = try await withNoiseConnection(host: host, port: port, handshake: makeHandshake(role: .initiator)) { session in
            try await engine.run(over: session, target: target)
        }
        try await absorbKeyGrants()
        return report
    }

    /// Connects to `target` through a relay and syncs once.
    public func sync(via relay: RelayEndpoint, to target: AgreementPublicKey, identity: UserID? = nil) async throws -> SyncReport {
        let engine = syncEngine()
        let report = try await withRelayedConnection(
            via: RelayAddress(host: relay.host, port: Int(relay.port), key: relay.key), to: target,
            outer: makeHandshake(role: .initiator), inner: makeHandshake(role: .initiator)
        ) { session in
            try await engine.run(over: session, target: identity)
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
        try await CirclesNet.serveViaRelay(
            RelayAddress(host: relay.host, port: Int(relay.port), key: relay.key),
            outer: makeHandshake(role: .initiator), inner: makeHandshake(role: .responder),
            onReserved: onReserved
        ) { session in
            if let report = try await self.respond(over: session) { await onSync(report) }
        }
    }

    /// One sync attempt, for reporting.
    public struct SyncAttempt: Sendable {
        public var succeeded: Bool { if case .success = result { true } else { false } }
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

        let joined = ((try? loadCommunities()) ?? []).filter { $0.role == .member || $0.role == .pending }
        // A community's owner, seen on the local network, serves it.
        for peer in peers where peer.device != deviceID {
            for state in joined where state.decodedProfile?.owner == peer.user {
                let route = "\(state.decodedProfile?.name ?? "community") on the local network (\(peer.host):\(peer.port))"
                _ = record(await tryRoute(route) { try await self.sync(host: peer.host, port: peer.port, target: state.community) })
            }
        }

        for pod in endpoints.pods {
            let route = "my pod at \(pod.host):\(pod.port)"
            _ = record(await tryRoute(route) { try await self.sync(host: pod.host, port: Int(pod.port)) })
        }

        let useDHT = (try? preferences().useDHT) ?? true
        for contact in contacts where !reached.contains(contact.user) {
            for attempt in await reach(contact.name, contact.user, target: nil, usePods: true, useDHT: useDHT) { _ = record(attempt) }
        }
        for state in joined where !reached.contains(state.community) {
            // Pending members must reach the owner: pods don't take join requests.
            for attempt in await reach(state.decodedProfile?.name ?? "community", state.community, target: state.community,
                                       usePods: state.role == .member, useDHT: useDHT) {
                _ = record(attempt)
            }
        }
        try? await processCommunities()
        return attempts
    }

    /// Tries a user's (or community's) routes until one works: pods, direct
    /// addresses, then each author device through each relay. When all fail,
    /// the DHT may hold a newer identity document with new addresses, which
    /// are tried once.
    private func reach(_ name: String, _ user: UserID, target: UserID?, usePods: Bool, useDHT: Bool) async -> [SyncAttempt] {
        var attempts: [SyncAttempt] = []
        let known = try? await store.verifiedIdentity(for: user)
        if let known {
            attempts += await routes(name, known, target: target, usePods: usePods)
            if attempts.last?.succeeded == true { return attempts }
        }
        guard useDHT, let fresher = try? await lookUp(user), fresher.version > known?.version ?? 0 else { return attempts }
        return attempts + (await routes(name + " (addresses from the DHT)", fresher, target: target, usePods: usePods))
    }

    private func routes(_ name: String, _ identity: VerifiedIdentity, target: UserID?, usePods: Bool) async -> [SyncAttempt] {
        var attempts: [SyncAttempt] = []
        if usePods {
            for pod in identity.endpoints.pods {
                let route = target == nil ? "\(name)'s pod at \(pod.host):\(pod.port)" : "\(name) on its pod at \(pod.host):\(pod.port)"
                attempts.append(await tryRoute(route) { try await self.sync(host: pod.host, port: Int(pod.port), target: target) })
                if attempts.last!.succeeded { return attempts }
            }
        }
        for direct in identity.endpoints.direct {
            attempts.append(await tryRoute("\(name) at \(direct.host):\(direct.port)") {
                try await self.sync(host: direct.host, port: Int(direct.port), target: target)
            })
            if attempts.last!.succeeded { return attempts }
        }
        let devices = identity.certificates.values.filter { $0.capabilities.contains(.author) }
        for relay in identity.endpoints.relays {
            for device in devices {
                attempts.append(await tryRoute("\(name) via relay \(relay.host):\(relay.port)") {
                    try await self.sync(via: relay, to: device.agreementKey, identity: target)
                })
                if attempts.last!.succeeded { return attempts }
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
    /// This device's push relay registrations (docs/DESIGN.md §7.6).
    var push: URL { account.appendingPathComponent("push.cbor") }
    /// DHT nodes known at the last refresh, to rejoin through.
    var dhtContacts: URL { account.appendingPathComponent("dht-nodes.cbor") }
    /// Communities we own or belong to (0600: holds community keys and MLS
    /// join secrets).
    var communities: URL { account.appendingPathComponent("communities.cbor") }
    /// A random key that seals local secret state such as MLS groups (0600).
    var storageKey: URL { account.appendingPathComponent("storage.key") }
    func mlsState(_ community: UserID) -> URL {
        account.appendingPathComponent("mls").appendingPathComponent(Base32.encode(community.multicodecBytes) + ".sealed")
    }
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
