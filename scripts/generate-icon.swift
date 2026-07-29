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

func gradient(
    colors: [CGColor],
    locations: [CGFloat]? = nil
) throws -> CGGradient {
    guard let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: colors as CFArray,
        locations: locations
    ) else { throw CocoaError(.fileWriteUnknown) }
    return gradient
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

    let tileRect = CGRect(x: 68 * scale, y: 68 * scale, width: 888 * scale, height: 888 * scale)
    let tilePath = CGPath(
        roundedRect: tileRect,
        cornerWidth: 220 * scale,
        cornerHeight: 220 * scale,
        transform: nil
    )

    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -18 * scale),
        blur: 34 * scale,
        color: color(0, 0, 0, alpha: 0.34)
    )
    context.addPath(tilePath)
    context.setFillColor(color(16, 48, 48))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tilePath)
    context.clip()

    let baseGradient = try gradient(
        colors: [
            color(17, 61, 57),
            color(20, 116, 120),
            color(57, 103, 174),
        ],
        locations: [0, 0.48, 1]
    )
    context.drawLinearGradient(
        baseGradient,
        start: CGPoint(x: 130 * scale, y: 130 * scale),
        end: CGPoint(x: 900 * scale, y: 910 * scale),
        options: []
    )

    context.setBlendMode(.screen)
    let warmGlow = try gradient(
        colors: [
            color(242, 168, 93, alpha: 0.78),
            color(242, 168, 93, alpha: 0),
        ],
        locations: [0, 1]
    )
    context.drawRadialGradient(
        warmGlow,
        startCenter: CGPoint(x: 210 * scale, y: 204 * scale),
        startRadius: 0,
        endCenter: CGPoint(x: 210 * scale, y: 204 * scale),
        endRadius: 500 * scale,
        options: [.drawsAfterEndLocation]
    )

    let coolGlow = try gradient(
        colors: [
            color(92, 229, 211, alpha: 0.54),
            color(92, 229, 211, alpha: 0),
        ],
        locations: [0, 1]
    )
    context.drawRadialGradient(
        coolGlow,
        startCenter: CGPoint(x: 816 * scale, y: 806 * scale),
        startRadius: 0,
        endCenter: CGPoint(x: 816 * scale, y: 806 * scale),
        endRadius: 510 * scale,
        options: [.drawsAfterEndLocation]
    )
    context.restoreGState()

    context.saveGState()
    context.addPath(tilePath)
    context.setStrokeColor(color(255, 255, 255, alpha: 0.26))
    context.setLineWidth(max(1, 5 * scale))
    context.strokePath()

    let insetRect = tileRect.insetBy(dx: 42 * scale, dy: 42 * scale)
    context.addPath(CGPath(
        roundedRect: insetRect,
        cornerWidth: 180 * scale,
        cornerHeight: 180 * scale,
        transform: nil
    ))
    context.setStrokeColor(color(255, 255, 255, alpha: 0.09))
    context.setLineWidth(max(1, 3 * scale))
    context.strokePath()
    context.restoreGState()

    let bars: [(x: CGFloat, height: CGFloat, fill: CGColor)] = [
        (341, 112, color(251, 189, 112, alpha: 0.92)),
        (433, 172, color(172, 232, 173, alpha: 0.92)),
        (525, 238, color(105, 224, 205, alpha: 0.94)),
        (617, 310, color(117, 194, 249, alpha: 0.94)),
    ]
    for bar in bars {
        let barRect = CGRect(
            x: bar.x * scale,
            y: 256 * scale,
            width: 66 * scale,
            height: bar.height * scale
        )
        let barPath = CGPath(
            roundedRect: barRect,
            cornerWidth: 33 * scale,
            cornerHeight: 33 * scale,
            transform: nil
        )
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: 8 * scale),
            blur: 22 * scale,
            color: bar.fill.copy(alpha: 0.38)
        )
        context.addPath(barPath)
        context.setFillColor(bar.fill)
        context.fillPath()
        context.restoreGState()

        context.addPath(barPath)
        context.setStrokeColor(color(255, 255, 255, alpha: 0.34))
        context.setLineWidth(max(1, 3 * scale))
        context.strokePath()
    }

    let bridgePath = CGMutablePath()
    bridgePath.move(to: CGPoint(x: 284 * scale, y: 556 * scale))
    bridgePath.addCurve(
        to: CGPoint(x: 740 * scale, y: 556 * scale),
        control1: CGPoint(x: 390 * scale, y: 766 * scale),
        control2: CGPoint(x: 634 * scale, y: 766 * scale)
    )

    context.saveGState()
    context.setLineCap(.round)
    context.setShadow(
        offset: CGSize(width: 0, height: -12 * scale),
        blur: 30 * scale,
        color: color(11, 43, 57, alpha: 0.42)
    )
    context.addPath(bridgePath)
    context.setStrokeColor(color(218, 249, 246, alpha: 0.54))
    context.setLineWidth(max(2, 92 * scale))
    context.strokePath()
    context.restoreGState()

    context.saveGState()
    context.setBlendMode(.screen)
    context.setLineCap(.round)
    context.addPath(bridgePath)
    context.setStrokeColor(color(255, 255, 255, alpha: 0.52))
    context.setLineWidth(max(1, 12 * scale))
    context.strokePath()
    context.restoreGState()

    for x in [240, 696] as [CGFloat] {
        let pillarRect = CGRect(
            x: x * scale,
            y: 238 * scale,
            width: 88 * scale,
            height: 342 * scale
        )
        let pillarPath = CGPath(
            roundedRect: pillarRect,
            cornerWidth: 44 * scale,
            cornerHeight: 44 * scale,
            transform: nil
        )
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -10 * scale),
            blur: 24 * scale,
            color: color(8, 38, 49, alpha: 0.4)
        )
        context.addPath(pillarPath)
        context.setFillColor(color(225, 251, 248, alpha: 0.48))
        context.fillPath()
        context.restoreGState()

        context.addPath(pillarPath)
        context.setStrokeColor(color(255, 255, 255, alpha: 0.48))
        context.setLineWidth(max(1, 4 * scale))
        context.strokePath()

        context.setFillColor(color(255, 255, 255, alpha: 0.52))
        context.fillEllipse(in: CGRect(
            x: (x + 35) * scale,
            y: 518 * scale,
            width: 18 * scale,
            height: 18 * scale
        ))
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
