public import CirclesCrypto
import Crypto

/// S/Kademlia's static puzzle (docs/DESIGN.md §12): a DHT node's key counts
/// only if SHA-256(label ‖ key) starts with `bits` zero bits. Making one
/// takes about 2^bits key generations, once per node, so Sybils cost that
/// much each, and a targeted eclipse (keys near a victim *and* solving the
/// puzzle) 2^bits times more than before. Hashing again, rather than
/// requiring zeros in the node ID itself, keeps IDs spread evenly.
public enum DHTPuzzle {
    /// The difficulty nodes require of each other: about 16,000 key
    /// generations, around a second. Lowered in tests and simulations.
    nonisolated(unsafe) public static var bits = 14

    /// The first byte of a DHT initiator's first Noise message, so the
    /// responder answers with its DHT key rather than its device key.
    public static let noisePurpose: UInt8 = 0x44

    public static func isSolved(_ key: AgreementPublicKey, bits: Int = DHTPuzzle.bits) -> Bool {
        var remaining = max(0, min(bits, 256))
        for byte in SHA256.hash(data: label + key.rawRepresentation) {
            if remaining == 0 { return true }
            if remaining >= 8 {
                guard byte == 0 else { return false }
                remaining -= 8
            } else {
                return byte >> (8 - remaining) == 0
            }
        }
        return true
    }

    /// A key pair whose agreement key solves the puzzle.
    public static func grind(bits: Int = DHTPuzzle.bits) -> DeviceKeyPair {
        while true {
            let agreement = Curve25519.KeyAgreement.PrivateKey()
            guard let key = try? AgreementPublicKey(rawRepresentation: Array(agreement.publicKey.rawRepresentation)),
                  isSolved(key, bits: bits)
            else { continue }
            if let pair = try? DeviceKeyPair(signingKey: Array(Curve25519.Signing.PrivateKey().rawRepresentation),
                                             agreementKey: Array(agreement.rawRepresentation)) {
                return pair
            }
        }
    }

    private static let label = Array("circles/v1/dht-puzzle".utf8)
}
