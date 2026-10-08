import Testing
import CirclesCore
@testable import CirclesKit

/// Builds a small TIFF/EXIF structure: IFD0 with Make, Orientation and a
/// GPS pointer, and a GPS directory with a latitude.
struct TIFFFixture {
    static let latitude: [UInt32] = [51, 1, 30, 1, 2_407, 100] // 51° 30' 24.07"
    var littleEndian = true

    func u16(_ v: Int) -> [UInt8] {
        littleEndian ? [UInt8(v & 0xFF), UInt8(v >> 8)] : [UInt8(v >> 8), UInt8(v & 0xFF)]
    }
    func u32(_ v: UInt32) -> [UInt8] {
        let b = (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) }
        return littleEndian ? b : b.reversed()
    }
    func entry(_ tag: Int, _ type: Int, _ count: UInt32, _ value: [UInt8]) -> [UInt8] {
        u16(tag) + u16(type) + u32(count) + value + [UInt8](repeating: 0, count: 4 - value.count)
    }

    var bytes: [UInt8] {
        // Layout: header (8) · IFD0 at 8 with 3 entries (2+36+4 = 42) → 50 ·
        // "TestCam\0" at 50 → 58 · GPS IFD at 58 with 2 entries (30) → 88 ·
        // latitude rationals at 88 (24) → 112.
        var b = (littleEndian ? [0x49, 0x49] : [0x4D, 0x4D]) + u16(42) + u32(8)
        b += u16(3)
        b += entry(0x010F, 2, 8, u32(50)) // Make → offset 50
        b += entry(0x0112, 3, 1, u16(6)) // Orientation = 6
        b += entry(0x8825, 4, 1, u32(58)) // GPSInfo → offset 58
        b += u32(0)
        b += Array("TestCam\0".utf8)
        b += u16(2)
        b += entry(0x0001, 2, 2, Array("N\0".utf8)) // GPSLatitudeRef
        b += entry(0x0002, 5, 3, u32(88)) // GPSLatitude → offset 88
        b += u32(0)
        b += Self.latitude.flatMap(u32)
        return b
    }

    /// IFD0's tags and inline values, read back.
    func tags(in tiff: [UInt8]) -> [Int: [UInt8]] {
        func r16(_ at: Int) -> Int {
            littleEndian ? Int(tiff[at]) | Int(tiff[at + 1]) << 8 : Int(tiff[at]) << 8 | Int(tiff[at + 1])
        }
        var result: [Int: [UInt8]] = [:]
        for i in 0..<r16(8) {
            let e = 10 + i * 12
            result[r16(e)] = Array(tiff[(e + 8)..<(e + 12)])
        }
        return result
    }

    var latitudeBytes: [UInt8] { Self.latitude.flatMap(u32) }
}

func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
    guard haystack.count >= needle.count else { return false }
    return (0...(haystack.count - needle.count)).contains { Array(haystack[$0..<($0 + needle.count)]) == needle }
}

@Suite("Location scrubbing")
struct LocationScrubberTests {
    @Test("TIFF: the GPS directory is zeroed and unlinked; other tags and offsets stay", arguments: [true, false])
    func tiff(littleEndian: Bool) throws {
        let fixture = TIFFFixture(littleEndian: littleEndian)
        let original = fixture.bytes
        #expect(fixture.tags(in: original)[0x8825] != nil)

        let scrubbed = try LocationScrubber.scrub(original)
        #expect(scrubbed.count == original.count)
        let tags = fixture.tags(in: scrubbed)
        #expect(tags[0x8825] == nil && tags.count == 2)
        #expect(tags[0x0112] == fixture.u16(6) + [0, 0])
        #expect(Array(scrubbed[50..<58]) == Array("TestCam\0".utf8))
        #expect(!contains(scrubbed, fixture.latitudeBytes))
        #expect(scrubbed[58..<112].allSatisfy { $0 == 0 })
    }

    @Test("JPEG: EXIF GPS removed, XMP mentioning GPS dropped, image data untouched")
    func jpeg() throws {
        let tiff = TIFFFixture().bytes
        func segment(_ marker: UInt8, _ payload: [UInt8]) -> [UInt8] {
            let length = payload.count + 2
            return [0xFF, marker, UInt8(length >> 8), UInt8(length & 0xFF)] + payload
        }
        let exif = segment(0xE1, Array("Exif\0\0".utf8) + tiff)
        let xmp = segment(0xE1, Array("http://ns.adobe.com/xap/1.0/\0".utf8)
                          + Array("<x:xmpmeta><rdf:Description exif:GPSLatitude=\"51,30.4N\"/></x:xmpmeta>".utf8))
        let quantization = segment(0xDB, [UInt8](repeating: 7, count: 65))
        let scan = segment(0xDA, [UInt8](repeating: 3, count: 10)) + [0x12, 0xFF, 0x00, 0x34, 0xFF, 0xD0, 0x56]
        let jpeg = [0xFF, 0xD8] + exif + xmp + quantization + scan + [0xFF, 0xD9]

        let scrubbed = try LocationScrubber.scrub(jpeg)
        #expect(!contains(scrubbed, TIFFFixture().latitudeBytes))
        #expect(!contains(scrubbed, Array("GPSLatitude".utf8)))
        #expect(contains(scrubbed, Array("TestCam".utf8)))
        #expect(scrubbed.count == jpeg.count - xmp.count)
        #expect(Array(scrubbed.suffix(quantization.count + scan.count + 2)) == quantization + scan + [0xFF, 0xD9])
    }

