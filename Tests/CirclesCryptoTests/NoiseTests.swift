import Testing
import Crypto
@testable import CirclesCrypto

@Suite("Noise XX")
struct NoiseTests {
    static func bytes(_ hex: String) -> [UInt8] {
        var result: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            result.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return result
    }

    static func key(_ hex: String) -> Curve25519.KeyAgreement.PrivateKey {
        try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: bytes(hex))
    }

    /// From the cacophony test-vector suite (vectors/cacophony.txt).
    @Test("matches the cacophony Noise_XX_25519_ChaChaPoly_SHA256 vector")
    func cacophonyVector() throws {
        let prologue = Self.bytes("4a6f686e2047616c74")
        var initiator = NoiseHandshake(
            role: .initiator,
            staticKey: Self.key("e61ef9919cde45dd5f82166404bd08e38bceb5dfdfded0a34c8df7ed542214d1"),
            prologue: prologue,
            ephemeral: Self.key("893e28b9dc6ca8d611ab664754b8ceb7bac5117349a4439a6b0569da977c464a")
        )
        var responder = NoiseHandshake(
            role: .responder,
            staticKey: Self.key("4a3acbfdb163dec651dfa3194dece676d437029c62a408b4c5ea9114246e4893"),
            prologue: prologue,
            ephemeral: Self.key("bbdb4cdbd309f1a1f2e1456967fe288cadd6f712d65dc7b7793d5e63da6b375b")
        )
        let messages: [(payload: String, ciphertext: String)] = [
            ("4c756477696720766f6e204d69736573",
             "ca35def5ae56cec33dc2036731ab14896bc4c75dbb07a61f879f8e3afa4c79444c756477696720766f6e204d69736573"),
            ("4d757272617920526f746862617264",
             "95ebc60d2b1fa672c1f46a8aa265ef51bfe38e7ccb39ec5be34069f14480884381cbad1f276e038c48378ffce2b65285e08d6b68aaa3629a5a8639392490e5b9bd5269c2f1e4f488ed8831161f19b7815528f8982ffe09be9b5c412f8a0db50f8814c7194e83f23dbd8d162c9326ad"),
            ("462e20412e20486179656b",
             "c7195ffacac1307ff99046f219750fc47693e23c3cb08b89c2af808b444850a80ae475b9df0f169ae80a89be0865b57f58c9fea0d4ec82a286427402f113e4b6ae769a1d95941d49b25030"),
            ("4361726c204d656e676572", "96763ed773f8e47bb3712f0e29b3060ffc956ffc146cee53d5e1df"),
            ("4a65616e2d426170746973746520536179", "3e40f15f6f3a46ae446b253bf8b1d9ffb6ed9b174d272328ff91a7e2e5c79c07f5"),
            ("457567656e2042f6686d20766f6e2042617765726b", "eb3f3515110702e047a6c9da4478b6ead94873c11c0f2d710ddb3f09fce024b3a58502ae3f"),
        ]

        // Handshake: messages alternate starting with the initiator.
        for i in 0..<3 {
            let (payload, expected) = (Self.bytes(messages[i].payload), Self.bytes(messages[i].ciphertext))
            let ciphertext: [UInt8]
            if i % 2 == 0 {
                ciphertext = try initiator.writeMessage(payload: payload)
                #expect(try responder.readMessage(ciphertext) == payload)
            } else {
                ciphertext = try responder.writeMessage(payload: payload)
                #expect(try initiator.readMessage(ciphertext) == payload)
            }
            #expect(ciphertext == expected, "handshake message \(i)")
        }
        #expect(initiator.handshakeHash == Self.bytes("c8e5f64e846193be2a834104c2a009868d6c9f3bd3c186299888b488b2f1f58e"))
        #expect(responder.handshakeHash == initiator.handshakeHash)

        // Transport messages continue the alternation.
        var i = try initiator.split(), r = try responder.split()
        for n in 3..<6 {
            let (payload, expected) = (Self.bytes(messages[n].payload), Self.bytes(messages[n].ciphertext))
            if n % 2 == 0 {
                let ciphertext = try i.send.encrypt(payload)
                #expect(ciphertext == expected, "transport message \(n)")
                #expect(try r.receive.decrypt(ciphertext) == payload)
            } else {
                let ciphertext = try r.send.encrypt(payload)
                #expect(ciphertext == expected, "transport message \(n)")
                #expect(try i.receive.decrypt(ciphertext) == payload)
            }
        }
    }

    @Test("each side learns the other's device agreement key")
    func authenticatesDevices() throws {
        let alice = DeviceKeyPair(), bob = DeviceKeyPair()
        var i = NoiseHandshake(role: .initiator, device: alice)
        var r = NoiseHandshake(role: .responder, device: bob)
        _ = try r.readMessage(try i.writeMessage())
        _ = try i.readMessage(try r.writeMessage())
        _ = try r.readMessage(try i.writeMessage())
        #expect(i.isComplete && r.isComplete)
        #expect(try i.split().remoteStaticKey == bob.agreementPublicKey)
        #expect(try r.split().remoteStaticKey == alice.agreementPublicKey)
    }

    @Test("a different prologue makes the handshake fail")
    func prologueBinding() throws {
        var i = NoiseHandshake(role: .initiator, device: DeviceKeyPair(), prologue: Array("circles/v1/noise".utf8))
        var r = NoiseHandshake(role: .responder, device: DeviceKeyPair(), prologue: Array("circles/v2/noise".utf8))
        _ = try r.readMessage(try i.writeMessage())
        #expect(throws: NoiseError.decryptionFailed) { try i.readMessage(try r.writeMessage()) }
    }

    @Test("messages out of turn, tampered or replayed are rejected")
    func misuse() throws {
        var i = NoiseHandshake(role: .initiator, device: DeviceKeyPair())
        var r = NoiseHandshake(role: .responder, device: DeviceKeyPair())
        #expect(throws: NoiseError.unexpectedMessage) { try r.writeMessage() }
        _ = try r.readMessage(try i.writeMessage())
        var second = try r.writeMessage()
        second[40] ^= 1
        #expect(throws: NoiseError.decryptionFailed) { try i.readMessage(second) }

        var a = NoiseHandshake(role: .initiator, device: DeviceKeyPair())
        var b = NoiseHandshake(role: .responder, device: DeviceKeyPair())
        _ = try b.readMessage(try a.writeMessage())
        _ = try a.readMessage(try b.writeMessage())
        _ = try b.readMessage(try a.writeMessage())
        var at = try a.split(), bt = try b.split()
        let message = try at.send.encrypt([1, 2, 3])
        #expect(try bt.receive.decrypt(message) == [1, 2, 3])
        // Replaying it fails: the receiver's nonce has moved on.
        #expect(throws: NoiseError.decryptionFailed) { try bt.receive.decrypt(message) }
    }
}
