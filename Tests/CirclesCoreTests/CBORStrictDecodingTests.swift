import Testing
@testable import CirclesCore

/// Valid CBOR that isn't in core deterministic form must be rejected, so
/// every decodable message has exactly one byte representation.
@Suite("CBOR strict decoding")
struct CBORStrictDecodingTests {
    let decoder = CBORDecoder()

    func parseError(_ hexInput: String) -> CBORError? {
        do {
            _ = try decoder.parse(bytes(hexInput))
            return nil
        } catch {
            return error
        }
    }

    @Test("overlong integer and length arguments", arguments: [
        "1800", "1817", "190000", "1900ff", "1a0000ffff", "1b00000000ffffffff",
        "5800", "7801 61",
    ])
    func overlongArguments(input: String) {
        #expect(parseError(input.replacing(" ", with: "")) == .nonCanonicalLength(offset: 0))
    }

    @Test("indefinite-length items", arguments: ["5f41ff", "7f6161ff", "9f01ff", "bf616101ff", "ff"])
    func indefiniteLength(input: String) {
        #expect(parseError(input) == .indefiniteLengthNotAllowed(offset: 0))
    }

    @Test("floats", arguments: ["f93c00", "fa47c35000", "fb3ff199999999999a"])
    func floats(input: String) {
        guard case .floatingPointNotAllowed = parseError(input) else {
            Issue.record("expected floatingPointNotAllowed")
            return
        }
    }

    @Test("unsorted map keys")
    func unsortedKeys() {
        // {"b": 1, "a": 2}
        #expect(parseError("a2616201616102") == .unsortedOrDuplicateMapKey(offset: 4))
        // {"aa": 1, "b": 2}: alphabetical, but not bytewise-by-encoding
        #expect(parseError("a262616101616202") == .unsortedOrDuplicateMapKey(offset: 5))
    }

    @Test("duplicate map keys")
    func duplicateKeys() {
        #expect(parseError("a2616101616102") == .unsortedOrDuplicateMapKey(offset: 4))
    }

    @Test("tags, undefined and other simple values")
    func unsupportedItems() {
        #expect(parseError("c11a514b67b0") == .unsupportedTag(offset: 0))
        #expect(parseError("f7") == .unsupportedSimpleValue(offset: 0))
        #expect(parseError("f0") == .unsupportedSimpleValue(offset: 0))
        #expect(parseError("f818") == .unsupportedSimpleValue(offset: 0))
    }

    @Test("reserved additional info", arguments: ["1c", "1d", "1e"])
    func reservedInfo(input: String) {
        #expect(parseError(input) == .reservedAdditionalInfo(offset: 0))
    }

    @Test("malformed input")
    func malformed() {
        #expect(parseError("") == .truncated(offset: 0))
        #expect(parseError("19 01".replacing(" ", with: "")) == .truncated(offset: 0))
        #expect(parseError("0101") == .trailingBytes(offset: 1))
        #expect(parseError("62c3") == .lengthExceedsInput(offset: 0))
        #expect(parseError("62c328") == .invalidUTF8(offset: 0))
        // An array claiming 2^32 elements must fail before allocating.
        #expect(parseError("9affffffff00") == .lengthExceedsInput(offset: 0))
        #expect(parseError("bb000000010000000000") == .lengthExceedsInput(offset: 0))
    }

    @Test("nesting deeper than the limit")
    func depthLimit() {
        let deep = String(repeating: "81", count: 65) + "00"
        #expect(parseError(deep) == .depthLimitExceeded(offset: 65))
        let ok = String(repeating: "81", count: 64) + "00"
        #expect(parseError(ok) == nil)
    }

    @Test("integers that don't fit the target type")
    func outOfRange() {
        #expect(throws: CBORError.valueOutOfRange(path: "")) {
            try decoder.decode(UInt8.self, from: bytes("190100"))
        }
        #expect(throws: CBORError.valueOutOfRange(path: "")) {
            try decoder.decode(UInt64.self, from: bytes("20"))
        }
        #expect(throws: CBORError.valueOutOfRange(path: "")) {
            try decoder.decode(Int64.self, from: bytes("3b8000000000000000"))
        }
    }

    @Test("unknown map keys are ignored for forward compatibility")
    func unknownKeys() throws {
        struct V1: Codable, Equatable { var a: Int }
        // {"a": 1, "z": 2}
        #expect(try decoder.decode(V1.self, from: bytes("a2616101617a02")) == V1(a: 1))
    }
}
