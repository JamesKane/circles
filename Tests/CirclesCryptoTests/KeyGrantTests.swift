import Testing
import CirclesCore
@testable import CirclesCrypto

@Suite("Key grants")
struct KeyGrantTests {
    let now = TestUser.issued + 10_000

    @Test("a member opens a grant and gets the owner's key")
    func roundTrip() throws {
        let alice = try TestUser(), bob = try TestUser()
        let key = AudienceKey.generate(epoch: 3)
        let sealed = try SealedKeyGrant.seal(key, owner: alice.userID, recipient: bob.userID,
                                             to: bob.device.agreementPublicKey, signedBy: alice.device)
        let opened = try sealed.open(with: bob.device, recipient: bob.userID, owner: alice.verified, receivedAtMillis: now)
        #expect(opened.id == key.id)
        #expect(opened.epoch == 3)

        // The granted key really is the same key: it opens Alice's envelope.
        var keyring = AudienceKeyring()
        keyring.insert(opened, owner: alice.userID)
        let envelope = try Envelope.seal([9, 9], author: alice.userID, to: EnvelopeAudience(audienceKeys: [key]))
        #expect(try envelope.open(keyring: keyring) == [9, 9])
    }

    @Test("only the addressed device can open a grant")
    func wrongDevice() throws {
        let alice = try TestUser(), bob = try TestUser(), carol = try TestUser()
        let sealed = try SealedKeyGrant.seal(.generate(epoch: 0), owner: alice.userID, recipient: bob.userID,
                                             to: bob.device.agreementPublicKey, signedBy: alice.device)
        #expect(throws: CryptoError.decryptionFailed) {
            try sealed.open(with: carol.device, recipient: carol.userID, owner: alice.verified, receivedAtMillis: now)
        }
    }

    @Test("a grant addressed to someone else is rejected")
    func wrongRecipient() throws {
        let alice = try TestUser(), bob = try TestUser(), carol = try TestUser()
        // Encrypted to Bob's device but naming Carol as recipient.
        let sealed = try SealedKeyGrant.seal(.generate(epoch: 0), owner: alice.userID, recipient: carol.userID,
                                             to: bob.device.agreementPublicKey, signedBy: alice.device)
        #expect(throws: CryptoError.identityMismatch) {
            try sealed.open(with: bob.device, recipient: bob.userID, owner: alice.verified, receivedAtMillis: now)
        }
    }

    @Test("a grant must be signed by an author device of the owner")
    func signerChecks() throws {
        let alice = try TestUser(), bob = try TestUser(), mallory = try TestUser()
        // Mallory claims to grant one of Alice's keys.
        let forged = try SealedKeyGrant.seal(.generate(epoch: 0), owner: alice.userID, recipient: bob.userID,
                                             to: bob.device.agreementPublicKey, signedBy: mallory.device)
        #expect(throws: CryptoError.unknownDevice(mallory.device.deviceID)) {
            try forged.open(with: bob.device, recipient: bob.userID, owner: alice.verified, receivedAtMillis: now)
        }

        // Alice's pod holds ciphertext but may not hand out keys.
        let pod = try TestUser(capabilities: .storeAndForward)
        let fromPod = try SealedKeyGrant.seal(.generate(epoch: 0), owner: pod.userID, recipient: bob.userID,
                                              to: bob.device.agreementPublicKey, signedBy: pod.device)
        #expect(throws: CryptoError.missingCapability(pod.device.deviceID)) {
            try fromPod.open(with: bob.device, recipient: bob.userID, owner: pod.verified, receivedAtMillis: now)
        }
    }

    @Test("grants received after the signing device was revoked are rejected")
    func revokedSigner() throws {
        let revokedAt = TestUser.issued + 5_000
        let alice = try TestUser(revokedAtMillis: revokedAt), bob = try TestUser()
        let sealed = try SealedKeyGrant.seal(.generate(epoch: 0), owner: alice.userID, recipient: bob.userID,
                                             to: bob.device.agreementPublicKey, signedBy: alice.device)
        #expect(throws: CryptoError.deviceRevoked(alice.device.deviceID)) {
            try sealed.open(with: bob.device, recipient: bob.userID, owner: alice.verified, receivedAtMillis: revokedAt)
        }
    }
}
