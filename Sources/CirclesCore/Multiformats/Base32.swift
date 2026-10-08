/// RFC 4648 base32, lowercase, unpadded: the `b` multibase encoding.
public enum Base32 {
    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567".utf8)

    private static let decodeTable: [UInt8] = {
        var table = [UInt8](repeating: 0xFF, count: 256)
        for (index, character) in alphabet.enumerated() {
            table[Int(character)] = UInt8(index)
        }
        return table
    }()

    public static func encode(_ bytes: some Collection<UInt8>) -> String {
        var output: [UInt8] = []
        output.reserveCapacity((bytes.count * 8 + 4) / 5)
        var buffer: UInt32 = 0
        var bits = 0
        for byte in bytes {
            buffer = buffer << 8 | UInt32(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                output.append(alphabet[Int(buffer >> UInt32(bits) & 0x1F)])
            }
        }
        if bits > 0 {
            output.append(alphabet[Int(buffer << UInt32(5 - bits) & 0x1F)])
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// Decodes unpadded lowercase base32. Returns nil for characters outside
    /// the alphabet, impossible lengths, or non-zero trailing bits (which
    /// would let two strings decode to the same bytes).
    public static func decode(_ string: some StringProtocol) -> [UInt8]? {
        var output: [UInt8] = []
        var buffer: UInt32 = 0
        var bits = 0
        for character in string.utf8 {
            let value = decodeTable[Int(character)]
            guard value != 0xFF else { return nil }
            buffer = (buffer << 5 | UInt32(value)) & 0xFFF
            bits += 5
            if bits >= 8 {
                bits -= 8
                output.append(UInt8(truncatingIfNeeded: buffer >> UInt32(bits)))
            }
        }
        // Valid unpadded lengths leave 0, 2, 4, 1 or 3 leftover bits; 5 or more
        // means a whole extra character that encodes nothing.
        guard bits < 5, buffer & ((1 << UInt32(bits)) - 1) == 0 else { return nil }
        return output
    }
}
