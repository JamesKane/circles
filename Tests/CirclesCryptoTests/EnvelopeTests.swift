import Testing
import CirclesCore
@testable import CirclesCrypto

@Suite("Envelopes")
struct EnvelopeTests {
    static let alice = try! UserID(ed25519PublicKey: [UInt8](repeating: 0xA1, count: 32))

    func keyring(_ keys: AudienceKey..., owner: UserID = alice) -> AudienceKeyring {
        var keyring = AudienceKeyring()
        for key in keys { keyring.insert(key, owner: owner) }
        return keyring
    }

    @Test("circle members open, others don't")
    func circleAudience() throws {
        let family = AudienceKey.generate(epoch: 0), work = AudienceKey.generate(epoch: 0)
        let envelope = try Envelope.seal(Array("hi".utf8), author: Self.alice, to: EnvelopeAudience(audienceKeys: [family]))
        #expect(try envelope.open(keyring: keyring(family)) == Array("hi".utf8))
        #expect(throws: CryptoError.notARecipient) { try envelope.open(keyring: keyring(work)) }
        #expect(throws: CryptoError.notARecipient) { try envelope.open(keyring: AudienceKeyring()) }
    }

    @Test("a removed member can read old posts but not new ones")
    func removedMember() throws {
        let bob = CircleKeyScheduleTests.user(1), carol = CircleKeyScheduleTests.user(2)
        var schedule = CircleKeySchedule(members: [bob, carol])
        let epoch0 = schedule.current
        let old = try Envelope.seal([1], author: Self.alice, to: EnvelopeAudience(audienceKeys: [schedule.current]))
        _ = schedule.remove([carol])
        let new = try Envelope.seal([2], author: Self.alice, to: EnvelopeAudience(audienceKeys: [schedule.current]))

        let carolsKeys = keyring(epoch0)
        #expect(try old.open(keyring: carolsKeys) == [1])
        #expect(throws: CryptoError.notARecipient) { try new.open(keyring: carolsKeys) }
        #expect(try new.open(keyring: keyring(epoch0, schedule.current)) == [2])
    }

