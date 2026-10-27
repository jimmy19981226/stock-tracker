import AppKit
import Foundation

// The app icon is drawn from three candlesticks. Keep this geometry as the
// source of truth for both the editable SVG and the opaque 1024px catalog PNG.
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let size = 1024
let background = "126B55"
let foreground = "F5FAF6"
let candles: [(x: CGFloat, top: CGFloat, bottom: CGFloat, bodyY: CGFloat, height: CGFloat)] = [
    (320, 430, 790, 510, 210),
    (512, 280, 710, 370, 240),
    (704, 220, 580, 290, 190)
]

func color(_ hex: String) -> NSColor {
    let rgb = UInt32(hex, radix: 16)!
    return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                   green: CGFloat((rgb >> 8) & 255) / 255,
                   blue: CGFloat(rgb & 255) / 255, alpha: 1)
}

let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
context.setAllowsAntialiasing(true)
context.translateBy(x: 0, y: CGFloat(size))
context.scaleBy(x: 1, y: -1)
context.setFillColor(color(background).cgColor)
context.fill(CGRect(x: 0, y: 0, width: size, height: size))

var shapes: [String] = []
for candle in candles {
    context.setFillColor(color(foreground).cgColor)
    let wick = NSRect(x: candle.x - 12, y: candle.top, width: 24,
                      height: candle.bottom - candle.top)
    context.addPath(CGPath(roundedRect: wick, cornerWidth: 12, cornerHeight: 12, transform: nil))
    context.fillPath()
    let body = NSRect(x: candle.x - 56, y: candle.bodyY, width: 112, height: candle.height)
    context.addPath(CGPath(roundedRect: body, cornerWidth: 20, cornerHeight: 20, transform: nil))
    context.fillPath()
    shapes.append("<rect x=\"\(Int(wick.minX))\" y=\"\(Int(wick.minY))\" width=\"24\" height=\"\(Int(wick.height))\" rx=\"12\"/>")
    shapes.append("<rect x=\"\(Int(body.minX))\" y=\"\(Int(body.minY))\" width=\"112\" height=\"\(Int(body.height))\" rx=\"20\"/>")
}
let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)

let directory = URL(fileURLWithPath: output, isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let png = directory.appendingPathComponent("candlestick-icon.png")
try bitmap.representation(using: .png, properties: [:])!.write(to: png)
let svg = """
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <rect width="1024" height="1024" fill="#\(background)"/>
  <g fill="#\(foreground)">
    \(shapes.joined(separator: "\n    "))
  </g>
</svg>

"""
try svg.write(to: directory.appendingPathComponent("candlestick-icon.svg"), atomically: true, encoding: .utf8)
print(png.path)
