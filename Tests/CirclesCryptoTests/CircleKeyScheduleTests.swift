import Testing
import CirclesCore
@testable import CirclesCrypto

@Suite("Circle key schedule")
struct CircleKeyScheduleTests {
    static func user(_ n: UInt8) -> UserID {
        try! UserID(ed25519PublicKey: [UInt8](repeating: n, count: 32))
    }

    let bob = user(1), carol = user(2), dave = user(3)

    @Test("initially every member needs the epoch-0 key")
    func initial() {
        let schedule = CircleKeySchedule(members: [bob, carol])
        #expect(schedule.current.epoch == 0)
        #expect(schedule.initialDistribution.recipients == [bob, carol])
    }

    @Test("adding a member sends them the current key without rotating")
    func addWithoutRotation() throws {
        var schedule = CircleKeySchedule(members: [bob])
        let before = schedule.current.id
        let added = schedule.add([dave, bob])
        let distribution = try #require(added)
        #expect(distribution.recipients == [dave])
        #expect(distribution.key.id == before)
        #expect(schedule.members == [bob, dave])
        #expect(schedule.add([dave]) == nil)
    }

    @Test("with rotateOnAdd, adding a member starts a new epoch for everyone")
    func addWithRotation() throws {
        var schedule = CircleKeySchedule(members: [bob], rotateOnAdd: true)
        let before = schedule.current.id
        let added = schedule.add([dave])
        let distribution = try #require(added)
        #expect(distribution.key.epoch == 1)
        #expect(distribution.key.id != before)
        #expect(distribution.recipients == [bob, dave])
    }

    @Test("removing a member rotates and leaves them out")
    func remove() throws {
        var schedule = CircleKeySchedule(members: [bob, carol, dave])
        let before = schedule.current.id
        let removed = schedule.remove([carol])
        let distribution = try #require(removed)
        #expect(distribution.key.epoch == 1)
        #expect(distribution.key.id != before)
        #expect(distribution.recipients == [bob, dave])
        #expect(schedule.remove([carol]) == nil)
    }

    @Test("every epoch gets a fresh, unlinkable key ID")
    func uniqueIDs() {
        var schedule = CircleKeySchedule()
        var ids: Set<AudienceKeyID> = [schedule.current.id]
        for epoch in 1...100 {
            #expect(schedule.rotate().key.epoch == UInt64(epoch))
            ids.insert(schedule.current.id)
        }
        #expect(ids.count == 101)
    }
}

extension CircleKeySchedule.Distribution: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.key.id == rhs.key.id && lhs.recipients == rhs.recipients
    }
}
