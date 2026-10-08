/// Parses CBOR, accepting only core deterministic encoding.
///
/// Anything another encoder could have written differently is rejected:
/// overlong arguments, indefinite lengths, unsorted or duplicate map keys,
/// floats, tags, and simple values other than false/true/null. This makes
/// "decodes successfully" imply "has exactly one encoding".
struct CBORReader {
    private let bytes: [UInt8]
    private var offset = 0
    private let maxDepth: Int

    init(_ bytes: [UInt8], maxDepth: Int) {
        self.bytes = bytes
        self.maxDepth = maxDepth
    }

    /// Reads exactly one top-level value and requires that it consumes all input.
    mutating func readDocument() throws(CBORError) -> CBORValue {
        let value = try readValue(depth: 0)
        guard offset == bytes.count else { throw .trailingBytes(offset: offset) }
        return value
    }

    private var remaining: Int { bytes.count - offset }

    private mutating func readValue(depth: Int) throws(CBORError) -> CBORValue {
        let start = offset
        guard depth <= maxDepth else { throw .depthLimitExceeded(offset: start) }
        guard remaining > 0 else { throw .truncated(offset: start) }

        let initial = bytes[offset]
        offset += 1
        let major = initial >> 5
        let info = initial & 0x1F

        if major == 7 {
            switch info {
            case 20: return .bool(false)
            case 21: return .bool(true)
            case 22: return .null
            case 25, 26, 27: throw .floatingPointNotAllowed(path: "offset \(start)")
            case 31: throw .indefiniteLengthNotAllowed(offset: start)
            default: throw .unsupportedSimpleValue(offset: start)
            }
        }

        let argument = try readArgument(info: info, start: start)

        switch major {
        case 0:
            return .unsigned(argument)
        case 1:
            return .negative(argument)
        case 2:
            let count = try checkedLength(argument, minimumItemSize: 1, start: start)
            let value = Array(bytes[offset..<offset + count])
            offset += count
            return .bytes(value)
        case 3:
            let count = try checkedLength(argument, minimumItemSize: 1, start: start)
            guard let string = String(validating: bytes[offset..<offset + count], as: UTF8.self) else {
                throw .invalidUTF8(offset: start)
            }
            offset += count
            return .text(string)
        case 4:
            let count = try checkedLength(argument, minimumItemSize: 1, start: start)
            var items: [CBORValue] = []
            items.reserveCapacity(count)
            for _ in 0..<count {
                items.append(try readValue(depth: depth + 1))
            }
            return .array(items)
        case 5:
            let count = try checkedLength(argument, minimumItemSize: 2, start: start)
            var entries: [CBORMapEntry] = []
            entries.reserveCapacity(count)
            var previousKey: ArraySlice<UInt8>?
            for _ in 0..<count {
                let keyStart = offset
                let key = try readValue(depth: depth + 1)
                let keyBytes = bytes[keyStart..<offset]
                // Strictly increasing also rules out duplicates.
                if let previousKey, !previousKey.lexicographicallyPrecedes(keyBytes) {
                    throw .unsortedOrDuplicateMapKey(offset: keyStart)
                }
                previousKey = keyBytes
                let value = try readValue(depth: depth + 1)
                entries.append(CBORMapEntry(key: key, value: value))
            }
            return .map(entries)
        default: // 6: tags
            throw .unsupportedTag(offset: start)
        }
    }

    private mutating func readArgument(info: UInt8, start: Int) throws(CBORError) -> UInt64 {
        let byteCount: Int
        let minimum: UInt64
        switch info {
        case 0..<24: return UInt64(info)
        case 24: (byteCount, minimum) = (1, 24)
        case 25: (byteCount, minimum) = (2, 0x100)
        case 26: (byteCount, minimum) = (4, 0x1_0000)
        case 27: (byteCount, minimum) = (8, 0x1_0000_0000)
        case 31: throw .indefiniteLengthNotAllowed(offset: start)
        default: throw .reservedAdditionalInfo(offset: start)
        }
        guard remaining >= byteCount else { throw .truncated(offset: start) }
        var value: UInt64 = 0
        for _ in 0..<byteCount {
            value = value << 8 | UInt64(bytes[offset])
            offset += 1
        }
        guard value >= minimum else { throw .nonCanonicalLength(offset: start) }
        return value
    }

    /// Rejects lengths that can't fit in the remaining input before
    /// allocating anything for them.
    private func checkedLength(_ argument: UInt64, minimumItemSize: Int, start: Int) throws(CBORError) -> Int {
        guard argument <= UInt64(remaining / minimumItemSize) else {
            throw remaining == 0 ? .truncated(offset: start) : .lengthExceedsInput(offset: start)
        }
        return Int(argument)
    }
}