    @Test("envelopes with more than 256 wraps are neither sealed nor opened, so trial decryption stays cheap")
    func wrapLimit() throws {
        let devices = (0...Envelope.maxWraps).map { _ in DeviceKeyPair().agreementPublicKey }
        #expect(throws: CryptoError.audienceTooLarge) {
            try Envelope.seal([1], author: Self.alice, to: EnvelopeAudience(devices: devices))
        }
        let me = DeviceKeyPair()
        let real = try Envelope.seal([1], author: Self.alice, to: EnvelopeAudience(devices: [me.agreementPublicKey]))
        let padded = Envelope(version: real.version, author: real.author, nonceBytes: real.nonce, ciphertext: real.ciphertext,
                              audienceWraps: [], deviceWraps: Array(repeating: real.deviceWraps[0], count: Envelope.maxWraps + 1))
        #expect(throws: CryptoError.audienceTooLarge) { try padded.open(keyring: AudienceKeyring(), device: me) }
        #expect(try real.open(keyring: AudienceKeyring(), device: me) == [1])
    }

    @Test("individually named devices open by trial decryption")
    func deviceAudience() throws {
        let bobPhone = DeviceKeyPair(), bobLaptop = DeviceKeyPair(), carol = DeviceKeyPair()
        let envelope = try Envelope.seal([7], author: Self.alice, to: EnvelopeAudience(
            devices: [bobPhone.agreementPublicKey, bobLaptop.agreementPublicKey]
        ))
        #expect(try envelope.open(keyring: AudienceKeyring(), device: bobPhone) == [7])
        #expect(try envelope.open(keyring: AudienceKeyring(), device: bobLaptop) == [7])
        #expect(throws: CryptoError.notARecipient) {
            try envelope.open(keyring: AudienceKeyring(), device: carol)
        }
    }

    @Test("a key only opens envelopes from the author who owns it")
    func authorBinding() throws {
        let key = AudienceKey.generate(epoch: 0)
        let mallory = try UserID(ed25519PublicKey: [UInt8](repeating: 0x66, count: 32))
        // Mallory, a member of Alice's circle, uses Alice's key under her own name.
        let envelope = try Envelope.seal([1], author: mallory, to: EnvelopeAudience(audienceKeys: [key]))
        #expect(throws: CryptoError.notARecipient) { try envelope.open(keyring: keyring(key)) }
    }

    @Test("padding hides small differences in length")
    func padding() throws {
        let key = AudienceKey.generate(epoch: 0)
        let a = try Envelope.seal([UInt8](repeating: 1, count: 1000), author: Self.alice, to: EnvelopeAudience(audienceKeys: [key]))
        let b = try Envelope.seal([UInt8](repeating: 1, count: 1015), author: Self.alice, to: EnvelopeAudience(audienceKeys: [key]))
        #expect(a.ciphertext.count == b.ciphertext.count)
    }

    @Test("Padmé padding has bounded overhead and round-trips", arguments: [0, 1, 2, 3, 9, 100, 1000, 4096, 100_000])
    func padme(length: Int) throws {
        let padded = Padding.pad([UInt8](repeating: 0xAB, count: length))
        #expect(padded.count >= length + 4)
        #expect(padded.count == Padding.paddedLength(padded.count)) // padded sizes are fixed points
        if length >= 256 { #expect(Double(padded.count) <= Double(length + 4) * 1.12) }
        #expect(try Padding.unpad(padded) == [UInt8](repeating: 0xAB, count: length))
    }

    @Test("malformed padding is rejected")
    func malformedPadding() throws {
        var padded = Padding.pad([UInt8](repeating: 1, count: 1000)) // 1004 framed → 1024
        padded[padded.count - 1] = 1
        #expect(throws: CryptoError.malformedPadding) { try Padding.unpad(padded) }
        #expect(throws: CryptoError.malformedPadding) { try Padding.unpad([0, 0, 1, 0]) }
        #expect(throws: CryptoError.malformedPadding) { try Padding.unpad([0, 0]) }
    }

    /// Wraps aren't authenticated as a set: changing a wrap meant for someone
    /// else leaves yours working. Tampering can deny access, but must never
    /// change what anyone reads.
    @Test("property: a tampered envelope fails or yields the original plaintext, never anything else")
    func tampering() throws {
        var rng = SplitMix64(seed: 0xE57E)
        let key = AudienceKey.generate(epoch: 0)
        let device = DeviceKeyPair()
        let plaintext = rng.bytes(300)
        let envelope = try Envelope.seal(plaintext, author: Self.alice, to: EnvelopeAudience(
            audienceKeys: [key], devices: [device.agreementPublicKey]
        ))
        let encoded = try CBOREncoder().encode(envelope)
        for _ in 0..<300 {
            var tampered = encoded
            tampered[Int.random(in: 0..<tampered.count, using: &rng)] ^= UInt8.random(in: 1 ... .max, using: &rng)
            guard let decoded = try? CBORDecoder().decode(Envelope.self, from: tampered) else { continue }
            if let opened = try? decoded.open(keyring: keyring(key), device: device) {
                #expect(opened == plaintext)
            }
        }
    }

    @Test("property: every member of a random audience opens it, nobody else does")
    func randomAudiences() throws {
        var rng = SplitMix64(seed: 0xA0D1)
        let keys = (0..<6).map { _ in AudienceKey.generate(epoch: 0) }
        let devices = (0..<4).map { _ in DeviceBox() }
        for _ in 0..<60 {
            let chosenKeys = keys.indices.filter { _ in Bool.random(using: &rng) }
            let chosenDevices = devices.indices.filter { _ in Bool.random(using: &rng) }
            let plaintext = rng.bytes(Int.random(in: 0...2000, using: &rng))
            let envelope = try Envelope.seal(plaintext, author: Self.alice, to: EnvelopeAudience(
                audienceKeys: chosenKeys.map { keys[$0] },
                devices: chosenDevices.map { devices[$0].keys.agreementPublicKey }
            ))
            #expect(envelope.ciphertext.count == Padding.paddedLength(plaintext.count + 4) + 16)
            for i in keys.indices {
                let result = try? envelope.open(keyring: keyring(keys[i]))
                #expect(result == (chosenKeys.contains(i) ? plaintext : nil))
            }
            for i in devices.indices {
                let result = try? envelope.open(keyring: AudienceKeyring(), device: devices[i].keys)
                #expect(result == (chosenDevices.contains(i) ? plaintext : nil))
            }
        }
    }

    @Test("end to end: Alice posts to a circle, Bob reads and verifies it")
    func endToEnd() throws {
        let alice = try TestUser(), bob = try TestUser()
        let friends = CircleKeySchedule(members: [bob.userID])
        let grant = try SealedKeyGrant.seal(friends.current, owner: alice.userID, recipient: bob.userID,
                                            to: bob.device.agreementPublicKey, signedBy: alice.device)

        let post = Post(author: alice.userID, created: HLCTimestamp(millis: TestUser.issued + 20_000),
                        body: RichText(plain: "Only my friends can read this"))
        let envelope = try Envelope.seal(post, label: .post, signedBy: alice.device, author: alice.userID,
                                         to: EnvelopeAudience(audienceKeys: [friends.current]))

        // Bob's side.
        var bobsKeys = AudienceKeyring()
        bobsKeys.insert(try grant.open(with: bob.device, recipient: bob.userID, owner: alice.verified,
                                       receivedAtMillis: TestUser.issued + 15_000), owner: alice.userID)
        let signed = try envelope.openSignedObject(keyring: bobsKeys, device: bob.device)
        let claimed = try CBORDecoder().decode(Post.self, from: signed.payload)
        let payload = try alice.verified.verify(signed, label: .post, atMillis: claimed.created.millis)
        #expect(try CBORDecoder().decode(Post.self, from: payload) == post)
        #expect(claimed.author == envelope.author)
    }
}
