import Testing
@testable import CirclesCore

@Suite("CBOR properties")
struct CBORPropertyTests {
    struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static func randomValue(depth: Int, using rng: inout SplitMix64) -> CBORValue {
        let leafKinds = 7
        let kind = Int.random(in: 0..<(depth > 0 ? leafKinds + 2 : leafKinds), using: &rng)
        switch kind {
        // Bias toward the boundaries where argument widths change.
        case 0: return .unsigned([0, 23, 24, 255, 256, 65535, 65536, UInt64(UInt32.max), UInt64(UInt32.max) + 1, .max,
                                  .random(in: 0 ... .max, using: &rng)].randomElement(using: &rng)!)
        case 1: return .negative(.random(in: 0 ... .max, using: &rng))
        case 2: return .bytes((0..<Int.random(in: 0...40, using: &rng)).map { _ in .random(in: 0 ... .max, using: &rng) })
        case 3: return .text(String((0..<Int.random(in: 0...20, using: &rng)).map { _ in
            ["a", "Z", "é", "水", "🙂", "\0"].randomElement(using: &rng)! }))
        case 4: return .bool(.random(using: &rng))
        case 5: return .null
        case 6: return .unsigned(.random(in: 0..<24, using: &rng))
        case 7:
            return .array((0..<Int.random(in: 0...5, using: &rng)).map { _ in randomValue(depth: depth - 1, using: &rng) })
        default:
            var entries: [CBORMapEntry] = []
            var seen: Set<CBORValue> = []
            for _ in 0..<Int.random(in: 0...5, using: &rng) {
                let key = randomValue(depth: 0, using: &rng)
                guard seen.insert(key).inserted else { continue }
                entries.append(CBORMapEntry(key: key, value: randomValue(depth: depth - 1, using: &rng)))
            }
            return .map(entries)
        }
    }

    @Test("property: random values survive write → strict parse → write unchanged")
    func roundTrip() throws {
        var rng = SplitMix64(state: 0xC0B0)
        for _ in 0..<2000 {
            let value = Self.randomValue(depth: 4, using: &rng)
            var writer = CBORWriter()
            try writer.write(value)
            let parsed = try CBORDecoder().parse(writer.bytes)
            var rewriter = CBORWriter()
            try rewriter.write(parsed)
            #expect(rewriter.bytes == writer.bytes)
        }
    }
}
