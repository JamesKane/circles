import Testing
import Foundation
import CirclesCore
import CirclesCrypto
import CirclesSync
@testable import CirclesStorage

func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("circles-storage-\(UUID().uuidString)")
}

extension SealedKeyGrant {
    static var stub: SealedKeyGrant {
        struct Stub: Codable { var encapsulatedKey: [UInt8] = [1]; var ciphertext: [UInt8] = [2] }
        return try! CBORDecoder().decode(SealedKeyGrant.self, from: CBOREncoder().encode(Stub()))
    }
}

@Suite("SQLite log store")
struct SQLiteLogStoreTests {
    @Test("learning of a revocation drops entries past the revoked device's last standing one")
    func revocationPrunes() async throws {
        let identity = IdentityKeyPair(), laptop = DeviceKeyPair(), phone = DeviceKeyPair()
        let certificates = [
            try DeviceCertificate.issue(for: laptop, by: identity, capabilities: .author, issuedMillis: 1, validForMillis: 1 << 50),
            try DeviceCertificate.issue(for: phone, by: identity, capabilities: .author, issuedMillis: 1, validForMillis: 1 << 50),
        ]
        let store = try SQLiteLogStore(path: temporaryDirectory().appendingPathComponent("db.sqlite"))
        let user = identity.userID
        let initial = try IdentityDocument(user: user, version: 1, certificates: certificates).signed(by: identity)
        try await store.saveIdentityDocument(initial, verified: try VerifiedIdentity(verifying: initial, for: user))
        for millis: UInt64 in [1, 2, 3] {
            try await store.appendLocal(.keyGrant(.stub), author: user, device: phone, created: HLCTimestamp(millis: millis))
        }
        try await store.appendLocal(.keyGrant(.stub), author: user, device: laptop, created: HLCTimestamp(millis: 4))
        let revoked = try IdentityDocument(user: user, version: 2, certificates: certificates,
                                           revocations: [DeviceRevocation(device: phone.deviceID, revokedAtMillis: 10, lastSequence: 1)]).signed(by: identity)
        try await store.saveIdentityDocument(revoked, verified: try VerifiedIdentity(verifying: revoked, for: user))
        #expect(try await store.head(author: user, device: phone.deviceID)?.sequence == 1)
        #expect(try await store.head(author: user, device: laptop.deviceID)?.sequence == 1)
    }

    let author = try! UserID(ed25519PublicKey: [UInt8](repeating: 1, count: 32))

    @Test("appends must follow the head, and persist across store instances")
    func appendAndReopen() async throws {
        let path = temporaryDirectory().appendingPathComponent("db.sqlite")
        let device = DeviceKeyPair()
        let store = try SQLiteLogStore(path: path)
        let first = try await store.appendLocal(.keyGrant(.stub), author: author, device: device, created: HLCTimestamp(millis: 1))
        try await store.appendLocal(.keyGrant(.stub), author: author, device: device, created: HLCTimestamp(millis: 2))
        await #expect(throws: LogStoreError.notNextInSequence) { try await store.append(first) }

        let reopened = try SQLiteLogStore(path: path)
        #expect(try await reopened.frontier(author: author)[device.deviceID] == 2)
        #expect(try await reopened.head(author: author, device: device.deviceID)?.sequence == 2)
        let all = try await reopened.entries(author: author, device: device.deviceID, after: 0, limit: 10)
        #expect(all.count == 2 && all.first == first.signed)
        #expect(try await reopened.entries(author: author, device: device.deviceID, after: 1, limit: 10).count == 1)
        #expect(try await reopened.authors() == [author])
    }

