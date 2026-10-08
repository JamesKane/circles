/// Decodes `Decodable` values from strict deterministic CBOR.
///
/// Input that isn't in core deterministic form is rejected before any Swift
/// type sees it (see `CBORReader`). Map keys the target type doesn't know
/// are ignored, so newer peers can add fields. Signatures must therefore be
/// verified over the received bytes, never over a re-encoding.
public struct CBORDecoder: Sendable {
    /// Maximum nesting of arrays and maps, bounding recursion on hostile input.
    public var maxDepth: Int

    public init(maxDepth: Int = 64) {
        self.maxDepth = maxDepth
    }

    public func decode<T: Decodable>(_ type: T.Type, from bytes: [UInt8]) throws(CBORError) -> T {
        try decode(type, from: try parse(bytes))
    }

    public func decode<T: Decodable>(_ type: T.Type, from value: CBORValue) throws(CBORError) -> T {
        do {
            return try unbox(value, as: type, codingPath: [])
        } catch let error as CBORError {
            throw error
        } catch {
            throw .custom(String(describing: error))
        }
    }

    /// Parses bytes into a `CBORValue`, enforcing deterministic encoding.
    public func parse(_ bytes: [UInt8]) throws(CBORError) -> CBORValue {
        var reader = CBORReader(bytes, maxDepth: maxDepth)
        return try reader.readDocument()
    }
}

// MARK: - Decoder internals

private func unbox<T: Decodable>(_ value: CBORValue, as type: T.Type, codingPath: [any CodingKey]) throws -> T {
    if type == [UInt8].self {
        guard case .bytes(let bytes) = value else {
            throw CBORError.typeMismatch(expected: "byte string", path: pathDescription(codingPath))
        }
        return bytes as! T
    }
    return try T(from: _CBORDecoder(value: value, codingPath: codingPath))
}

private func unboxInteger<T: FixedWidthInteger>(_ value: CBORValue, codingPath: [any CodingKey]) throws -> T {
    let result: T?
    switch value {
    case .unsigned(let n):
        result = T(exactly: n)
    case .negative(let n):
        // The value is -1 - n, i.e. ~n, which only fits a signed type when
        // n <= Int64.max.
        result = n <= UInt64(Int64.max) ? T(exactly: ~Int64(n)) : nil
    default:
        throw CBORError.typeMismatch(expected: "integer", path: pathDescription(codingPath))
    }
    guard let result else { throw CBORError.valueOutOfRange(path: pathDescription(codingPath)) }
    return result
}

private func unboxBool(_ value: CBORValue, codingPath: [any CodingKey]) throws -> Bool {
    guard case .bool(let b) = value else {
        throw CBORError.typeMismatch(expected: "bool", path: pathDescription(codingPath))
    }
    return b
}

private func unboxString(_ value: CBORValue, codingPath: [any CodingKey]) throws -> String {
    guard case .text(let s) = value else {
        throw CBORError.typeMismatch(expected: "text string", path: pathDescription(codingPath))
    }
    return s
}

private func keyValue(_ key: some CodingKey) -> CBORValue {
    if let int = key.intValue { CBORValue(Int64(int)) } else { .text(key.stringValue) }
}

private struct _CBORDecoder: Decoder {
    let value: CBORValue
    let codingPath: [any CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        guard case .map(let entries) = value else {
            throw CBORError.typeMismatch(expected: "map", path: pathDescription(codingPath))
        }
        return KeyedDecodingContainer(KeyedContainer<Key>(entries: entries, codingPath: codingPath))
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        guard case .array(let items) = value else {
            throw CBORError.typeMismatch(expected: "array", path: pathDescription(codingPath))
        }
        return UnkeyedContainer(items: items, codingPath: codingPath)
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer {
        SingleValueContainer(value: value, codingPath: codingPath)
    }
}

private struct KeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let codingPath: [any CodingKey]
    private let storage: [CBORValue: CBORValue]
    let allKeys: [Key]