    @Test("JPEG: XMP without location is kept")
    func jpegPlainXMP() throws {
        let xmpPayload = Array("http://ns.adobe.com/xap/1.0/\0<x:xmpmeta><rdf:Description xmp:Rating=\"5\"/></x:xmpmeta>".utf8)
        let length = xmpPayload.count + 2
        let jpeg = [0xFF, 0xD8, 0xFF, 0xE1, UInt8(length >> 8), UInt8(length & 0xFF)] + xmpPayload
            + [0xFF, 0xDA, 0x00, 0x02, 0x11, 0x22, 0xFF, 0xD9]
        #expect(try LocationScrubber.scrub(jpeg) == jpeg)
    }

    @Test("PNG: eXIf scrubbed with a valid CRC, XMP dropped, image data untouched")
    func png() throws {
        func chunk(_ type: String, _ data: [UInt8]) -> [UInt8] {
            let typeBytes = Array(type.utf8)
            return LocationScrubber.bigEndian(UInt32(data.count)) + typeBytes + data
                + LocationScrubber.bigEndian(LocationScrubber.crc32(typeBytes + data))
        }
        #expect(LocationScrubber.crc32(Array("IEND".utf8)) == 0xAE42_6082) // the well-known IEND CRC
        let header = chunk("IHDR", [0, 0, 0, 1, 0, 0, 0, 1, 8, 2, 0, 0, 0])
        let idat = chunk("IDAT", [0x78, 0x9C, 0x63, 0x60, 0x00, 0x00, 0x00, 0x02, 0x00, 0x01])
        let comment = chunk("tEXt", Array("Comment\0hello".utf8))
        let xmp = chunk("iTXt", Array("XML:com.adobe.xmp\0\0\0\0\0<exif:GPSLatitude>51</exif:GPSLatitude>".utf8))
        let png = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + header + chunk("eXIf", TIFFFixture().bytes)
            + xmp + comment + idat + chunk("IEND", [])

        let scrubbed = try LocationScrubber.scrub(png)
        #expect(!contains(scrubbed, TIFFFixture().latitudeBytes))
        #expect(!contains(scrubbed, Array("GPSLatitude".utf8)))
        #expect(contains(scrubbed, comment) && contains(scrubbed, idat))
        // The scrubbed eXIf chunk's CRC matches its new contents.
        let exifStart = 8 + header.count
        let exifData = Array(scrubbed[(exifStart + 8)..<(exifStart + 8 + TIFFFixture().bytes.count)])
        let storedCRC = Array(scrubbed[(exifStart + 8 + exifData.count)..<(exifStart + 12 + exifData.count)])
        #expect(storedCRC == LocationScrubber.bigEndian(LocationScrubber.crc32(Array("eXIf".utf8) + exifData)))
    }

    @Test("WebP: EXIF scrubbed, XMP with GPS dropped, flags and RIFF size updated")
    func webp() throws {
        func chunk(_ fourCC: String, _ data: [UInt8]) -> [UInt8] {
            let size = UInt32(data.count)
            return Array(fourCC.utf8) + (0..<4).map { UInt8((size >> (8 * $0)) & 0xFF) } + data + (data.count % 2 == 1 ? [0] : [])
        }
        let vp8x = chunk("VP8X", [0x0C, 0, 0, 0, 0, 0, 0, 0, 0, 0]) // EXIF | XMP flags
        let image = chunk("VP8L", [0x2F, 0, 0, 0, 0x10, 0x07])
        let body = vp8x + image + chunk("EXIF", TIFFFixture().bytes) + chunk("XMP ", Array("<exif:GPSLatitude>51</exif:GPSLatitude>".utf8))
        let size = UInt32(4 + body.count)
        let webp = Array("RIFF".utf8) + (0..<4).map { UInt8((size >> (8 * $0)) & 0xFF) } + Array("WEBP".utf8) + body

        let scrubbed = try LocationScrubber.scrub(webp)
        #expect(!contains(scrubbed, TIFFFixture().latitudeBytes))
        #expect(!contains(scrubbed, Array("GPSLatitude".utf8)))
        #expect(contains(scrubbed, image))
        #expect(scrubbed[20] == 0x08) // XMP flag cleared, EXIF flag kept
        let riffSize = (4..<8).reduce(0) { $0 | Int(scrubbed[$1]) << (8 * ($1 - 4)) }
        #expect(riffSize == scrubbed.count - 8)
    }

