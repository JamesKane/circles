import Testing
@testable import CirclesCore

@Suite("CBOR encoding")
struct CBOREncodingTests {
    let encoder = CBOREncoder()
    let decoder = CBORDecoder()

    // RFC 8949 Appendix A examples that fall inside our data model.
    @Test("unsigned integers match RFC 8949 Appendix A", arguments: [
        (UInt64(0), "00"), (1, "01"), (10, "0a"), (23, "17"), (24, "1818"), (25, "1819"),
        (100, "1864"), (1000, "1903e8"), (1_000_000, "1a000f4240"),
        (1_000_000_000_000, "1b000000e8d4a51000"), (UInt64.max, "1bffffffffffffffff"),
    ])
    func unsignedIntegers(value: UInt64, expected: String) throws {
        #expect(hex(try encoder.encode(value)) == expected)
        #expect(try decoder.decode(UInt64.self, from: bytes(expected)) == value)
    }

    @Test("negative integers match RFC 8949 Appendix A", arguments: [
        (Int64(-1), "20"), (-10, "29"), (-100, "3863"), (-1000, "3903e7"),
        (Int64.min, "3b7fffffffffffffff"),
    ])
    func negativeIntegers(value: Int64, expected: String) throws {
        #expect(hex(try encoder.encode(value)) == expected)
        #expect(try decoder.decode(Int64.self, from: bytes(expected)) == value)
    }

    @Test("strings match RFC 8949 Appendix A", arguments: [
        ("", "60"), ("a", "6161"), ("IETF", "6449455446"), ("\"\\", "62225c"),
        ("\u{00fc}", "62c3bc"), ("\u{6c34}", "63e6b0b4"),
    ])
    func strings(value: String, expected: String) throws {
        #expect(hex(try encoder.encode(value)) == expected)
        #expect(try decoder.decode(String.self, from: bytes(expected)) == value)
    }

    @Test("simple values and containers match RFC 8949 Appendix A")
    func simpleValuesAndContainers() throws {
        #expect(hex(try encoder.encode(false)) == "f4")
        #expect(hex(try encoder.encode(true)) == "f5")
        #expect(hex(try encoder.encode(Int?.none)) == "f6")
        #expect(hex(try encoder.encode([UInt8]([1, 2, 3, 4]))) == "4401020304")
        #expect(hex(try encoder.encode([Int]())) == "80")
        #expect(hex(try encoder.encode([1, 2, 3])) == "83010203")
        #expect(hex(try encoder.encode([[1], [2, 3]])) == "8281018202 03".replacing(" ", with: ""))
        #expect(hex(try encoder.encode(Array(1...25))) ==
            "98190102030405060708090a0b0c0d0e0f101112131415161718181819")
    }

    @Test("map keys are sorted by encoded bytes, so shorter keys come first")
    func mapKeyOrder() throws {
        struct Keys: Codable, Equatable {
            var aa = 3
            var b = 2
            var a = 1
        }
        // a (61 61) < b (61 62) < aa (62 61 61)
        #expect(hex(try encoder.encode(Keys())) == "a3616101616202626161 03".replacing(" ", with: ""))
        #expect(try decoder.decode(Keys.self, from: encoder.encode(Keys())) == Keys())
    }

    @Test("dictionary encoding doesn't depend on insertion order")
    func dictionaryDeterminism() throws {
        var forward: [String: Int] = [:]
        var backward: [String: Int] = [:]
        let keys = (0..<50).map { "key\($0)" }
        for (i, k) in keys.enumerated() { forward[k] = i }
        for (i, k) in keys.enumerated().reversed() { backward[k] = i }
        #expect(try encoder.encode(forward) == encoder.encode(backward))
    }

    @Test("integer-keyed dictionaries use integer map keys")
    func integerKeys() throws {
        // Swift's integer-keyed dictionaries use CodingKeys with an intValue.
        let value: [Int: String] = [10: "x", -1: "y", 1: "z"]
        // 01 < 0a < 20: unsigned keys sort before negative ones.
        #expect(hex(try encoder.encode(value)) == "a3 01617a 0a6178 206179".replacing(" ", with: ""))
        #expect(try decoder.decode([Int: String].self, from: encoder.encode(value)) == value)
    }

    @Test("absent optionals are omitted, so they don't change the encoding")
    func optionalOmission() throws {
        struct WithOptional: Codable { var a = 1; var b: Int? = nil }
        struct Without: Codable { var a = 1 }
        #expect(try encoder.encode(WithOptional()) == encoder.encode(Without()))
    }

    @Test("floating point is rejected")
    func floatsRejected() {
        struct HasDouble: Codable { var x = 1.5 }
        #expect(throws: CBORError.floatingPointNotAllowed(path: "x")) {
            try encoder.encode(HasDouble())
        }
    }

    @Test("integer arrays are never mistaken for byte strings")
    func integerArraysStayArrays() throws {
        #expect(hex(try encoder.encode([Int]())) == "80")
        #expect(hex(try encoder.encode([UInt16]([1, 2]))) == "820102")
        #expect(hex(try encoder.encode([UInt8]())) == "40")
    }

    @Test("an empty Encodable encodes as an empty map")
    func emptyEncodable() throws {
        struct Empty: Codable {}
        #expect(hex(try encoder.encode(Empty())) == "a0")
    }
}
