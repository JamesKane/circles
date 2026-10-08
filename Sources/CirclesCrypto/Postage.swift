import Crypto

/// Proof of work for unsolicited requests (docs/DESIGN.md §7.5, §12):
/// hashcash over SHA-256. Stamping `payload` with `bits` takes about
/// 2^bits hashes; checking takes one.
public enum Postage {
    /// A nonce such that SHA-256(label ‖ payload ‖ nonce) starts with
    /// `bits` zero bits.
    public static func stamp(_ payload: [UInt8], bits: Int) -> UInt64 {
        var nonce: UInt64 = 0
        while !isValid(payload, nonce: nonce, bits: bits) { nonce &+= 1 }
        return nonce
    }

    public static func isValid(_ payload: [UInt8], nonce: UInt64, bits: Int) -> Bool {
        var hasher = SHA256()
        hasher.update(data: label)
        hasher.update(data: payload)
        withUnsafeBytes(of: nonce.bigEndian) { hasher.update(bufferPointer: $0) }
        var remaining = max(0, min(bits, 256))
        for byte in hasher.finalize() {
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

    private static let label = Array("circles/v1/postage".utf8)
}
