import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Readies a photo for posting. JPEG, PNG, GIF and WebP are posted as they
/// are; other formats, such as HEIC, become JPEG so every platform can show
/// them (and because the core refuses HEIC, whose location data it can't
/// remove yet). Location is removed by CirclesKit's LocationScrubber when the
/// post is made, the same on every platform.
nonisolated enum PhotoPreparation {
    struct Photo {
        var data: Data
        var mediaType: String
        /// As displayed, after any rotation in the orientation tag.
        var width: UInt32?
        var height: UInt32?
    }

    static func prepare(_ data: Data) -> Photo? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source).flatMap({ UTType($0 as String) })
        else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        var width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.uint32Value
        var height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.uint32Value
        // Orientations 5–8 rotate by 90°, so the displayed size is swapped.
        if let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue, orientation >= 5 {
            swap(&width, &height)
        }

        if [UTType.jpeg, .png, .gif, .webP].contains(type), let mediaType = type.preferredMIMEType {
            return Photo(data: data, mediaType: mediaType, width: width, height: height)
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        // The source's metadata comes along (orientation, camera, location);
        // LocationScrubber removes the location when posting.
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        CGImageDestinationAddImageFromSource(destination, source, 0, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return Photo(data: output as Data, mediaType: "image/jpeg", width: width, height: height)
    }
}
