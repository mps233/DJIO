import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outputDirectories = CommandLine.arguments.dropFirst().map {
  URL(fileURLWithPath: $0, isDirectory: true)
}
guard !outputDirectories.isEmpty else {
  fputs("usage: generate-icon.swift <asset-directory> [<asset-directory> ...]\n", stderr)
  exit(2)
}

let canvasSize = 1024
let canvasRect = CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, alpha: CGFloat = 1) -> CGColor {
  CGColor(red: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

func gradient(
  colors: [CGColor],
  locations: [CGFloat]? = nil
) throws -> CGGradient {
  guard
    let gradient = CGGradient(
      colorsSpace: CGColorSpaceCreateDeviceRGB(),
      colors: colors as CFArray,
      locations: locations
    )
  else {
    throw CocoaError(.fileWriteUnknown)
  }
  return gradient
}

func renderPNG(_ draw: (CGContext) throws -> Void) throws -> Data {
  guard
    let context = CGContext(
      data: nil,
      width: canvasSize,
      height: canvasSize,
      bitsPerComponent: 8,
      bytesPerRow: canvasSize * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
  else {
    throw CocoaError(.fileWriteUnknown)
  }

  context.clear(canvasRect)
  try draw(context)

  guard let image = context.makeImage() else {
    throw CocoaError(.fileWriteUnknown)
  }
  let data = NSMutableData()
  guard
    let destination = CGImageDestinationCreateWithData(
      data,
      UTType.png.identifier as CFString,
      1,
      nil
    )
  else {
    throw CocoaError(.fileWriteUnknown)
  }
  CGImageDestinationAddImage(destination, image, nil)
  guard CGImageDestinationFinalize(destination) else {
    throw CocoaError(.fileWriteUnknown)
  }
  return data as Data
}

func drawRadialGlow(
  in context: CGContext,
  center: CGPoint,
  radius: CGFloat,
  glowColor: CGColor
) throws {
  guard let transparentGlowColor = glowColor.copy(alpha: 0) else {
    throw CocoaError(.fileWriteUnknown)
  }
  let glow = try gradient(
    colors: [
      glowColor,
      transparentGlowColor,
    ],
    locations: [0, 1]
  )
  context.drawRadialGradient(
    glow,
    startCenter: center,
    startRadius: 0,
    endCenter: center,
    endRadius: radius,
    options: [.drawsAfterEndLocation]
  )
}

let ambientGlow = try renderPNG { context in
  context.setBlendMode(.screen)
  try drawRadialGlow(
    in: context,
    center: CGPoint(x: 512, y: 490),
    radius: 360,
    glowColor: color(44, 183, 211, alpha: 0.26)
  )
  try drawRadialGlow(
    in: context,
    center: CGPoint(x: 326, y: 345),
    radius: 210,
    glowColor: color(245, 173, 66, alpha: 0.16)
  )
  try drawRadialGlow(
    in: context,
    center: CGPoint(x: 690, y: 610),
    radius: 250,
    glowColor: color(63, 126, 246, alpha: 0.18)
  )
}

let barWidth: CGFloat = 86
let barGap: CGFloat = 32
let barHeights: [CGFloat] = [170, 250, 330, 410]
let totalBarWidth = barWidth * CGFloat(barHeights.count)
  + barGap * CGFloat(barHeights.count - 1)
let firstBarX = (CGFloat(canvasSize) - totalBarWidth) / 2
let baseline: CGFloat = 286

let barColors: [(top: CGColor, middle: CGColor, bottom: CGColor, glow: CGColor)] = [
  (
    color(255, 246, 214, alpha: 0.96),
    color(248, 190, 76, alpha: 0.90),
    color(219, 133, 33, alpha: 0.92),
    color(246, 174, 55, alpha: 0.34)
  ),
  (
    color(224, 255, 240, alpha: 0.96),
    color(81, 218, 157, alpha: 0.90),
    color(30, 155, 119, alpha: 0.92),
    color(56, 206, 148, alpha: 0.32)
  ),
  (
    color(218, 255, 255, alpha: 0.96),
    color(56, 211, 213, alpha: 0.90),
    color(24, 143, 169, alpha: 0.92),
    color(41, 197, 210, alpha: 0.34)
  ),
  (
    color(224, 243, 255, alpha: 0.97),
    color(81, 162, 247, alpha: 0.92),
    color(43, 95, 207, alpha: 0.94),
    color(70, 143, 244, alpha: 0.36)
  ),
]

let signalBars = try renderPNG { context in
  for index in barHeights.indices {
    let x = firstBarX + CGFloat(index) * (barWidth + barGap)
    let height = barHeights[index]
    let rect = CGRect(x: x, y: baseline, width: barWidth, height: height)
    let radius = barWidth / 2
    let path = CGPath(
      roundedRect: rect,
      cornerWidth: radius,
      cornerHeight: radius,
      transform: nil
    )
    let palette = barColors[index]

    context.saveGState()
    context.setShadow(
      offset: CGSize(width: 0, height: -10),
      blur: 26,
      color: palette.glow
    )
    context.addPath(path)
    context.setFillColor(palette.middle)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(path)
    context.clip()
    let verticalFill = try gradient(
      colors: [palette.bottom, palette.middle, palette.top],
      locations: [0, 0.58, 1]
    )
    context.drawLinearGradient(
      verticalFill,
      start: CGPoint(x: rect.midX, y: rect.minY),
      end: CGPoint(x: rect.midX, y: rect.maxY),
      options: []
    )

    context.setBlendMode(.screen)
    let edgeRefraction = try gradient(
      colors: [
        color(255, 255, 255, alpha: 0.62),
        color(255, 255, 255, alpha: 0.08),
        color(255, 255, 255, alpha: 0.24),
      ],
      locations: [0, 0.48, 1]
    )
    context.drawLinearGradient(
      edgeRefraction,
      start: CGPoint(x: rect.minX, y: rect.midY),
      end: CGPoint(x: rect.maxX, y: rect.midY),
      options: []
    )

    let topHighlight = CGRect(
      x: rect.minX + 14,
      y: rect.maxY - 42,
      width: rect.width - 28,
      height: 24
    )
    context.setFillColor(color(255, 255, 255, alpha: 0.28))
    context.fillEllipse(in: topHighlight)
    context.restoreGState()

    context.addPath(path)
    context.setStrokeColor(color(255, 255, 255, alpha: 0.76))
    context.setLineWidth(5)
    context.strokePath()

    let innerRect = rect.insetBy(dx: 7, dy: 7)
    context.addPath(
      CGPath(
        roundedRect: innerRect,
        cornerWidth: max(1, radius - 7),
        cornerHeight: max(1, radius - 7),
        transform: nil
      )
    )
    context.setStrokeColor(color(255, 255, 255, alpha: 0.16))
    context.setLineWidth(2)
    context.strokePath()
  }
}

for outputDirectory in outputDirectories {
  try FileManager.default.createDirectory(
    at: outputDirectory,
    withIntermediateDirectories: true
  )
  try ambientGlow.write(
    to: outputDirectory.appendingPathComponent("AmbientGlow.png"),
    options: .atomic
  )
  try signalBars.write(
    to: outputDirectory.appendingPathComponent("SignalBars.png"),
    options: .atomic
  )
}
