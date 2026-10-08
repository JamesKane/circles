import Testing
import CirclesCore
@testable import CirclesCrypto

@Suite("Signed objects")
struct SignedObjectTests {
    @Test("a signature verifies for its label and signer")
    func roundTrip() throws {
        let device = DeviceKeyPair()
        let signed = try SignedObject(signing: [1, 2, 3], label: .post, with: device)
        #expect(try signed.verifiedPayload(label: .post, signer: device.deviceID.publicKey) == [1, 2, 3])
        #expect(signed.signerDevice == device.deviceID)
        #expect(signed.contentID == ContentID(hashing: [1, 2, 3]))
    }

    @Test("a signature for one label is rejected under another")
    func domainSeparation() throws {
        let device = DeviceKeyPair()
        let signed = try SignedObject(signing: [1, 2, 3], label: .comment, with: device)
        #expect(throws: CryptoError.invalidSignature) {
            try signed.verifiedPayload(label: .deviceCertificate, signer: device.deviceID.publicKey)
        }
    }

    @Test("the expected signer is enforced")
    func wrongSigner() throws {
        let signed = try SignedObject(signing: [1], label: .post, with: DeviceKeyPair())
        #expect(throws: CryptoError.unexpectedSigner) {
            try signed.verifiedPayload(label: .post, signer: DeviceKeyPair().deviceID.publicKey)
        }
        // Swapping in another key as the claimed signer doesn't help.
        let other = DeviceKeyPair()
        let forged = SignedObject(payload: signed.payload, signer: other.deviceID.publicKey, signature: signed.signature)
        #expect(throws: CryptoError.invalidSignature) {
            try forged.verifiedPayload(label: .post, signer: other.deviceID.publicKey)
        }
    }

    @Test("property: flipping any bit of the payload or signature breaks verification")
    func bitFlips() throws {
        var rng = SplitMix64(seed: 0x5167)
        let device = DeviceKeyPair()
        let signer = device.deviceID.publicKey
        for _ in 0..<200 {
            let payload = rng.bytes(Int.random(in: 1...512, using: &rng))
            let signed = try SignedObject(signing: payload, label: .post, with: device)
            var p = signed.payload, s = signed.signature
            if Bool.random(using: &rng) {
                p[Int.random(in: 0..<p.count, using: &rng)] ^= 1 << UInt8.random(in: 0..<8, using: &rng)
            } else {
                s[Int.random(in: 0..<s.count, using: &rng)] ^= 1 << UInt8.random(in: 0..<8, using: &rng)
            }
            #expect(throws: CryptoError.invalidSignature) {
                try SignedObject(payload: p, signer: signer, signature: s).verifiedPayload(label: .post, signer: signer)
            }
        }
    }

    @Test("keys survive export and import")
    func keyExport() throws {
        let identity = IdentityKeyPair()
        let restoredIdentity = try IdentityKeyPair(rawRepresentation: identity.exportRawRepresentation())
        #expect(restoredIdentity.userID == identity.userID)

        let device = DeviceKeyPair()
        let raw = device.exportRawRepresentation()
        let restored = try DeviceKeyPair(signingKey: raw.signingKey, agreementKey: raw.agreementKey)
        #expect(restored.deviceID == device.deviceID)
        #expect(restored.agreementPublicKey == device.agreementPublicKey)

        #expect(throws: CryptoError.invalidKey) { _ = try IdentityKeyPair(rawRepresentation: [1, 2, 3]) }
    }
}
