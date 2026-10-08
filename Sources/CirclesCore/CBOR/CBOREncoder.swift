/// Encodes `Encodable` values as deterministic CBOR.
///
/// Mapping from Swift:
/// - integers → major types 0/1, `Bool` → true/false, `nil` → null
/// - `String` → text string, `[UInt8]` → byte string
/// - keyed containers → maps (an integer key if the `CodingKey` has
///   `intValue`, otherwise its string), unkeyed containers → arrays
/// - `Float`/`Double` → error: signed objects never contain floats
public struct CBOREncoder: Sendable {
    public init() {}

    public func encode<T: Encodable>(_ value: T) throws(CBORError) -> [UInt8] {
        var writer = CBORWriter()
        try writer.write(try encodeToValue(value))
        return writer.bytes
    }

    public func encodeToValue<T: Encodable>(_ value: T) throws(CBORError) -> CBORValue {
        do {
            return try box(value, codingPath: [])
        } catch let error as CBORError {
            throw error
        } catch {
            throw .custom(String(describing: error))
        }
    }
}

// MARK: - Encoder internals

/// A slot in the tree being built. Containers write into nodes lazily, so a
/// nested container can be filled in after its parent has been created.
private final class Node {
    enum Content {
        case empty
        case value(CBORValue)
        case map([(key: CBORValue, node: Node)])
        case array([Node])
    }

    var content: Content = .empty

    func resolve() -> CBORValue {
        switch content {
        // A type whose encode(to:) wrote nothing becomes an empty map,
        // matching JSONEncoder.
        case .empty: .map([])
        case .value(let value): value
        case .map(let entries): .map(entries.map { CBORMapEntry(key: $0.key, value: $0.node.resolve()) })
        case .array(let nodes): .array(nodes.map { $0.resolve() })
        }
    }
}

private func box<T: Encodable>(_ value: T, codingPath: [any CodingKey]) throws -> CBORValue {
    // Match the static type exactly: a dynamic `as? [UInt8]` cast also
    // succeeds for an empty [Int], and with Foundation bridging can convert
    // other integer arrays.
    if T.self == [UInt8].self {
        return .bytes(value as! [UInt8])
    }
    let encoder = _CBOREncoder(node: Node(), codingPath: codingPath)
    try value.encode(to: encoder)
    return encoder.node.resolve()
}

private func keyValue(_ key: some CodingKey) -> CBORValue {
    if let int = key.intValue { CBORValue(Int64(int)) } else { .text(key.stringValue) }
}

private func floatError(_ codingPath: [any CodingKey]) -> CBORError {
    .floatingPointNotAllowed(path: pathDescription(codingPath))
}

private struct _CBOREncoder: Encoder {
    let node: Node
    let codingPath: [any CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    init(node: Node, codingPath: [any CodingKey]) {
        self.node = node
        self.codingPath = codingPath
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        if case .map = node.content {} else { node.content = .map([]) }
        return KeyedEncodingContainer(KeyedContainer<Key>(node: node, codingPath: codingPath))
    }

    func unkeyedContainer() -> any UnkeyedEncodingContainer {
        if case .array = node.content {} else { node.content = .array([]) }
        return UnkeyedContainer(node: node, codingPath: codingPath)
    }

    func singleValueContainer() -> any SingleValueEncodingContainer {
        SingleValueContainer(node: node, codingPath: codingPath)
    }
}

private struct KeyedContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let node: Node
    let codingPath: [any CodingKey]

    private func set(_ value: CBORValue, for key: Key) {
        insert(Node(value), for: key)
    }

    private func insert(_ child: Node, for key: Key) {
        guard case .map(var entries) = node.content else { return }
        let k = keyValue(key)
        entries.removeAll { $0.key == k }
        entries.append((k, child))
        node.content = .map(entries)
    }

    mutating func encodeNil(forKey key: Key) throws { set(.null, for: key) }
    mutating func encode(_ value: Bool, forKey key: Key) throws { set(.bool(value), for: key) }
    mutating func encode(_ value: String, forKey key: Key) throws { set(.text(value), for: key) }
    mutating func encode(_ value: Double, forKey key: Key) throws { throw floatError(codingPath + [key]) }
    mutating func encode(_ value: Float, forKey key: Key) throws { throw floatError(codingPath + [key]) }
    mutating func encode(_ value: Int, forKey key: Key) throws { set(CBORValue(Int64(value)), for: key) }
    mutating func encode(_ value: Int8, forKey key: Key) throws { set(CBORValue(Int64(value)), for: key) }
    mutating func encode(_ value: Int16, forKey key: Key) throws { set(CBORValue(Int64(value)), for: key) }
    mutating func encode(_ value: Int32, forKey key: Key) throws { set(CBORValue(Int64(value)), for: key) }
    mutating func encode(_ value: Int64, forKey key: Key) throws { set(CBORValue(value), for: key) }
    mutating func encode(_ value: UInt, forKey key: Key) throws { set(.unsigned(UInt64(value)), for: key) }
    mutating func encode(_ value: UInt8, forKey key: Key) throws { set(.unsigned(UInt64(value)), for: key) }
    mutating func encode(_ value: UInt16, forKey key: Key) throws { set(.unsigned(UInt64(value)), for: key) }
    mutating func encode(_ value: UInt32, forKey key: Key) throws { set(.unsigned(UInt64(value)), for: key) }
    mutating func encode(_ value: UInt64, forKey key: Key) throws { set(.unsigned(value), for: key) }

    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        set(try box(value, codingPath: codingPath + [key]), for: key)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type, forKey key: Key
    ) -> KeyedEncodingContainer<NestedKey> {
        let child = Node()
        child.content = .map([])
        insert(child, for: key)
        return KeyedEncodingContainer(KeyedContainer<NestedKey>(node: child, codingPath: codingPath + [key]))
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
        let child = Node()
        child.content = .array([])
        insert(child, for: key)
        return UnkeyedContainer(node: child, codingPath: codingPath + [key])
    }

    mutating func superEncoder() -> any Encoder {
        superEncoder(forKey: Key(stringValue: "super")!)
    }

    mutating func superEncoder(forKey key: Key) -> any Encoder {
        let child = Node()
        insert(child, for: key)
        return _CBOREncoder(node: child, codingPath: codingPath + [key])
    }
}

