import Testing
@testable import CirclesFuzz

/// A small deterministic generator, so failures reproduce.
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

/// libFuzzer-style mutations of valid seeds: bit flips, interesting bytes,
/// insertions, deletions, truncation, duplication and splicing.
func mutate(_ input: [UInt8], others: [[UInt8]], using rng: inout SplitMix64) -> [UInt8] {
    var bytes = input
    for _ in 0..<Int.random(in: 1...4, using: &rng) {
        let position = bytes.isEmpty ? 0 : Int.random(in: 0..<bytes.count, using: &rng)
        switch Int.random(in: 0..<8, using: &rng) {
        case 0 where !bytes.isEmpty: bytes[position] ^= 1 << UInt8.random(in: 0..<8, using: &rng)
        case 1 where !bytes.isEmpty: bytes[position] = [0x00, 0x01, 0x17, 0x18, 0x1F, 0x7F, 0x80, 0x9F, 0xBF, 0xFF].randomElement(using: &rng)!
        case 2: bytes.insert(UInt8.random(in: .min ... .max, using: &rng), at: position)
        case 3 where !bytes.isEmpty: bytes.remove(at: position)
        case 4: bytes = Array(bytes.prefix(position))
        case 5 where !bytes.isEmpty:
            let end = min(bytes.count, position + Int.random(in: 1...16, using: &rng))
            bytes.insert(contentsOf: bytes[position..<end], at: position)
        case 6:
            if let other = others.randomElement(using: &rng), !other.isEmpty {
                let start = Int.random(in: 0..<other.count, using: &rng)
                bytes.insert(contentsOf: other[start..<min(other.count, start + 32)], at: position)
            }
        default:
            bytes = (0..<Int.random(in: 0...64, using: &rng)).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
        }
    }
    return bytes
}

@Suite("Fuzz targets under seeded mutation")
struct MutationTests {
    static let iterations: [String: Int] = ["mls": 300, "sync": 200, "dht": 400, "push": 400]

    @Test("never crash, and hold their invariants", arguments: FuzzTargets.all.keys.sorted())
    func target(_ name: String) throws {
        let target = try #require(FuzzTargets.all[name])
        let seeds = try #require(try FuzzTargets.seeds()[name])
        // The seeds themselves.
        for seed in seeds { target(seed) }
        var rng = SplitMix64(state: name.utf8.reduce(0xC1C1E5) { $0 &* 31 &+ UInt64($1) })
        for _ in 0..<(Self.iterations[name] ?? 2000) {
            target(mutate(seeds.randomElement(using: &rng)!, others: seeds, using: &rng))
        }
    }
}