    @Test("two store instances on one database (like two processes) can't both append the same sequence")
    func sharedDatabase() async throws {
        let path = temporaryDirectory().appendingPathComponent("db.sqlite")
        let device = DeviceKeyPair()
        let a = try SQLiteLogStore(path: path), b = try SQLiteLogStore(path: path)
        // Both build entry 1 against an empty log; only one append may win.
        let entryA = try VerifiedLogEntry(signing: LogEntry(author: author, device: device.deviceID, sequence: 1, previous: nil,
                                                            created: HLCTimestamp(millis: 1), body: .keyGrant(.stub)), with: device)
        let entryB = try VerifiedLogEntry(signing: LogEntry(author: author, device: device.deviceID, sequence: 1, previous: nil,
                                                            created: HLCTimestamp(millis: 2), body: .keyGrant(.stub)), with: device)
        async let resultA: Bool = (try? await a.append(entryA)) != nil
        async let resultB: Bool = (try? await b.append(entryB)) != nil
        let (okA, okB) = await (resultA, resultB)
        #expect(okA != okB)
        #expect(try await a.frontier(author: author)[device.deviceID] == 1)
    }

    @Test("blobs are stored by hash, and entries record which blobs they still need")
    func blobs() async throws {
        let store = try SQLiteLogStore(path: temporaryDirectory().appendingPathComponent("db.sqlite"))
        let device = DeviceKeyPair()
        let present = try await store.putBlob([1, 2, 3])
        #expect(present == ContentID(hashing: [1, 2, 3]))
        let missing = ContentID(hashing: [9])
        try await store.appendLocal(.keyGrant(.stub), author: author, device: device, created: HLCTimestamp(millis: 1),
                                    blobs: [present, missing])
        #expect(try await store.neededBlobs(limit: 10) == [missing])
        try await store.putBlob([9])
        #expect(try await store.neededBlobs(limit: 10).isEmpty)
        #expect(try await store.blob(missing) == [9])
        #expect(try await store.blob(ContentID(hashing: [7])) == nil)
    }

    @Test("identity documents only move forward")
    func identities() async throws {
        let store = try SQLiteLogStore(path: temporaryDirectory().appendingPathComponent("db.sqlite"))
        let identity = IdentityKeyPair()
        let v2 = try IdentityDocument(user: identity.userID, version: 2, certificates: []).signed(by: identity)
        let v1 = try IdentityDocument(user: identity.userID, version: 1, certificates: []).signed(by: identity)
        try await store.saveIdentityDocument(v2, verified: VerifiedIdentity(verifying: v2, for: identity.userID))
        try await store.saveIdentityDocument(v1, verified: VerifiedIdentity(verifying: v1, for: identity.userID))
        #expect(try await store.identityDocument(for: identity.userID) == v2)
    }

    @Test("an M3 file-based store is imported")
    func legacyImport() async throws {
        let root = temporaryDirectory()
        let device = DeviceKeyPair()
        // Write an M3-style tree: logs/<author>/<device>/<seq>.cbor
        let memory = MemoryLogStore()
        let e1 = try await memory.appendLocal(.keyGrant(.stub), author: author, device: device, created: HLCTimestamp(millis: 1))
        let e2 = try await memory.appendLocal(.keyGrant(.stub), author: author, device: device, created: HLCTimestamp(millis: 2))
        let directory = root.appendingPathComponent("logs").appendingPathComponent(Base32.encode(author.multicodecBytes))
            .appendingPathComponent(Base32.encode(device.deviceID.multicodecBytes))
        for (seq, entry) in [(1, e1), (2, e2)] {
            try FileIO.write(try CBOREncoder().encode(entry.signed),
                             to: directory.appendingPathComponent(String(repeating: "0", count: 19) + "\(seq).cbor"))
        }
        let store = try SQLiteLogStore(path: root.appendingPathComponent("circles.sqlite"))
        #expect(try await store.importLegacyFiles(from: root) == 2)
        #expect(try await store.head(author: author, device: device.deviceID) == LogHead(sequence: 2, id: e2.id))
        #expect(try await store.importLegacyFiles(from: root) == 0) // idempotent
    }
}
