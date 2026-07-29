import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 2 else {
    fputs("usage: generate-icon.swift <iconset-directory>\n", stderr)
    exit(2)
}

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, alpha: CGFloat = 1) -> CGColor {
    CGColor(red: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

func renderIcon(pixels: Int) throws -> Data {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: pixels * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw CocoaError(.fileWriteUnknown) }

    let scale = CGFloat(pixels) / 1024
    context.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))

    let tileRect = CGRect(x: 66 * scale, y: 66 * scale, width: 892 * scale, height: 892 * scale)
    context.addPath(CGPath(roundedRect: tileRect, cornerWidth: 210 * scale, cornerHeight: 210 * scale, transform: nil))
    context.setFillColor(color(31, 35, 39))
    context.fillPath()

    context.setStrokeColor(color(90, 99, 108))
    context.setLineWidth(max(2, 24 * scale))
    context.setLineCap(.round)
    context.move(to: CGPoint(x: 254 * scale, y: 510 * scale))
    context.addLine(to: CGPoint(x: 770 * scale, y: 510 * scale))
    context.strokePath()

    let centers: [CGFloat] = [254, 426, 598, 770]
    let fills = [
        color(240, 244, 247),
        color(72, 145, 255),
        color(57, 199, 190),
        color(48, 209, 88),
    ]
    for (index, center) in centers.enumerated() {
        let radius = 64 * scale
        context.setFillColor(fills[index])
        context.fillEllipse(in: CGRect(
            x: center * scale - radius,
            y: 510 * scale - radius,
            width: radius * 2,
            height: radius * 2
        ))

        let coreRadius = max(1, 18 * scale)
        context.setFillColor(color(31, 35, 39, alpha: index == 0 ? 0.75 : 0.9))
        context.fillEllipse(in: CGRect(
            x: center * scale - coreRadius,
            y: 510 * scale - coreRadius,
            width: coreRadius * 2,
            height: coreRadius * 2
        ))
    }

    context.setStrokeColor(color(48, 209, 88, alpha: 0.9))
    context.setLineWidth(max(2, 18 * scale))
    context.setLineCap(.round)
    let radioCenter = CGPoint(x: 770 * scale, y: 510 * scale)
    for radius in [96, 142, 188] as [CGFloat] {
        context.addArc(
            center: radioCenter,
            radius: radius * scale,
            startAngle: -0.62,
            endAngle: 0.62,
            clockwise: false
        )
        context.strokePath()
    }

    guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    return data as Data
}

for variant in variants {
    try renderIcon(pixels: variant.pixels).write(to: output.appendingPathComponent(variant.name), options: .atomic)
}
