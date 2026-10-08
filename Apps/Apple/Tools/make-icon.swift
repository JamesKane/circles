// Draws the macOS app icon at every size AppIcon.appiconset needs, from the
// same artwork as the GNOME icon (Apps/Gnome/.../dev.circles.Circles.svg):
// three overlapping rings on a blue tile. Laid out on Apple's macOS grid: a
// 1024 px canvas with an 824 px superellipse tile, a vertical gradient and a
// soft drop shadow.
//
//     swift Apps/Apple/Tools/make-icon.swift Apps/Apple/Circles/Assets.xcassets/AppIcon.appiconset

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let output = URL(filePath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".", directoryHint: .isDirectory)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// A superellipse (|x|^n + |y|^n = 1), the continuous-corner shape of macOS icons.
func superellipse(in rect: CGRect, exponent n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = pow(abs(c), 2 / n) * (c < 0 ? -1 : 1)
        let y = pow(abs(s), 2 / n) * (s < 0 ? -1 : 1)
        let point = CGPoint(x: rect.midX + x * rect.width / 2, y: rect.midY + y * rect.height / 2)
        i == 0 ? path.move(to: point) : path.addLine(to: point)
    }
    path.closeSubpath()
    return path
}

func drawIcon(pixels: Int) -> CGImage {
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(pixels) / 1024
    context.scaleBy(x: scale, y: scale)
    // CoreGraphics' origin is bottom-left; the artwork is laid out top-down.
    context.translateBy(x: 0, y: 1024)
    context.scaleBy(x: 1, y: -1)

    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = superellipse(in: tile)

    // Drop shadow under the tile.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: 10), blur: 20, color: color(0x000000, alpha: 0.3))
    context.addPath(shape)
    context.setFillColor(color(0x1C71D8))
    context.fillPath()
    context.restoreGState()

    // The tile: GNOME's blue (#1c71d8), a little lighter at the top.
    context.saveGState()
    context.addPath(shape)
    context.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                              colors: [color(0x3584E4), color(0x1C71D8), color(0x1A5FB4)] as CFArray,
                              locations: [0, 0.55, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 512, y: tile.minY), end: CGPoint(x: 512, y: tile.maxY), options: [])
    context.restoreGState()

    // The rings, mapped from the SVG's 112-unit tile (at 8,8) onto 824 px.
    // At small sizes the strokes get heavier so the rings stay legible.
    let unit = tile.width / 112
    let weight: CGFloat = pixels <= 16 ? 1.7 : pixels <= 32 ? 1.35 : pixels <= 64 ? 1.15 : 1
    func ring(_ cx: CGFloat, _ cy: CGFloat, _ hex: UInt32) {
        let r = 22 * unit
        let center = CGPoint(x: tile.minX + (cx - 8) * unit, y: tile.minY + (cy - 8) * unit)
        context.setStrokeColor(color(hex, alpha: 0.95))
        context.setLineWidth(7 * unit * weight)
        context.strokeEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
    }
    ring(50, 54, 0xFFFFFF)
    ring(78, 54, 0x99C1F1)
    ring(64, 78, 0xF6D32D)

    return context.makeImage()!
}

// macOS AppIcon slots: point size × scale.
let slots: [(points: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
var images: [[String: String]] = []
for slot in slots {
    let pixels = slot.points * slot.scale
    let name = "icon_\(slot.points)x\(slot.points)\(slot.scale == 2 ? "@2x" : "").png"
    let destination = CGImageDestinationCreateWithURL(output.appending(path: name) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, drawIcon(pixels: pixels), nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("couldn't write \(name)") }
    images.append(["filename": name, "idiom": "mac", "scale": "\(slot.scale)x", "size": "\(slot.points)x\(slot.points)"])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: output.appending(path: "Contents.json"))
print("Wrote \(images.count) icons to \(output.path)")
