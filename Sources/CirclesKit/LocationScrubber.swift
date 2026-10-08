/// Removes location metadata from media before it's posted. Photos often
/// carry GPS coordinates, and an attachment goes to everyone in the post's
/// audience, so a photo would otherwise reveal where it was taken.
///
/// Pure Swift, so it behaves the same on every platform. The format is
/// detected from the bytes, not the declared media type:
/// - JPEG: the EXIF GPS directory is zeroed and unlinked in place (the image
///   data is untouched), and XMP packets that mention GPS are dropped.
/// - PNG: the same for the `eXIf` chunk (CRC recomputed); XMP and legacy
///   "Raw profile" EXIF text chunks are dropped.
/// - WebP: the same for the `EXIF` chunk; an XMP chunk mentioning GPS is
///   dropped.
/// - TIFF: the GPS directory is zeroed and unlinked in place.
/// - GIF and data that isn't a recognized image pass through unchanged.
/// - ISO media files (HEIC, AVIF, MP4, MOV) can carry location too, but
///   aren't handled yet, so they're refused rather than posted as they are.
public enum LocationScrubber {
    public enum Failure: Error, Sendable, Equatable, CustomStringConvertible {
        /// A format whose location data can't be removed yet.
        case unsupportedFormat(String)
        /// The file claims a format but its structure doesn't parse.
        case malformed(String)

        public var description: String {
            switch self {
            case .unsupportedFormat(let format):
                "Circles can't remove location data from \(format) files yet, so they can't be attached. Convert it to JPEG first."
            case .malformed(let format):
                "This \(format) file looks damaged, so Circles can't check it for location data."
            }
        }
    }

