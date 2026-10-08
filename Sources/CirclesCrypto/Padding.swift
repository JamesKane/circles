/// Length hiding for envelope plaintexts with the Padmé scheme (Nikitin et
/// al., "Reducing Metadata Leakage from Encrypted Files and Communication with
/// PURBs", 2019). Padded sizes leak O(log log n) bits of the length, and the
/// overhead is at most about 12%.
///
/// Framing: `UInt32 big-endian length || payload || zero bytes`.
enum Padding {
    static func paddedLength(_ length: Int) -> Int {
        guard length > 2 else { return length }
        let e = Int.bitWidth - 1 - length.leadingZeroBitCount         // floor(log2 L)
        let s = Int.bitWidth - 1 - e.leadingZeroBitCount + 1          // floor(log2 E) + 1
        let mask = (1 << (e - s)) - 1
        return (length + mask) & ~mask
    }

    static func pad(_ payload: [UInt8]) -> [UInt8] {
        let framed = payload.count + 4
        var output: [UInt8] = []
        output.reserveCapacity(paddedLength(framed))
        let length = UInt32(payload.count)
        output.append(contentsOf: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: length >> $0) })
        output.append(contentsOf: payload)
        output.append(contentsOf: repeatElement(0, count: paddedLength(framed) - framed))
        return output
    }

    static func unpad(_ padded: [UInt8]) throws(CryptoError) -> [UInt8] {
        guard padded.count >= 4 else { throw .malformedPadding }
        let length = padded.prefix(4).reduce(0) { $0 << 8 | Int($1) }
        guard length <= padded.count - 4, padded.count == paddedLength(length + 4) else {
            throw .malformedPadding
        }
        guard padded[(4 + length)...].allSatisfy({ $0 == 0 }) else { throw .malformedPadding }
        return Array(padded[4..<(4 + length)])
    }
}