    init(entries: [CBORMapEntry], codingPath: [any CodingKey]) {
        self.codingPath = codingPath
        // The reader has already rejected duplicate keys.
        storage = Dictionary(entries.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        allKeys = entries.compactMap { entry in
            switch entry.key {
            case .text(let s): Key(stringValue: s)
            case .unsigned(let n): Int(exactly: n).flatMap { Key(intValue: $0) }
            case .negative(let n): n <= UInt64(Int64.max) ? Int(exactly: ~Int64(n)).flatMap { Key(intValue: $0) } : nil
            default: nil
            }
        }
    }

    func contains(_ key: Key) -> Bool { storage[keyValue(key)] != nil }

    private func value(for key: Key) throws -> CBORValue {
        guard let value = storage[keyValue(key)] else {
            throw CBORError.keyNotFound(key: key.stringValue, path: pathDescription(codingPath))
        }
        return value
    }

    func decodeNil(forKey key: Key) throws -> Bool { try value(for: key) == .null }
    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool {
        try unboxBool(value(for: key), codingPath: codingPath + [key])
    }
    func decode(_ type: String.Type, forKey key: Key) throws -> String {
        try unboxString(value(for: key), codingPath: codingPath + [key])
    }
    func decode(_ type: Double.Type, forKey key: Key) throws -> Double {
        throw CBORError.floatingPointNotAllowed(path: pathDescription(codingPath + [key]))
    }
    func decode(_ type: Float.Type, forKey key: Key) throws -> Float {
        throw CBORError.floatingPointNotAllowed(path: pathDescription(codingPath + [key]))
    }
    func decode(_ type: Int.Type, forKey key: Key) throws -> Int { try integer(key) }
    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { try integer(key) }
    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { try integer(key) }
    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { try integer(key) }
    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { try integer(key) }
    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { try integer(key) }
    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { try integer(key) }
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { try integer(key) }
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { try integer(key) }
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { try integer(key) }

    private func integer<T: FixedWidthInteger>(_ key: Key) throws -> T {
        try unboxInteger(value(for: key), codingPath: codingPath + [key])
    }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        try unbox(value(for: key), as: type, codingPath: codingPath + [key])
    }

    func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type, forKey key: Key
    ) throws -> KeyedDecodingContainer<NestedKey> {
        try _CBORDecoder(value: value(for: key), codingPath: codingPath + [key]).container(keyedBy: type)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        try _CBORDecoder(value: value(for: key), codingPath: codingPath + [key]).unkeyedContainer()
    }

    func superDecoder() throws -> any Decoder {
        try superDecoder(forKey: Key(stringValue: "super")!)
    }

    func superDecoder(forKey key: Key) throws -> any Decoder {
        _CBORDecoder(value: try value(for: key), codingPath: codingPath + [key])
    }
}

private struct IndexKey: CodingKey {
    let intValue: Int?
    var stringValue: String { String(intValue!) }
    init(_ index: Int) { intValue = index }
    init?(stringValue: String) { nil }
    init?(intValue: Int) { self.intValue = intValue }
}

private struct UnkeyedContainer: UnkeyedDecodingContainer {
    let items: [CBORValue]
    let codingPath: [any CodingKey]
    private(set) var currentIndex = 0

    init(items: [CBORValue], codingPath: [any CodingKey]) {
        self.items = items
        self.codingPath = codingPath
    }

    var count: Int? { items.count }
    var isAtEnd: Bool { currentIndex >= items.count }

    private var currentPath: [any CodingKey] { codingPath + [IndexKey(currentIndex)] }

    private mutating func next() throws -> CBORValue {
        guard !isAtEnd else { throw CBORError.unkeyedContainerAtEnd(path: pathDescription(currentPath)) }
        defer { currentIndex += 1 }
        return items[currentIndex]
    }

    mutating func decodeNil() throws -> Bool {
        guard !isAtEnd else { throw CBORError.unkeyedContainerAtEnd(path: pathDescription(currentPath)) }
        // Per the protocol, only consume the element if it is nil.
        if items[currentIndex] == .null {
            currentIndex += 1
            return true
        }
        return false
    }

