#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Crypto

/// The Noise Protocol Framework (revision 34), pattern XX with
/// `25519_ChaChaPoly_SHA256`, used to secure peer sessions
/// (docs/DESIGN.md §7.1). Each side's Noise static key is its device's X25519
/// agreement key, so after the handshake each side knows which certified
/// device it's talking to.
///
///     -> e
///     <- e, ee, s, es
///     -> s, se
public struct NoiseHandshake: Sendable {
    public enum Role: Sendable { case initiator, responder }

    public static let protocolName = "Noise_XX_25519_ChaChaPoly_SHA256"
    public static let circlesPrologue = Array("circles/v1/noise".utf8)
    /// The largest Noise message, including the 16-byte tag.
    public static let maxMessageLength = 65535

    public let role: Role
    private var symmetric: SymmetricState
    private let s: Curve25519.KeyAgreement.PrivateKey
    private var e: Curve25519.KeyAgreement.PrivateKey?
    private var re: Curve25519.KeyAgreement.PublicKey?
    private var rs: Curve25519.KeyAgreement.PublicKey?
    private var messageIndex = 0
    private var fixedEphemeral: Curve25519.KeyAgreement.PrivateKey?

    public init(role: Role, device: borrowing DeviceKeyPair, prologue: [UInt8] = NoiseHandshake.circlesPrologue) {
        self.init(role: role, staticKey: device.agreementKey, prologue: prologue, ephemeral: nil)
    }

    /// `ephemeral` is for test vectors only.
    init(role: Role, staticKey: Curve25519.KeyAgreement.PrivateKey, prologue: [UInt8], ephemeral: Curve25519.KeyAgreement.PrivateKey?) {
        self.role = role
        s = staticKey
        fixedEphemeral = ephemeral
        symmetric = SymmetricState(protocolName: Self.protocolName)
        symmetric.mixHash(prologue)
    }

    public var isComplete: Bool { messageIndex == 3 }

    /// Whether it's this side's turn to write.
    public var isMyTurn: Bool {
        (messageIndex % 2 == 0) == (role == .initiator)
    }

    /// The peer's static key, known after the peer's `s` token.
    public var remoteStaticKey: AgreementPublicKey? { rs.map(AgreementPublicKey.init) }

    /// Uniquely identifies the session; usable for channel binding.
    public var handshakeHash: [UInt8] { symmetric.h }

    public mutating func writeMessage(payload: [UInt8] = []) throws(NoiseError) -> [UInt8] {
        guard !isComplete, isMyTurn else { throw .unexpectedMessage }
        var out: [UInt8] = []
        switch messageIndex {
        case 0:
            writeE(&out)
        case 1:
            writeE(&out)
            try mixDH(e, re)
            try writeS(&out)
            try mixDH(s, re) // es (responder side)
        default:
            try writeS(&out)
            try mixDH(s, re) // se (initiator side)
        }
        out += try symmetric.encryptAndHash(payload)
        guard out.count <= Self.maxMessageLength else { throw .messageTooLong }
        messageIndex += 1
        return out
    }

    public mutating func readMessage(_ message: [UInt8]) throws(NoiseError) -> [UInt8] {
        guard !isComplete, !isMyTurn else { throw .unexpectedMessage }
        guard message.count <= Self.maxMessageLength else { throw .messageTooLong }
        var input = message[...]
        switch messageIndex {
        case 0:
            try readE(&input)
        case 1:
            try readE(&input)
            try mixDH(e, re)
            try readS(&input)
            try mixDH(e, rs) // es (initiator side)
        default:
            try readS(&input)
            try mixDH(e, rs) // se (responder side)
        }
        let payload = try symmetric.decryptAndHash(Array(input))
        messageIndex += 1
        return payload
    }

    /// The transport ciphers once the handshake is complete.
    public func split() throws(NoiseError) -> NoiseTransport {
        guard isComplete, let rs else { throw .handshakeIncomplete }
        let (c1, c2) = symmetric.split()
        return role == .initiator
            ? NoiseTransport(send: c1, receive: c2, remoteStaticKey: AgreementPublicKey(rs), handshakeHash: symmetric.h)
            : NoiseTransport(send: c2, receive: c1, remoteStaticKey: AgreementPublicKey(rs), handshakeHash: symmetric.h)
    }

    // MARK: Tokens

    private mutating func writeE(_ out: inout [UInt8]) {
        let ephemeral = fixedEphemeral ?? Curve25519.KeyAgreement.PrivateKey()
        e = ephemeral
        let pub = Array(ephemeral.publicKey.rawRepresentation)
        out += pub
        symmetric.mixHash(pub)
    }

    private mutating func writeS(_ out: inout [UInt8]) throws(NoiseError) {
        out += try symmetric.encryptAndHash(Array(s.publicKey.rawRepresentation))
    }

