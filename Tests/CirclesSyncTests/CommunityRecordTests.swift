import Testing
import CirclesCore
import CirclesCrypto
@testable import CirclesSync

@Suite("Community records")
struct CommunityRecordTests {
    @Test("records and content round-trip through deterministic CBOR")
    func roundTrip() throws {
        let identity = IdentityKeyPair(), device = DeviceKeyPair()
        let community = identity.userID
        let profile = CommunityProfile(community: community, version: 1, name: "Hikers", description: "Trails",
                                       visibility: .private, joinPolicy: .approval, owner: community)
        let signedProfile = try SignedObject(signing: try CBOREncoder().encode(profile), label: .communityProfile, with: identity)
        let post = Post(author: community, created: HLCTimestamp(millis: 1), body: RichText(plain: "hi"), community: community)
        let item = CommunityItem(contribution: ContentItem(kind: .post, object: try SignedObject(encoding: post, label: .post, with: device)),
                                 contributorIdentity: signedProfile)
        let records: [CommunityRecord] = [
            .profile(signedProfile),
            .open(.members(added: [community], removed: [])),
            .open(.item(item)),
            .open(.deletion(ContentID(hashing: [1]))),
            .sealed([1, 2, 3]),
            .commit([4, 5]),
            .welcome([6], keyPackages: [[7, 8], [9]]),
        ]
        for record in records {
            let body = LogBody.community(record)
            #expect(try CBORDecoder().decode(LogBody.self, from: CBOREncoder().encode(body)) == body)
        }
        #expect(try CBORDecoder().decode(Post.self, from: CBOREncoder().encode(post)).community == community)
    }
}
