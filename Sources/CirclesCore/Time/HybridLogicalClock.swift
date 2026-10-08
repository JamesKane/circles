/// A hybrid logical clock timestamp (docs/DESIGN.md §9.5): wall-clock
/// milliseconds since the Unix epoch, plus a counter that orders events within
/// the same millisecond or while the wall clock runs behind.
///
/// Encoded on the wire as a two-element array `[millis, counter]`.
public struct HLCTimestamp: Sendable, Hashable, Comparable {
    public var millis: UInt64
    public var counter: UInt32

    public init(millis: UInt64, counter: UInt32 = 0) {
        self.millis = millis
        self.counter = counter
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.millis, lhs.counter) < (rhs.millis, rhs.counter)
    }
}

extension HLCTimestamp: Codable {
    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        millis = try container.decode(UInt64.self)
        counter = try container.decode(UInt32.self)
        guard container.isAtEnd else {
            throw CBORError.typeMismatch(expected: "[millis, counter]", path: pathDescription(decoder.codingPath))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(millis)
        try container.encode(counter)
    }
}

public enum ClockError: Error, Sendable, Equatable {
    /// A remote timestamp is further ahead of local wall time than allowed.
    case driftExceeded(remote: HLCTimestamp, physicalMillis: UInt64)
}

/// The clock state. It's a value type with no wall-clock access of its own:
/// callers pass in physical time, so it is deterministic under test, and its
/// owner (an actor in practice) decides how it's shared.
public struct HybridLogicalClock: Sendable {
    public private(set) var last: HLCTimestamp
    /// How far ahead of local wall time a received timestamp may be.
    public var maxDriftMillis: UInt64

    public init(last: HLCTimestamp = HLCTimestamp(millis: 0), maxDriftMillis: UInt64 = 60_000) {
        self.last = last
        self.maxDriftMillis = maxDriftMillis
    }

    /// A timestamp for a local event, greater than every timestamp seen so far.
    public mutating func now(physicalMillis: UInt64) -> HLCTimestamp {
        if physicalMillis > last.millis {
            last = HLCTimestamp(millis: physicalMillis)
        } else {
            advanceCounter()
        }
        return last
    }

    /// Merges a timestamp from another node, returning a local timestamp
    /// greater than both it and every earlier local one.
    public mutating func receive(
        _ remote: HLCTimestamp, physicalMillis: UInt64
    ) throws(ClockError) -> HLCTimestamp {
        guard remote.millis <= physicalMillis &+ maxDriftMillis else {
            throw .driftExceeded(remote: remote, physicalMillis: physicalMillis)
        }
        let millis = max(last.millis, remote.millis, physicalMillis)
        switch (millis == last.millis, millis == remote.millis) {
        case (true, true):
            last.counter = max(last.counter, remote.counter)
        case (true, false):
            break
        case (false, true):
            last = remote
        case (false, false):
            // Wall time is ahead of both: start a fresh millisecond.
            last = HLCTimestamp(millis: millis)
            return last
        }
        advanceCounter()
        return last
    }

    private mutating func advanceCounter() {
        if last.counter == .max {
            // Borrow a millisecond rather than wrap. This only happens after
            // 2^32 events in one millisecond, or a wildly fast remote clock.
            last = HLCTimestamp(millis: last.millis + 1)
        } else {
            last.counter += 1
        }
    }
}