    mutating func decode(_ type: Bool.Type) throws -> Bool {
        let path = currentPath
        return try unboxBool(next(), codingPath: path)
    }
    mutating func decode(_ type: String.Type) throws -> String {
        let path = currentPath
        return try unboxString(next(), codingPath: path)
    }
    mutating func decode(_ type: Double.Type) throws -> Double {
        throw CBORError.floatingPointNotAllowed(path: pathDescription(currentPath))
    }
    mutating func decode(_ type: Float.Type) throws -> Float {
        throw CBORError.floatingPointNotAllowed(path: pathDescription(currentPath))
    }
    mutating func decode(_ type: Int.Type) throws -> Int { try integer() }
    mutating func decode(_ type: Int8.Type) throws -> Int8 { try integer() }
    mutating func decode(_ type: Int16.Type) throws -> Int16 { try integer() }
    mutating func decode(_ type: Int32.Type) throws -> Int32 { try integer() }
    mutating func decode(_ type: Int64.Type) throws -> Int64 { try integer() }
    mutating func decode(_ type: UInt.Type) throws -> UInt { try integer() }
    mutating func decode(_ type: UInt8.Type) throws -> UInt8 { try integer() }
    mutating func decode(_ type: UInt16.Type) throws -> UInt16 { try integer() }
    mutating func decode(_ type: UInt32.Type) throws -> UInt32 { try integer() }
    mutating func decode(_ type: UInt64.Type) throws -> UInt64 { try integer() }

    private mutating func integer<T: FixedWidthInteger>() throws -> T {
        let path = currentPath
        return try unboxInteger(next(), codingPath: path)
    }

    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let path = currentPath
        return try unbox(next(), as: type, codingPath: path)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type
    ) throws -> KeyedDecodingContainer<NestedKey> {
        let path = currentPath
        return try _CBORDecoder(value: next(), codingPath: path).container(keyedBy: type)
    }

    mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
        let path = currentPath
        return try _CBORDecoder(value: next(), codingPath: path).unkeyedContainer()
    }

    mutating func superDecoder() throws -> any Decoder {
        let path = currentPath
        return _CBORDecoder(value: try next(), codingPath: path)
    }
}

private struct SingleValueContainer: SingleValueDecodingContainer {
    let value: CBORValue
    let codingPath: [any CodingKey]

    func decodeNil() -> Bool { value == .null }
    func decode(_ type: Bool.Type) throws -> Bool { try unboxBool(value, codingPath: codingPath) }
    func decode(_ type: String.Type) throws -> String { try unboxString(value, codingPath: codingPath) }
    func decode(_ type: Double.Type) throws -> Double {
        throw CBORError.floatingPointNotAllowed(path: pathDescription(codingPath))
    }
    func decode(_ type: Float.Type) throws -> Float {
        throw CBORError.floatingPointNotAllowed(path: pathDescription(codingPath))
    }
    func decode(_ type: Int.Type) throws -> Int { try unboxInteger(value, codingPath: codingPath) }
    func decode(_ type: Int8.Type) throws -> Int8 { try unboxInteger(value, codingPath: codingPath) }
    func decode(_ type: Int16.Type) throws -> Int16 { try unboxInteger(value, codingPath: codingPath) }
    func decode(_ type: Int32.Type) throws -> Int32 { try unboxInteger(value, codingPath: codingPath) }
    func decode(_ type: Int64.Type) throws -> Int64 { try unboxInteger(value, codingPath: codingPath) }
    func decode(_ type: UInt.Type) throws -> UInt { try unboxInteger(value, codingPath: codingPath) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try unboxInteger(value, codingPath: codingPath) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try unboxInteger(value, codingPath: codingPath) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try unboxInteger(value, codingPath: codingPath) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { try unboxInteger(value, codingPath: codingPath) }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try unbox(value, as: type, codingPath: codingPath)
    }
}
