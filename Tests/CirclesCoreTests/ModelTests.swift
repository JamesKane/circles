import Testing
@testable import CirclesCore

@Suite("Model")
struct ModelTests {
    static let alice = try! UserID(ed25519PublicKey: [UInt8](repeating: 0xA1, count: 32))
    static let bob = try! UserID(ed25519PublicKey: [UInt8](repeating: 0xB0, count: 32))

    static let post = Post(
        author: alice,
        created: HLCTimestamp(millis: 1_791_158_400_000, counter: 0),
        body: RichText([
            .text("Hello "),
            .mention(bob, displayName: "Bob"),
            .text(" — welcome to "),
            .hashtag("circles"),
            .link(url: "https://example.com", label: "the docs"),
        ]),
        attachments: [
            BlobRef(chunks: [ContentID(hashing: Array("chunk".utf8))], key: [UInt8](repeating: 7, count: 32),
                    digest: ContentID(hashing: Array("photo".utf8)), byteCount: 123_456,
                    mediaType: "image/jpeg", width: 1024, height: 768),
        ],
        collection: try! CollectionID(bytes: [UInt8](0..<16)),
        replyPolicy: ReplyPolicy(commentsEnabled: true, resharesEnabled: false)
    )

    @Test("posts, comments and reactions round-trip")
    func roundTrip() throws {
        let encoder = CBOREncoder()
        let decoder = CBORDecoder()
        #expect(try decoder.decode(Post.self, from: encoder.encode(Self.post)) == Self.post)

        let postRef = ObjectRef(author: Self.alice, id: try ContentID(of: Self.post))
        let comment = Comment(author: Self.bob, parent: postRef,
                              created: HLCTimestamp(millis: 1_791_158_460_000, counter: 1),
                              body: RichText(plain: "Thanks!"))
        #expect(try decoder.decode(Comment.self, from: encoder.encode(comment)) == comment)

        let reaction = Reaction(author: Self.bob, target: postRef, kind: .plusOne,
                                created: HLCTimestamp(millis: 1_791_158_470_000))
        #expect(try decoder.decode(Reaction.self, from: encoder.encode(reaction)) == reaction)
    }

    @Test("the same post always has the same ContentID")
    func stableContentID() throws {
        #expect(try ContentID(of: Self.post) == ContentID(of: Self.post))
        var edited = Self.post
        edited.body = RichText(plain: "edited")
        #expect(try ContentID(of: edited) != ContentID(of: Self.post))
    }

    @Test("rich text runs encode as [kind, fields…] and reject unknown kinds")
    func richTextWireFormat() throws {
        let text = RichText([.text("hi"), .hashtag("x")])
        #expect(hex(try CBOREncoder().encode(text)) == "82" + "82006268 69".replacing(" ", with: "") + "82046178")
        #expect(throws: CBORError.custom("unknown rich text run kind 99")) {
            try CBORDecoder().decode(RichText.self, from: bytes("81821863626869"))
        }
        #expect(throws: CBORError.self) {
            try CBORDecoder().decode(RichText.self, from: bytes("818300626869f5")) // extra field
        }
        #expect(Self.post.body.plainText == "Hello @Bob — welcome to #circlesthe docs")
    }

    /// Guards the wire format: if this changes, every existing signature and
    /// ContentID breaks. Update the expected value only for an intentional,
    /// versioned format change.
    @Test("post wire format is stable")
    func goldenPostID() throws {
        let encoded = hex(try CBOREncoder().encode(Self.post))
        let id = try ContentID(of: Self.post).description
        #expect(encoded == [
            "a664626f64798582006648656c6c6f2083035822ed01b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0",
            "b0b0b0b0b0b063426f6282007020e280942077656c636f6d6520746f20820467636972636c657383057368747470733a",
            "2f2f6578616d706c652e636f6d6874686520646f637366617574686f725822ed01a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1",
            "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a16763726561746564821b000001a1095c3400006a636f6c6c656374696f6e50",
            "000102030405060708090a0b0c0d0e0f6b6174746163686d656e747381a7636b65795820070707070707070707070707",
            "0707070707070707070707070707070707070707657769647468190400666368756e6b7381582212206c87f68371b289",
            "54707ebb92afee7ccffb74c6f71ec8fea8a98cf6104289585b666469676573745822122055c64d0fcd6f9d5f7c828093",
            "857e3fdfda68478bb4e9bd24d481ef391c7804e8666865696768741903006962797465436f756e741a0001e240696d65",
            "646961547970656a696d6167652f6a7065676b7265706c79506f6c696379a26f636f6d6d656e7473456e61626c6564f5",
            "6f7265736861726573456e61626c6564f4",
        ].joined())
        #expect(id == "bciqk5tfyavpywe33sw3jwjh3u3muwrkppuvdznfgxkfcwwgetyroxaq")
    }
}
