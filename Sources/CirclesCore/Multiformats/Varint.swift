/// Unsigned LEB128 varints as used by multiformats (multicodec, multihash).
public enum Varint {
    public static func encode(_ value: UInt64) -> [UInt8] {
        var value = value
        var output: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            output.append(byte)
        } while value != 0
        return output
    }

    /// Decodes a varint from the start of `bytes`, returning the value and the
    /// number of bytes consumed. Rejects non-minimal encodings and values over
    /// 63 bits, as the multiformats spec requires.
    public static func decode(_ bytes: some Collection<UInt8>) -> (value: UInt64, length: Int)? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        var length = 0
        for byte in bytes {
            length += 1
            guard length <= 9 else { return nil }
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 {
                // A final zero byte after the first means a padded encoding.
                guard byte != 0 || length == 1 else { return nil }
                return (value, length)
            }
            shift += 7
        }
        return nil
    }
}
