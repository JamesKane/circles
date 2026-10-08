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
            BlobRef(id: ContentID(hashing: Array("photo".utf8)), byteCount: 123_456,
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

    /// Guards the wire format: if this changes, every existing signature and
    /// ContentID breaks. Update the expected value only for an intentional,
    /// versioned format change.
    @Test("post wire format is stable")
    func goldenPostID() throws {
        let encoded = hex(try CBOREncoder().encode(Self.post))
        let id = try ContentID(of: Self.post).description
        #expect(encoded == [
            "a664626f6479a16472756e7385a16474657874a1625f306648656c6c6f20a1676d656e74696f6ea2625f305822ed01b0",
            "b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b06b646973706c61794e616d6563426f62a1",
            "6474657874a1625f307020e280942077656c636f6d6520746f20a16768617368746167a1625f3067636972636c6573a1",
            "646c696e6ba26375726c7368747470733a2f2f6578616d706c652e636f6d656c6162656c6874686520646f6373666175",
            "74686f725822ed01a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a16763726561746564",
            "821b000001a1095c3400006a636f6c6c656374696f6e50000102030405060708090a0b0c0d0e0f6b6174746163686d65",
            "6e747381a56269645822122055c64d0fcd6f9d5f7c828093857e3fdfda68478bb4e9bd24d481ef391c7804e865776964",
            "7468190400666865696768741903006962797465436f756e741a0001e240696d65646961547970656a696d6167652f6a",
            "7065676b7265706c79506f6c696379a26f636f6d6d656e7473456e61626c6564f56f7265736861726573456e61626c65",
            "64f4",
        ].joined())
        #expect(id == "bciqa4jzqzquwzq2u4y6yhtg273x43mtqvvuninsa4dcon33zfgvxpja")
    }
}
