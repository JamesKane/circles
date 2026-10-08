import Testing
import CirclesCore
@testable import CirclesCrypto

@Suite("Identity documents and device certificates")
struct IdentityTests {
    let now = TestUser.issued + 10_000

    @Test("a certified device's objects verify")
    func certifiedDevice() throws {
        let alice = try TestUser()
        let post = try SignedObject(signing: [42], label: .post, with: alice.device)
        #expect(try alice.verified.verify(post, label: .post, atMillis: now) == [42])
        #expect(alice.verified.certificates[alice.device.deviceID]?.agreementKey == alice.device.agreementPublicKey)
    }

    @Test("an uncertified device is rejected")
    func unknownDevice() throws {
        let alice = try TestUser()
        let stranger = DeviceKeyPair()
        let post = try SignedObject(signing: [42], label: .post, with: stranger)
        #expect(throws: CryptoError.unknownDevice(stranger.deviceID)) {
            try alice.verified.verify(post, label: .post, atMillis: now)
        }
    }

    @Test("certificates only cover their validity window")
    func validityWindow() throws {
        let alice = try TestUser()
        let post = try SignedObject(signing: [1], label: .post, with: alice.device)
        let id = alice.device.deviceID
        let before = TestUser.issued - 1
        let after = TestUser.issued + TestUser.validFor
        #expect(throws: CryptoError.certificateNotValid(id, atMillis: before)) {
            try alice.verified.verify(post, label: .post, atMillis: before)
        }
        #expect(throws: CryptoError.certificateNotValid(id, atMillis: after)) {
            try alice.verified.verify(post, label: .post, atMillis: after)
        }
    }

    @Test("revocation rejects objects from the revocation time onward, not before")
    func revocation() throws {
        let revokedAt = TestUser.issued + 5_000
        let alice = try TestUser(revokedAtMillis: revokedAt)
        let post = try SignedObject(signing: [1], label: .post, with: alice.device)
        #expect(try alice.verified.verify(post, label: .post, atMillis: revokedAt - 1) == [1])
        #expect(throws: CryptoError.deviceRevoked(alice.device.deviceID)) {
            try alice.verified.verify(post, label: .post, atMillis: revokedAt)
        }
    }

    @Test("a pod can't author content")
    func podCannotAuthor() throws {
        let alice = try TestUser(capabilities: .storeAndForward)
        let post = try SignedObject(signing: [1], label: .post, with: alice.device)
        #expect(throws: CryptoError.missingCapability(alice.device.deviceID)) {
            try alice.verified.verify(post, label: .post, atMillis: now)
        }
        #expect(try alice.verified.verify(post, label: .post, atMillis: now, requiring: .storeAndForward) == [1])
    }

    @Test("a document must be signed by the user it describes")
    func documentSigner() throws {
        let alice = try TestUser()
        let mallory = IdentityKeyPair()
        // Mallory can't sign a document for Alice...
        #expect(throws: CryptoError.identityMismatch) {
            try IdentityDocument(user: alice.userID, version: 2, certificates: []).signed(by: mallory)
        }
        // ...and her own document can't be passed off as Alice's.
        let malloryDoc = try IdentityDocument(user: mallory.userID, version: 1, certificates: []).signed(by: mallory)
        #expect(throws: CryptoError.unexpectedSigner) {
            try VerifiedIdentity(verifying: malloryDoc, for: alice.userID)
        }
    }

    @Test("a certificate issued by another identity is rejected")
    func foreignCertificate() throws {
        let alice = try TestUser()
        let mallory = IdentityKeyPair()
        let malloryDevice = DeviceKeyPair()
        let foreign = try DeviceCertificate.issue(
            for: malloryDevice, by: mallory, capabilities: .author,
            issuedMillis: TestUser.issued, validForMillis: TestUser.validFor
        )
        let document = try IdentityDocument(
            user: alice.userID, version: 2, certificates: [alice.certificate, foreign]
        ).signed(by: alice.identity)
        #expect(throws: CryptoError.unexpectedSigner) {
            try VerifiedIdentity(verifying: document, for: alice.userID)
        }
    }

    @Test("on renewal, the certificate with the later expiry wins")
    func renewal() throws {
        let identity = IdentityKeyPair()
        let device = DeviceKeyPair()
        let old = try DeviceCertificate.issue(for: device, by: identity, capabilities: .author,
                                              issuedMillis: 1_000, validForMillis: 10_000)
        let renewed = try DeviceCertificate.issue(for: device, by: identity, capabilities: .author,
                                                  issuedMillis: 9_000, validForMillis: 10_000)
        for order in [[old, renewed], [renewed, old]] {
            let document = try IdentityDocument(user: identity.userID, version: 1, certificates: order).signed(by: identity)
            let verified = try VerifiedIdentity(verifying: document, for: identity.userID)
            #expect(verified.certificates[device.deviceID]?.expiresMillis == 19_000)
        }
    }
}
