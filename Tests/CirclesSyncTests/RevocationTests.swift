import Testing
import CirclesCore
import CirclesCrypto
@testable import CirclesSync

/// A user with two devices; the second gets revoked.
struct TwoDevices: ~Copyable {
    let identity = IdentityKeyPair()
    let laptop = DeviceKeyPair()
    let phone = DeviceKeyPair()

    func document(version: UInt64, revoking revocation: DeviceRevocation? = nil) throws -> SignedObject {
        let certificates = [
            try DeviceCertificate.issue(for: laptop, by: identity, capabilities: .author, issuedMillis: 1, validForMillis: 1 << 50),
            try DeviceCertificate.issue(for: phone, by: identity, capabilities: .author, issuedMillis: 1, validForMillis: 1 << 50),
        ]
        return try IdentityDocument(user: identity.userID, version: version, certificates: certificates,
                                    revocations: revocation.map { [$0] } ?? []).signed(by: identity)
    }

    /// The phone's log entry `sequence`, claiming `millis`.
    func phoneEntry(_ sequence: UInt64, after previous: ContentID?, millis: UInt64) throws -> VerifiedLogEntry {
        let entry = LogEntry(author: identity.userID, device: phone.deviceID, sequence: sequence, previous: previous,
                             created: HLCTimestamp(millis: millis), body: .keyGrant(try CBORDecoder().decode(SealedKeyGrant.self, from: CBOREncoder().encode(StubGrant()))))
        return try VerifiedLogEntry(signing: entry, with: phone)
    }
}

struct StubGrant: Codable { var encapsulatedKey: [UInt8] = [1]; var ciphertext: [UInt8] = [2] }

@Suite("Device revocation")
struct RevocationTests {
    @Test("a revoked device can't backdate entries past its last standing one")
    func backdating() throws {
        let user = TwoDevices()
        let first = try user.phoneEntry(1, after: nil, millis: 100)
        let second = try user.phoneEntry(2, after: first.id, millis: 200)
        // Revoked at 1000, standing through entry 1. Entry 2 claims 200,
        // before the revocation time, but comes after the last standing entry.
        let revocation = DeviceRevocation(device: user.phone.deviceID, revokedAtMillis: 1000, lastSequence: 1)
        let revoked = try VerifiedIdentity(verifying: try user.document(version: 2, revoking: revocation), for: user.identity.userID)
        #expect(throws: Never.self) { try VerifiedLogEntry(verifying: first.signed, author: revoked, after: nil) }
        #expect(throws: SyncError.self) {
            try VerifiedLogEntry(verifying: second.signed, author: revoked, after: LogHead(sequence: 1, id: first.id))
        }
        // Without lastSequence, only the time applies, and the backdated entry passes.
        let timeOnly = try VerifiedIdentity(verifying: try user.document(version: 2, revoking: DeviceRevocation(device: user.phone.deviceID, revokedAtMillis: 1000)),
                                            for: user.identity.userID)
        #expect(throws: Never.self) { try VerifiedLogEntry(verifying: second.signed, author: timeOnly, after: LogHead(sequence: 1, id: first.id)) }
    }

    @Test("learning of a revocation drops entries already stored past the cutoff")
    func pruning() async throws {
        let user = TwoDevices()
        let store = MemoryLogStore()
        let initial = try user.document(version: 1)
        try await store.saveIdentityDocument(initial, verified: try VerifiedIdentity(verifying: initial, for: user.identity.userID))
        let first = try user.phoneEntry(1, after: nil, millis: 100)
        let second = try user.phoneEntry(2, after: first.id, millis: 200)
        try await store.append(first)
        try await store.append(second)
        let revoked = try user.document(version: 2, revoking: DeviceRevocation(device: user.phone.deviceID, revokedAtMillis: 1000, lastSequence: 1))
        try await store.saveIdentityDocument(revoked, verified: try VerifiedIdentity(verifying: revoked, for: user.identity.userID))
        #expect(try await store.allEntries(author: user.identity.userID).map(\.contentID) == [first.id])
    }
}
