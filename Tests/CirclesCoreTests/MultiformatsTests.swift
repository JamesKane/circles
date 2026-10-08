import Testing
@testable import CirclesCore

@Suite("Multiformats")
struct MultiformatsTests {
    // RFC 4648 §10, lowercased and unpadded.
    @Test("base32 matches RFC 4648 test vectors", arguments: [
        ("", ""), ("f", "my"), ("fo", "mzxq"), ("foo", "mzxw6"),
        ("foob", "mzxw6yq"), ("fooba", "mzxw6ytb"), ("foobar", "mzxw6ytboi"),
    ])
    func base32(input: String, expected: String) {
        #expect(Base32.encode(Array(input.utf8)) == expected)
        #expect(Base32.decode(expected) == Array(input.utf8))
    }

    @Test("base32 rejects invalid input", arguments: [
        "MZXW6",   // uppercase
        "mzxw6=",  // padding
        "m1",      // outside the alphabet
        "m",       // impossible length
        "mz",      // non-zero trailing bits ("my" is canonical for "f")
    ])
    func base32Invalid(input: String) {
        #expect(Base32.decode(input) == nil)
    }

    @Test("varints match the multiformats spec", arguments: [
        (UInt64(1), "01"), (127, "7f"), (128, "8001"), (255, "ff01"),
        (300, "ac02"), (16384, "808001"), (0xED, "ed01"),
    ])
    func varint(value: UInt64, expected: String) {
        #expect(hex(Varint.encode(value)) == expected)
        let decoded = Varint.decode(bytes(expected))
        #expect(decoded?.value == value)
        #expect(decoded?.length == expected.count / 2)
    }

    @Test("varint rejects non-minimal, truncated and oversized input", arguments: [
        "8000", "ff00", "80", "", "ffffffffffffffffff01",
    ])
    func varintInvalid(input: String) {
        #expect(Varint.decode(bytes(input)) == nil)
    }
}
