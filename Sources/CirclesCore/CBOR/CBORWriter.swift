/// Serializes `CBORValue`s in core deterministic encoding (RFC 8949 §4.2.1):
/// shortest-form arguments, definite lengths, and map keys sorted by the
/// bytewise lexicographic order of their encodings.
struct CBORWriter {
    private(set) var bytes: [UInt8] = []

    mutating func write(_ value: CBORValue, path: String = "") throws(CBORError) {
        switch value {
        case .unsigned(let n):
            writeHeader(major: 0, argument: n)
        case .negative(let n):
            writeHeader(major: 1, argument: n)
        case .bytes(let b):
            writeHeader(major: 2, argument: UInt64(b.count))
            bytes.append(contentsOf: b)
        case .text(let s):
            let utf8 = Array(s.utf8)
            writeHeader(major: 3, argument: UInt64(utf8.count))
            bytes.append(contentsOf: utf8)
        case .array(let items):
            writeHeader(major: 4, argument: UInt64(items.count))
            for item in items {
                try write(item, path: path)
            }
        case .map(let entries):
            var encoded: [(key: [UInt8], value: CBORValue)] = []
            encoded.reserveCapacity(entries.count)
            for entry in entries {
                var keyWriter = CBORWriter()
                try keyWriter.write(entry.key, path: path)
                encoded.append((keyWriter.bytes, entry.value))
            }
            encoded.sort { $0.key.lexicographicallyPrecedes($1.key) }
            for (previous, next) in zip(encoded, encoded.dropFirst()) where previous.key == next.key {
                throw .duplicateMapKey(path: path)
            }
            writeHeader(major: 5, argument: UInt64(encoded.count))
            for entry in encoded {
                bytes.append(contentsOf: entry.key)
                try write(entry.value, path: path)
            }
        case .bool(let b):
            bytes.append(b ? 0xF5 : 0xF4)
        case .null:
            bytes.append(0xF6)
        }
    }

    private mutating func writeHeader(major: UInt8, argument: UInt64) {
        let m = major << 5
        switch argument {
        case 0..<24:
            bytes.append(m | UInt8(argument))
        case 24...0xFF:
            bytes.append(m | 24)
            bytes.append(UInt8(argument))
        case 0x100...0xFFFF:
            bytes.append(m | 25)
            appendBigEndian(argument, byteCount: 2)
        case 0x1_0000...0xFFFF_FFFF:
            bytes.append(m | 26)
            appendBigEndian(argument, byteCount: 4)
        default:
            bytes.append(m | 27)
            appendBigEndian(argument, byteCount: 8)
        }
    }

    private mutating func appendBigEndian(_ value: UInt64, byteCount: Int) {
        for shift in stride(from: (byteCount - 1) * 8, through: 0, by: -8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }
}
