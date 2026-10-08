import Testing
@testable import CirclesCore

@Suite("Identifiers")
struct IdentifierTests {
    static let key = [UInt8](0..<32)

    @Test("UserID text form round-trips and uses the multicodec prefix")
    func userIDText() throws {
        let id = try UserID(ed25519PublicKey: Self.key)
        #expect(id.multicodecBytes.prefix(2) == [0xED, 0x01])
        #expect(id.description.hasPrefix("circles:b5u"))
        #expect(try UserID(parsing: id.description) == id)
    }

    @Test("UserID rejects bad input")
    func userIDInvalid() throws {
        #expect(throws: IdentifierError.invalidLength(expected: 32, actual: 31)) {
            try UserID(ed25519PublicKey: [UInt8](repeating: 0, count: 31))
        }
        // secp256k1-pub (0xe7) instead of ed25519-pub
        #expect(throws: IdentifierError.unsupportedCode(0xE7)) {
            try UserID(multicodecBytes: [0xE7, 0x01] + Self.key)
        }
        #expect(throws: IdentifierError.invalidPrefix) {
            try UserID(parsing: "did:key:z6Mk")
        }
        #expect(UserID("circles:b!!!") == nil)
    }

    @Test("ContentID is the SHA-256 multihash (FIPS 180-2 'abc' vector)")
    func contentIDHash() throws {
        let id = ContentID(hashing: Array("abc".utf8))
        #expect(hex(id.digest) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(hex(id.multihash) == "1220" + hex(id.digest))
        #expect(id.description.hasPrefix("bciq"))
        #expect(try ContentID(parsing: id.description) == id)
    }

    @Test("ContentID rejects other hashes and wrong lengths")
    func contentIDInvalid() {
        // blake3 multihash code is 0x1e
        #expect(throws: IdentifierError.unsupportedCode(0x1E)) {
            try ContentID(multihash: [0x1E, 0x20] + [UInt8](repeating: 0, count: 32))
        }
        #expect(throws: IdentifierError.invalidLength(expected: 32, actual: 31)) {
            try ContentID(multihash: [0x12, 0x20] + [UInt8](repeating: 0, count: 31))
        }
    }

    @Test("identifiers encode as CBOR byte strings and round-trip")
    func identifiersOnTheWire() throws {
        let user = try UserID(ed25519PublicKey: Self.key)
        let encoded = try CBOREncoder().encode(user)
        #expect(hex(Array(encoded.prefix(4))) == "5822ed01") // bytes(34): ed01 + key
        #expect(try CBORDecoder().decode(UserID.self, from: encoded) == user)

        let content = ContentID(hashing: [])
        #expect(try CBORDecoder().decode(ContentID.self, from: CBOREncoder().encode(content)) == content)
    }
}