    private mutating func readE(_ input: inout ArraySlice<UInt8>) throws(NoiseError) {
        guard input.count >= 32 else { throw .malformedMessage }
        let bytes = Array(input.prefix(32))
        input = input.dropFirst(32)
        guard let key = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: bytes) else { throw .malformedMessage }
        re = key
        symmetric.mixHash(bytes)
    }

    private mutating func readS(_ input: inout ArraySlice<UInt8>) throws(NoiseError) {
        let length = 32 + (symmetric.cipher.hasKey ? 16 : 0)
        guard input.count >= length else { throw .malformedMessage }
        let bytes = try symmetric.decryptAndHash(Array(input.prefix(length)))
        input = input.dropFirst(length)
        guard let key = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: bytes) else { throw .malformedMessage }
        rs = key
    }

    private mutating func mixDH(_ privateKey: Curve25519.KeyAgreement.PrivateKey?, _ publicKey: Curve25519.KeyAgreement.PublicKey?) throws(NoiseError) {
        guard let privateKey, let publicKey,
              let shared = try? privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        else { throw .keyAgreementFailed }
        symmetric.mixKey(shared.withUnsafeBytes { Array($0) })
    }
}

/// The two transport ciphers produced by a completed handshake.
public struct NoiseTransport: Sendable {
    public var send: NoiseCipherState
    public var receive: NoiseCipherState
    public let remoteStaticKey: AgreementPublicKey
    public let handshakeHash: [UInt8]
}

public enum NoiseError: Error, Sendable, Equatable {
    case unexpectedMessage
    case malformedMessage
    case messageTooLong
    case decryptionFailed
    case keyAgreementFailed
    case handshakeIncomplete
    case nonceExhausted
}

/// Noise CipherState: ChaCha20-Poly1305 with a 64-bit counter nonce
/// (encoded as 32 zero bits followed by the little-endian counter).
public struct NoiseCipherState: Sendable {
    private var key: SymmetricKey?
    private var nonce: UInt64 = 0

    init(key: SymmetricKey? = nil) {
        self.key = key
    }

    var hasKey: Bool { key != nil }

    public mutating func encrypt(_ plaintext: [UInt8], associatedData: [UInt8] = []) throws(NoiseError) -> [UInt8] {
        guard let key else { return plaintext }
        guard nonce != .max else { throw .nonceExhausted }
        defer { nonce += 1 }
        do {
            let box = try ChaChaPoly.seal(plaintext, using: key, nonce: Self.nonce(nonce), authenticating: associatedData)
            return Array(box.ciphertext) + Array(box.tag)
        } catch {
            throw .decryptionFailed
        }
    }

    public mutating func decrypt(_ ciphertext: [UInt8], associatedData: [UInt8] = []) throws(NoiseError) -> [UInt8] {
        guard let key else { return ciphertext }
        guard nonce != .max else { throw .nonceExhausted }
        guard ciphertext.count >= 16,
              let box = try? ChaChaPoly.SealedBox(nonce: Self.nonce(nonce), ciphertext: ciphertext.dropLast(16), tag: ciphertext.suffix(16)),
              let plaintext = try? ChaChaPoly.open(box, using: key, authenticating: associatedData)
        else { throw .decryptionFailed }
        nonce += 1
        return Array(plaintext)
    }

    private static func nonce(_ n: UInt64) -> ChaChaPoly.Nonce {
        var bytes = [UInt8](repeating: 0, count: 4)
        withUnsafeBytes(of: n.littleEndian) { bytes += $0 }
        return try! ChaChaPoly.Nonce(data: bytes)
    }
}

/// Noise SymmetricState with SHA-256 and HMAC-based HKDF.
private struct SymmetricState: Sendable {
    var cipher = NoiseCipherState()
    var ck: [UInt8]
    var h: [UInt8]

    init(protocolName: String) {
        let name = Array(protocolName.utf8)
        h = name.count <= 32 ? name + [UInt8](repeating: 0, count: 32 - name.count) : Array(SHA256.hash(data: name))
        ck = h
    }

    mutating func mixHash(_ data: [UInt8]) {
        h = Array(SHA256.hash(data: h + data))
    }

    mutating func mixKey(_ inputKeyMaterial: [UInt8]) {
        let (newCK, tempK) = Self.hkdf(chainingKey: ck, inputKeyMaterial: inputKeyMaterial)
        ck = newCK
        cipher = NoiseCipherState(key: SymmetricKey(data: tempK))
    }

    mutating func encryptAndHash(_ plaintext: [UInt8]) throws(NoiseError) -> [UInt8] {
        let ciphertext = try cipher.encrypt(plaintext, associatedData: h)
        mixHash(ciphertext)
        return ciphertext
    }

    mutating func decryptAndHash(_ ciphertext: [UInt8]) throws(NoiseError) -> [UInt8] {
        let plaintext = try cipher.decrypt(ciphertext, associatedData: h)
        mixHash(ciphertext)
        return plaintext
    }

    func split() -> (NoiseCipherState, NoiseCipherState) {
        let (k1, k2) = Self.hkdf(chainingKey: ck, inputKeyMaterial: [])
        return (NoiseCipherState(key: SymmetricKey(data: k1)), NoiseCipherState(key: SymmetricKey(data: k2)))
    }

    /// Noise's HKDF with two outputs (spec §4.3).
    static func hkdf(chainingKey: [UInt8], inputKeyMaterial: [UInt8]) -> ([UInt8], [UInt8]) {
        let tempKey = SymmetricKey(data: hmac(SymmetricKey(data: chainingKey), inputKeyMaterial))
        let output1 = hmac(tempKey, [0x01])
        let output2 = hmac(tempKey, output1 + [0x02])
        return (output1, output2)
    }

    private static func hmac(_ key: SymmetricKey, _ data: [UInt8]) -> [UInt8] {
        Array(HMAC<SHA256>.authenticationCode(for: data, using: key))
    }
}