    public static func scrub(_ data: [UInt8]) throws -> [UInt8] {
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return try scrubJPEG(data) }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return try scrubPNG(data) }
        if data.count >= 12, data.starts(with: Array("RIFF".utf8)), Array(data[8..<12]) == Array("WEBP".utf8) {
            return try scrubWebP(data)
        }
        if data.starts(with: [0x49, 0x49, 0x2A, 0x00]) || data.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) {
            var copy = data
            guard removeGPS(fromTIFF: &copy, at: 0, length: copy.count) else { throw Failure.malformed("TIFF") }
            return copy
        }
        if data.count >= 12, Array(data[4..<8]) == Array("ftyp".utf8) {
            throw Failure.unsupportedFormat(isoMediaName(brand: Array(data[8..<12])))
        }
        return data
    }

    // MARK: TIFF / EXIF

    /// Zeroes the GPS directory of the TIFF structure at `start` and removes
    /// IFD0's pointer to it. Everything stays at the same offset, so other
    /// directories and the rest of the file remain valid. Returns false if
    /// the structure doesn't parse.
    static func removeGPS(fromTIFF bytes: inout [UInt8], at start: Int, length: Int) -> Bool {
        let end = start + length
        guard length >= 8, end <= bytes.count else { return false }
        let little: Bool
        switch (bytes[start], bytes[start + 1]) {
        case (0x49, 0x49): little = true
        case (0x4D, 0x4D): little = false
        default: return false
        }
        func u16(_ at: Int) -> Int? {
            guard at >= start, at + 2 <= end else { return nil }
            return little ? Int(bytes[at]) | Int(bytes[at + 1]) << 8 : Int(bytes[at]) << 8 | Int(bytes[at + 1])
        }
        func u32(_ at: Int) -> Int? {
            guard at >= start, at + 4 <= end else { return nil }
            let b = (0..<4).map { Int(bytes[at + $0]) }
            return little ? b[0] | b[1] << 8 | b[2] << 16 | b[3] << 24 : b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3]
        }
        func zero(_ at: Int, _ count: Int) {
            let lower = max(at, start), upper = min(at + count, end)
            if lower < upper { for i in lower..<upper { bytes[i] = 0 } }
        }

        guard u16(start + 2) == 42, let ifd0Offset = u32(start + 4) else { return false }
        let ifd0 = start + ifd0Offset
        guard let entryCount = u16(ifd0), ifd0 + 2 + entryCount * 12 + 4 <= end else { return false }

        for index in 0..<entryCount {
            let entry = ifd0 + 2 + index * 12
            guard u16(entry) == 0x8825 else { continue } // GPSInfo
            if let gpsOffset = u32(entry + 8), let gpsCount = u16(start + gpsOffset) {
                let gps = start + gpsOffset
                for gpsIndex in 0..<gpsCount {
                    let gpsEntry = gps + 2 + gpsIndex * 12
                    guard let type = u16(gpsEntry + 2), let count = u32(gpsEntry + 4) else { break }
                    let size = tiffTypeSize(type) * count
                    if size > 4, let valueOffset = u32(gpsEntry + 8) { zero(start + valueOffset, size) }
                }
                zero(gps, 2 + gpsCount * 12 + 4)
            }
            // Remove the pointer entry, keeping the rest sorted and in place.
            let last = ifd0 + 2 + (entryCount - 1) * 12
            if entry < last {
                bytes.replaceSubrange(entry..<last, with: Array(bytes[(entry + 12)...(last + 11)]))
            }
            zero(last, 12)
            let newCount = entryCount - 1
            bytes[ifd0] = UInt8(little ? newCount & 0xFF : newCount >> 8)
            bytes[ifd0 + 1] = UInt8(little ? newCount >> 8 : newCount & 0xFF)
            // The next-IFD pointer followed the old last entry; move it up.
            let nextPointer = Array(bytes[(last + 12)..<(last + 16)])
            zero(last + 12, 4)
            bytes.replaceSubrange(last..<(last + 4), with: nextPointer)
            return true
        }
        return true
    }

    static func tiffTypeSize(_ type: Int) -> Int {
        switch type {
        case 1, 2, 6, 7: 1 // BYTE, ASCII, SBYTE, UNDEFINED
        case 3, 8: 2 // SHORT, SSHORT
        case 4, 9, 11, 13: 4 // LONG, SLONG, FLOAT, IFD
        case 5, 10, 12: 8 // RATIONAL, SRATIONAL, DOUBLE
        default: 0
        }
    }

    // MARK: JPEG

    static let exifHeader = Array("Exif\0\0".utf8)
    static let xmpHeader = Array("http://ns.adobe.com/xap/1.0/\0".utf8)
    static let extendedXMPHeader = Array("http://ns.adobe.com/xmp/extension/\0".utf8)

    static func scrubJPEG(_ data: [UInt8]) throws -> [UInt8] {
        var output: [UInt8] = [0xFF, 0xD8]
        var index = 2
        while index < data.count {
            guard data[index] == 0xFF else { throw Failure.malformed("JPEG") }
            var markerIndex = index + 1
            while markerIndex < data.count, data[markerIndex] == 0xFF { markerIndex += 1 } // fill bytes
            guard markerIndex < data.count else { throw Failure.malformed("JPEG") }
            let marker = data[markerIndex]
            if marker == 0xD9 || (0xD0...0xD7).contains(marker) || marker == 0x01 { // no length
                output += [0xFF, marker]
                index = markerIndex + 1
                if marker == 0xD9 { output += data[index...]; return output }
                continue
            }
            guard markerIndex + 2 < data.count else { throw Failure.malformed("JPEG") }
            let length = Int(data[markerIndex + 1]) << 8 | Int(data[markerIndex + 2])
            let segmentEnd = markerIndex + 1 + length
            guard length >= 2, segmentEnd <= data.count else { throw Failure.malformed("JPEG") }
            var segment = Array(data[(markerIndex - 1)..<segmentEnd]) // FF, marker, length, payload
            let payload = 4 // offset of the payload within `segment`
            if marker == 0xE1 {
                let body = segment[payload...]
                if body.starts(with: exifHeader) {
                    let tiff = payload + exifHeader.count
                    guard removeGPS(fromTIFF: &segment, at: tiff, length: segment.count - tiff) else {
                        throw Failure.malformed("JPEG")
                    }
                } else if body.starts(with: extendedXMPHeader) {
                    index = segmentEnd
                    continue // an extended XMP piece may hold GPS split across pieces: drop them all
                } else if body.starts(with: xmpHeader), contains(Array(body), "GPS") {
                    index = segmentEnd
                    continue
                }
            }
            output += segment
            index = segmentEnd
            if marker == 0xDA { // start of scan: the rest is image data
                output += data[index...]
                return output
            }
        }
        throw Failure.malformed("JPEG")
    }

    // MARK: PNG

    static func scrubPNG(_ data: [UInt8]) throws -> [UInt8] {
        var output = Array(data[0..<8])
        var index = 8
        while index + 12 <= data.count {
            let length = Int(data[index]) << 24 | Int(data[index + 1]) << 16 | Int(data[index + 2]) << 8 | Int(data[index + 3])
            let chunkEnd = index + 12 + length
            guard length >= 0, chunkEnd <= data.count else { throw Failure.malformed("PNG") }
            let type = String(decoding: data[(index + 4)..<(index + 8)], as: UTF8.self)
            let body = Array(data[(index + 8)..<(index + 8 + length)])
            switch type {
            case "eXIf":
                var exif = body
                guard removeGPS(fromTIFF: &exif, at: 0, length: exif.count) else { throw Failure.malformed("PNG") }
                output += Array(data[index..<(index + 8)]) + exif + bigEndian(crc32(Array(data[(index + 4)..<(index + 8)]) + exif))
            case "iTXt", "tEXt", "zTXt":
                // Text chunks start with a keyword. XMP and ImageMagick's
                // hex-encoded EXIF profiles may hold GPS (possibly
                // compressed), so they go; other text stays.
                let keyword = String(decoding: body.prefix { $0 != 0 }, as: UTF8.self)
                if keyword == "XML:com.adobe.xmp" || keyword.hasPrefix("Raw profile type") { break }
                output += data[index..<chunkEnd]
            default:
                output += data[index..<chunkEnd]
            }
            index = chunkEnd
            if type == "IEND" { return output + data[index...] }
        }
        throw Failure.malformed("PNG")
    }

    // MARK: WebP

    static func scrubWebP(_ data: [UInt8]) throws -> [UInt8] {
        var chunks: [UInt8] = []
        var droppedXMP = false
        var index = 12
        while index + 8 <= data.count {
            let fourCC = String(decoding: data[index..<(index + 4)], as: UTF8.self)
            let size = Int(data[index + 4]) | Int(data[index + 5]) << 8 | Int(data[index + 6]) << 16 | Int(data[index + 7]) << 24
            let padded = size + (size & 1)
            guard index + 8 + size <= data.count else { throw Failure.malformed("WebP") }
            var chunk = Array(data[index..<min(index + 8 + padded, data.count)])
            switch fourCC {
            case "EXIF":
                // Some writers keep JPEG's "Exif\0\0" prefix inside the chunk.
                let tiff = Array(chunk[8...]).starts(with: exifHeader) ? 8 + exifHeader.count : 8
                guard removeGPS(fromTIFF: &chunk, at: tiff, length: 8 + size - tiff) else { throw Failure.malformed("WebP") }
                chunks += chunk
            case "XMP " where contains(Array(chunk[8..<(8 + size)]), "GPS"):
                droppedXMP = true
            default:
                chunks += chunk
            }
            index += 8 + padded
        }
        if droppedXMP, chunks.count >= 9, String(decoding: chunks[0..<4], as: UTF8.self) == "VP8X" {
            chunks[8] &= ~0x04 // the "has XMP" flag
        }
        let riffSize = UInt32(4 + chunks.count)
        return Array("RIFF".utf8) + (0..<4).map { UInt8(truncatingIfNeeded: riffSize >> (8 * $0)) } + Array("WEBP".utf8) + chunks
    }

    // MARK: Helpers

    static func isoMediaName(brand: [UInt8]) -> String {
        switch String(decoding: brand, as: UTF8.self) {
        case "heic", "heix", "heim", "heis", "hevc", "hevx", "mif1", "msf1": "HEIC"
        case "avif", "avis": "AVIF"
        case "qt  ": "QuickTime"
        default: "MP4"
        }
    }

    static func contains(_ bytes: [UInt8], _ text: String) -> Bool {
        let needle = Array(text.utf8)
        guard bytes.count >= needle.count else { return false }
        return (0...(bytes.count - needle.count)).contains { start in
            bytes[start] == needle[0] && Array(bytes[start..<(start + needle.count)]) == needle
        }
    }

    static func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    static let crcTable: [UInt32] = (0..<256).map { n in
        (0..<8).reduce(UInt32(n)) { c, _ in c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    }

    /// CRC-32 as PNG uses it (ISO 3309).
    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        ~bytes.reduce(UInt32.max) { crcTable[Int(($0 ^ UInt32($1)) & 0xFF)] ^ ($0 >> 8) }
    }
}