    @Test("HEIC, AVIF and MP4 are refused; GIF and other data pass through")
    func otherFormats() throws {
        func iso(_ brand: String) -> [UInt8] { [0, 0, 0, 24] + Array("ftyp".utf8) + Array(brand.utf8) + [UInt8](repeating: 0, count: 12) }
        #expect(throws: LocationScrubber.Failure.unsupportedFormat("HEIC")) { try LocationScrubber.scrub(iso("heic")) }
        #expect(throws: LocationScrubber.Failure.unsupportedFormat("AVIF")) { try LocationScrubber.scrub(iso("avif")) }
        #expect(throws: LocationScrubber.Failure.unsupportedFormat("MP4")) { try LocationScrubber.scrub(iso("isom")) }

        let gif = Array("GIF89a".utf8) + [1, 0, 1, 0, 0, 0, 0, 0x3B]
        #expect(try LocationScrubber.scrub(gif) == gif)
        let text = Array("just some text".utf8)
        #expect(try LocationScrubber.scrub(text) == text)
    }

    @Test("a damaged JPEG is refused rather than posted unchecked")
    func malformed() {
        let truncated: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE1, 0x40, 0x00, 0x01, 0x02]
        #expect(throws: LocationScrubber.Failure.malformed("JPEG")) { try LocationScrubber.scrub(truncated) }
    }

    @Test("posting scrubs attachments: the audience receives the photo without its location")
    func postedAttachments() async throws {
        let alice = try await Account.create(home: temporaryHome(), displayName: "Alice")
        let bob = try await Account.create(home: temporaryHome(), displayName: "Bob")
        try await befriend(alice, bob)
        let tiff = TIFFFixture().bytes
        let exifLength = tiff.count + 8
        let photo = [0xFF, 0xD8, 0xFF, 0xE1, UInt8(exifLength >> 8), UInt8(exifLength & 0xFF)] + Array("Exif\0\0".utf8) + tiff
            + [0xFF, 0xDA, 0x00, 0x02, 0x11, 0x22, 0xFF, 0xD9]
        let id = try await alice.post(RichText(plain: "where was this?"), to: .everyone,
                                      attachments: [Attachment(data: photo, mediaType: "image/jpeg")])
        try await sync(bob, with: alice)
        let item = try #require(try await bob.stream().first { $0.id == id })
        let reference = try #require(item.attachments.first)
        let received = try #require(try await bob.attachmentData(reference))
        #expect(received.count == photo.count)
        #expect(!contains(received, TIFFFixture().latitudeBytes))
        #expect(contains(received, Array("TestCam".utf8)))

        let heic = [0, 0, 0, 24] + Array("ftypheic".utf8) + [UInt8](repeating: 0, count: 12)
        await #expect(throws: LocationScrubber.Failure.unsupportedFormat("HEIC")) {
            try await alice.post(RichText(plain: "nope"), to: .everyone, attachments: [Attachment(data: heic, mediaType: "image/heic")])
        }
    }
}

#if canImport(ImageIO)
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@Suite("Location scrubbing with ImageIO")
struct LocationScrubberImageIOTests {
    /// A real image as ImageIO writes it, with GPS, orientation and a camera model.
    func photo(_ type: UTType) throws -> [UInt8] {
        let context = try #require(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 51.5007, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 0.1246, kCGImagePropertyGPSLongitudeRef: "W"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "TestCam"],
        ]
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return [UInt8](output as Data)
    }

    @Test("ImageIO's JPEG and PNG lose their GPS but keep orientation, camera and pixels", arguments: [UTType.jpeg, .png])
    func roundTrip(type: UTType) throws {
        let original = try photo(type)
        func read(_ bytes: [UInt8]) throws -> (properties: [CFString: Any], image: CGImage?) {
            let source = try #require(CGImageSourceCreateWithData(Data(bytes) as CFData, nil))
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            return (properties, CGImageSourceCreateImageAtIndex(source, 0, nil))
        }
        #expect(try read(original).properties[kCGImagePropertyGPSDictionary] != nil)

        let scrubbed = try read(try LocationScrubber.scrub(original))
        #expect(scrubbed.properties[kCGImagePropertyGPSDictionary] == nil)
        #expect((scrubbed.properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue == 6)
        #expect((scrubbed.properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFModel] as? String == "TestCam")
        #expect(scrubbed.image?.width == 64 && scrubbed.image?.height == 48)
    }
}
#endif
