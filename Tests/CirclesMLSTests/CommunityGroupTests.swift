import Testing
@testable import CirclesMLS

@Suite("Community groups over MLS")
struct CommunityGroupTests {
    let alice = Array("alice".utf8), bob = Array("bob".utf8), carol = Array("carol".utf8), dave = Array("dave".utf8)

    @Test("the sequencer adds members with one commit and one Welcome; members decrypt its posts")
    func lifecycle() throws {
        var sequencer = try CommunityGroup.create(identity: alice, groupID: Array("g1".utf8))
        let bobSecrets = try CommunityGroup.makeKeyPackage(identity: bob)
        let carolSecrets = try CommunityGroup.makeKeyPackage(identity: carol)
        #expect(try CommunityGroup.inspect(keyPackage: bobSecrets.keyPackage).identity == bob)

        let commit = try sequencer.add(keyPackages: [bobSecrets.keyPackage, carolSecrets.keyPackage])
        let welcome = try #require(commit.welcome)
        var bobGroup = try CommunityGroup.join(welcome: welcome, secrets: bobSecrets)
        var carolGroup = try CommunityGroup.join(welcome: welcome, secrets: carolSecrets)
        #expect(bobGroup.epoch == sequencer.epoch && carolGroup.epoch == sequencer.epoch)
        #expect(Set(sequencer.members) == [alice, bob, carol])
        #expect(Set(bobGroup.members) == [alice, bob, carol])

        let message = try sequencer.encrypt(Array("welcome, everyone".utf8))
        #expect(!CommunityGroup.isCommit(message))
        #expect(try bobGroup.decrypt(message).data == Array("welcome, everyone".utf8))
        #expect(try carolGroup.decrypt(message).data == Array("welcome, everyone".utf8))
    }

    @Test("a removed member learns it and can't read what follows")
    func removal() throws {
        var sequencer = try CommunityGroup.create(identity: alice, groupID: Array("g2".utf8))
        let bobSecrets = try CommunityGroup.makeKeyPackage(identity: bob)
        let carolSecrets = try CommunityGroup.makeKeyPackage(identity: carol)
        let welcome = try #require(try sequencer.add(keyPackages: [bobSecrets.keyPackage, carolSecrets.keyPackage]).welcome)
        var bobGroup = try CommunityGroup.join(welcome: welcome, secrets: bobSecrets)
        var carolGroup = try CommunityGroup.join(welcome: welcome, secrets: carolSecrets)

        let removal = try sequencer.remove(identities: [carol])
        #expect(CommunityGroup.isCommit(removal.message))
        #expect(try bobGroup.process(commit: removal.message) == .applied)
        #expect(try carolGroup.process(commit: removal.message) == .removed)
        #expect(Set(sequencer.members) == [alice, bob])

        let after = try sequencer.encrypt(Array("just us now".utf8))
        #expect(try bobGroup.decrypt(after).data == Array("just us now".utf8))
        #expect(throws: GroupCryptoError.self) { try carolGroup.decrypt(after) }
        #expect(throws: GroupCryptoError.notAMember) { try sequencer.remove(identities: [carol]) }
    }

    @Test("a later member sees posts from when they joined, not before")
    func historyFromJoinOnward() throws {
        var sequencer = try CommunityGroup.create(identity: alice, groupID: Array("g3".utf8))
        let bobSecrets = try CommunityGroup.makeKeyPackage(identity: bob)
        var bobGroup = try CommunityGroup.join(welcome: try #require(try sequencer.add(keyPackages: [bobSecrets.keyPackage]).welcome),
                                               secrets: bobSecrets)
        let before = try sequencer.encrypt(Array("before dave".utf8))
        #expect(try bobGroup.decrypt(before).data == Array("before dave".utf8))

        let daveSecrets = try CommunityGroup.makeKeyPackage(identity: dave)
        let addDave = try sequencer.add(keyPackages: [daveSecrets.keyPackage])
        #expect(try bobGroup.process(commit: addDave.message) == .applied)
        var daveGroup = try CommunityGroup.join(welcome: try #require(addDave.welcome), secrets: daveSecrets)

        #expect(throws: GroupCryptoError.self) { try daveGroup.decrypt(before) }
        let after = try sequencer.encrypt(Array("hi dave".utf8))
        #expect(try daveGroup.decrypt(after).data == Array("hi dave".utf8))
        #expect(try bobGroup.decrypt(after).data == Array("hi dave".utf8))
    }

    @Test("a Welcome for someone else is recognized as not ours")
    func welcomeForSomeoneElse() throws {
        var sequencer = try CommunityGroup.create(identity: alice, groupID: Array("g4".utf8))
        let bobSecrets = try CommunityGroup.makeKeyPackage(identity: bob)
        let carolSecrets = try CommunityGroup.makeKeyPackage(identity: carol)
        let welcome = try #require(try sequencer.add(keyPackages: [bobSecrets.keyPackage]).welcome)
        #expect(throws: GroupCryptoError.notForUs) { try CommunityGroup.join(welcome: welcome, secrets: carolSecrets) }
    }

    @Test("state survives sealing and reopening, and needs the right key")
    func persistence() throws {
        var sequencer = try CommunityGroup.create(identity: alice, groupID: Array("g5".utf8))
        let bobSecrets = try CommunityGroup.makeKeyPackage(identity: bob)
        let bobGroup = try CommunityGroup.join(welcome: try #require(try sequencer.add(keyPackages: [bobSecrets.keyPackage]).welcome),
                                               secrets: bobSecrets)
        let key = [UInt8](repeating: 7, count: 32)
        let sealedSequencer = try sequencer.sealed(with: key)
        let sealedBob = try bobGroup.sealed(with: key)

        var reopenedSequencer = try CommunityGroup.open(sealed: sealedSequencer, with: key)
        var reopenedBob = try CommunityGroup.open(sealed: sealedBob, with: key)
        // Both keep working: the sequencer can still sign, Bob can still decrypt.
        let message = try reopenedSequencer.encrypt(Array("after a restart".utf8))
        #expect(try reopenedBob.decrypt(message).data == Array("after a restart".utf8))
        #expect(throws: GroupCryptoError.self) { try CommunityGroup.open(sealed: sealedBob, with: [UInt8](repeating: 8, count: 32)) }
    }

    @Test("tampered KeyPackages and out-of-order commits are rejected")
    func rejection() throws {
        var secrets = try CommunityGroup.makeKeyPackage(identity: bob)
        secrets.keyPackage[secrets.keyPackage.count - 5] ^= 0xFF
        #expect(throws: GroupCryptoError.self) { try CommunityGroup.inspect(keyPackage: secrets.keyPackage) }

        var sequencer = try CommunityGroup.create(identity: alice, groupID: Array("g6".utf8))
        let bobSecrets = try CommunityGroup.makeKeyPackage(identity: bob)
        var bobGroup = try CommunityGroup.join(welcome: try #require(try sequencer.add(keyPackages: [bobSecrets.keyPackage]).welcome),
                                               secrets: bobSecrets)
        let first = try sequencer.add(keyPackages: [try CommunityGroup.makeKeyPackage(identity: carol).keyPackage])
        let second = try sequencer.add(keyPackages: [try CommunityGroup.makeKeyPackage(identity: dave).keyPackage])
        #expect(throws: GroupCryptoError.self) { try bobGroup.process(commit: second.message) } // skipped `first`
        #expect(try bobGroup.process(commit: first.message) == .applied)
        #expect(try bobGroup.process(commit: second.message) == .applied)
    }
}
