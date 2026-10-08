import Testing
@testable import CirclesCore

@Suite("Hybrid logical clock")
struct HybridLogicalClockTests {
    @Test("local events follow wall time when it advances")
    func followsWallTime() {
        var clock = HybridLogicalClock()
        #expect(clock.now(physicalMillis: 1000) == HLCTimestamp(millis: 1000, counter: 0))
        #expect(clock.now(physicalMillis: 1005) == HLCTimestamp(millis: 1005, counter: 0))
    }

    @Test("timestamps stay strictly increasing when wall time stalls or goes backwards")
    func monotonic() {
        var clock = HybridLogicalClock()
        let a = clock.now(physicalMillis: 1000)
        let b = clock.now(physicalMillis: 1000)
        let c = clock.now(physicalMillis: 900)
        #expect(a < b && b < c)
        #expect(c == HLCTimestamp(millis: 1000, counter: 2))
    }

    @Test("receiving a timestamp from the future moves the clock past it")
    func receiveAhead() throws {
        var clock = HybridLogicalClock()
        _ = clock.now(physicalMillis: 1000)
        let remote = HLCTimestamp(millis: 5000, counter: 7)
        let merged = try clock.receive(remote, physicalMillis: 1000)
        #expect(merged == HLCTimestamp(millis: 5000, counter: 8))
        #expect(clock.now(physicalMillis: 1001) > merged)
    }

    @Test("receiving at the same millisecond takes the larger counter")
    func receiveSameMillisecond() throws {
        var clock = HybridLogicalClock(last: HLCTimestamp(millis: 2000, counter: 3))
        #expect(try clock.receive(HLCTimestamp(millis: 2000, counter: 9), physicalMillis: 1500)
            == HLCTimestamp(millis: 2000, counter: 10))
        #expect(try clock.receive(HLCTimestamp(millis: 2000, counter: 1), physicalMillis: 1500)
            == HLCTimestamp(millis: 2000, counter: 11))
    }

    @Test("receiving an old timestamp when wall time is ahead starts a fresh millisecond")
    func receiveBehind() throws {
        var clock = HybridLogicalClock(last: HLCTimestamp(millis: 1000, counter: 5))
        #expect(try clock.receive(HLCTimestamp(millis: 900, counter: 50), physicalMillis: 3000)
            == HLCTimestamp(millis: 3000, counter: 0))
    }

    @Test("timestamps too far ahead of wall time are rejected")
    func driftRejected() {
        var clock = HybridLogicalClock(maxDriftMillis: 60_000)
        let remote = HLCTimestamp(millis: 1000 + 60_001)
        #expect(throws: ClockError.driftExceeded(remote: remote, physicalMillis: 1000)) {
            try clock.receive(remote, physicalMillis: 1000)
        }
        #expect(clock.last == HLCTimestamp(millis: 0))
    }

    @Test("counter overflow borrows a millisecond instead of wrapping")
    func counterOverflow() {
        var clock = HybridLogicalClock(last: HLCTimestamp(millis: 10, counter: .max))
        #expect(clock.now(physicalMillis: 10) == HLCTimestamp(millis: 11, counter: 0))
    }

    @Test("timestamps encode as [millis, counter]")
    func wireFormat() throws {
        let ts = HLCTimestamp(millis: 1000, counter: 2)
        #expect(hex(try CBOREncoder().encode(ts)) == "821903e802")
        #expect(try CBORDecoder().decode(HLCTimestamp.self, from: bytes("821903e802")) == ts)
        #expect(throws: CBORError.self) {
            try CBORDecoder().decode(HLCTimestamp.self, from: bytes("831903e80200"))
        }
    }
}
