/// Hooks for fuzzing the CBOR layer directly (docs/DESIGN.md §12).
@_spi(Fuzzing)
public enum CBORFuzzing {
    /// Parses `bytes` as one deterministic CBOR document and writes it back.
    /// Nil if it doesn't parse. Strictness means anything that parses must
    /// come back byte for byte.
    public static func roundTrip(_ bytes: [UInt8], maxDepth: Int = 64) -> [UInt8]? {
        var reader = CBORReader(bytes, maxDepth: maxDepth)
        guard let value = try? reader.readDocument() else { return nil }
        var writer = CBORWriter()
        guard (try? writer.write(value)) != nil else { return nil }
        return writer.bytes
    }
}