private struct IndexKey: CodingKey {
    let intValue: Int?
    var stringValue: String { String(intValue!) }
    init(_ index: Int) { intValue = index }
    init?(stringValue: String) { nil }
    init?(intValue: Int) { self.intValue = intValue }
}

private struct UnkeyedContainer: UnkeyedEncodingContainer {
    let node: Node
    let codingPath: [any CodingKey]

    var count: Int {
        if case .array(let nodes) = node.content { nodes.count } else { 0 }
    }

    private var nextPath: [any CodingKey] { codingPath + [IndexKey(count)] }

    private func append(_ child: Node) {
        guard case .array(var nodes) = node.content else { return }
        nodes.append(child)
        node.content = .array(nodes)
    }

    private func append(_ value: CBORValue) { append(Node(value)) }

    mutating func encodeNil() throws { append(.null) }
    mutating func encode(_ value: Bool) throws { append(.bool(value)) }
    mutating func encode(_ value: String) throws { append(.text(value)) }
    mutating func encode(_ value: Double) throws { throw floatError(nextPath) }
    mutating func encode(_ value: Float) throws { throw floatError(nextPath) }
    mutating func encode(_ value: Int) throws { append(CBORValue(Int64(value))) }
    mutating func encode(_ value: Int8) throws { append(CBORValue(Int64(value))) }
    mutating func encode(_ value: Int16) throws { append(CBORValue(Int64(value))) }
    mutating func encode(_ value: Int32) throws { append(CBORValue(Int64(value))) }
    mutating func encode(_ value: Int64) throws { append(CBORValue(value)) }
    mutating func encode(_ value: UInt) throws { append(.unsigned(UInt64(value))) }
    mutating func encode(_ value: UInt8) throws { append(.unsigned(UInt64(value))) }
    mutating func encode(_ value: UInt16) throws { append(.unsigned(UInt64(value))) }
    mutating func encode(_ value: UInt32) throws { append(.unsigned(UInt64(value))) }
    mutating func encode(_ value: UInt64) throws { append(.unsigned(value)) }

    mutating func encode<T: Encodable>(_ value: T) throws {
        append(try box(value, codingPath: nextPath))
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type
    ) -> KeyedEncodingContainer<NestedKey> {
        let path = nextPath
        let child = Node()
        child.content = .map([])
        append(child)
        return KeyedEncodingContainer(KeyedContainer<NestedKey>(node: child, codingPath: path))
    }

    mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer {
        let path = nextPath
        let child = Node()
        child.content = .array([])
        append(child)
        return UnkeyedContainer(node: child, codingPath: path)
    }

    mutating func superEncoder() -> any Encoder {
        let path = nextPath
        let child = Node()
        append(child)
        return _CBOREncoder(node: child, codingPath: path)
    }
}

private struct SingleValueContainer: SingleValueEncodingContainer {
    let node: Node
    let codingPath: [any CodingKey]

    private func set(_ value: CBORValue) { node.content = .value(value) }

    mutating func encodeNil() throws { set(.null) }
    mutating func encode(_ value: Bool) throws { set(.bool(value)) }
    mutating func encode(_ value: String) throws { set(.text(value)) }
    mutating func encode(_ value: Double) throws { throw floatError(codingPath) }
    mutating func encode(_ value: Float) throws { throw floatError(codingPath) }
    mutating func encode(_ value: Int) throws { set(CBORValue(Int64(value))) }
    mutating func encode(_ value: Int8) throws { set(CBORValue(Int64(value))) }
    mutating func encode(_ value: Int16) throws { set(CBORValue(Int64(value))) }
    mutating func encode(_ value: Int32) throws { set(CBORValue(Int64(value))) }
    mutating func encode(_ value: Int64) throws { set(CBORValue(value)) }
    mutating func encode(_ value: UInt) throws { set(.unsigned(UInt64(value))) }
    mutating func encode(_ value: UInt8) throws { set(.unsigned(UInt64(value))) }
    mutating func encode(_ value: UInt16) throws { set(.unsigned(UInt64(value))) }
    mutating func encode(_ value: UInt32) throws { set(.unsigned(UInt64(value))) }
    mutating func encode(_ value: UInt64) throws { set(.unsigned(value)) }

    mutating func encode<T: Encodable>(_ value: T) throws {
        set(try box(value, codingPath: codingPath))
    }
}

extension Node {
    convenience init(_ value: CBORValue) {
        self.init()
        content = .value(value)
    }
}
