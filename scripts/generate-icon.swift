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

func drawAxisWhisper(in context: CGContext) {
  let center = CGPoint(x: 512, y: 514)

  // A barely-there gimbal frame. It reads as refraction before it reads as a
  // literal shape, which keeps the DJI reference intentionally hidden.
  context.saveGState()
  context.translateBy(x: center.x, y: center.y)
  context.rotate(by: -.pi / 8)
  context.setBlendMode(.screen)

  let frameRect = CGRect(x: -286, y: -286, width: 572, height: 572)
  let frame = CGPath(
    roundedRect: frameRect,
    cornerWidth: 154,
    cornerHeight: 154,
    transform: nil
  )
  context.addPath(frame)
  context.setStrokeColor(color(222, 250, 255, alpha: 0.045))
  context.setLineWidth(4)
  context.setShadow(
    offset: .zero,
    blur: 22,
    color: color(79, 205, 236, alpha: 0.055)
  )
  context.strokePath()
  context.restoreGState()

  // Four pinpricks are the only explicit nod to a gimbal's mounting points.
  context.saveGState()
  context.setBlendMode(.screen)
  let nodeRadius: CGFloat = 4
  let nodeDistance: CGFloat = 274
  let nodeAngles = [CGFloat.pi / 4, 3 * CGFloat.pi / 4, 5 * CGFloat.pi / 4, 7 * CGFloat.pi / 4]
  for angle in nodeAngles {
    let nodeCenter = CGPoint(
      x: center.x + cos(angle) * nodeDistance,
      y: center.y + sin(angle) * nodeDistance
    )
    context.setFillColor(color(220, 250, 255, alpha: 0.045))
    context.fillEllipse(
      in: CGRect(
        x: nodeCenter.x - nodeRadius,
        y: nodeCenter.y - nodeRadius,
        width: nodeRadius * 2,
        height: nodeRadius * 2
      )
    )
  }
  context.restoreGState()
}

let ambientGlow = try renderPNG { context in
  context.setBlendMode(.screen)
  try drawRadialGlow(
    in: context,
    center: CGPoint(x: 512, y: 490),
    radius: 360,
    glowColor: color(44, 183, 211, alpha: 0.18)
  )
  try drawRadialGlow(
    in: context,
    center: CGPoint(x: 326, y: 350),
    radius: 205,
    glowColor: color(245, 173, 66, alpha: 0.075)
  )
  try drawRadialGlow(
    in: context,
    center: CGPoint(x: 700, y: 600),
    radius: 260,
    glowColor: color(63, 126, 246, alpha: 0.12)
  )
}

func drawHiddenDJIReflection(in context: CGContext, clippingPath: CGPath) {
  context.saveGState()
  context.addPath(clippingPath)
  context.clip()
  context.translateBy(x: 512, y: 514)
  context.rotate(by: -.pi / 5)
  context.setBlendMode(.screen)

  // Three quiet, rounded reflections. Together they echo DJI's three-band
  // mark, but the low contrast and lens refraction keep it from becoming a
  // copy of the wordmark.
  let barWidth: CGFloat = 44
  let barHeight: CGFloat = 128
  let barGap: CGFloat = 17
  let firstX = -barWidth * 1.5 - barGap
  for index in 0..<3 {
    let x = firstX + CGFloat(index) * (barWidth + barGap)
    let rect = CGRect(x: x, y: -barHeight / 2, width: barWidth, height: barHeight)
    let path = CGPath(
      roundedRect: rect,
      cornerWidth: barWidth / 2,
      cornerHeight: barWidth / 2,
      transform: nil
    )
    context.addPath(path)
    context.setFillColor(color(238, 255, 255, alpha: 0.075))
    context.setStrokeColor(color(255, 255, 255, alpha: 0.15))
    context.setLineWidth(3)
    context.drawPath(using: .fillStroke)
  }

  // A soft oblique highlight makes the bars feel embedded in the glass,
  // rather than stamped on top of it.
  let highlightRect = CGRect(x: -168, y: 48, width: 338, height: 16)
  let highlight = CGPath(
    roundedRect: highlightRect,
    cornerWidth: 8,
    cornerHeight: 8,
    transform: nil
  )
  context.addPath(highlight)
  context.setFillColor(color(255, 255, 255, alpha: 0.08))
  context.fillPath()
  context.restoreGState()
}

func drawGlassLens(in context: CGContext) throws {
  let center = CGPoint(x: 512, y: 514)

  // Give the glass core a little more presence at Dock size while keeping
  // the outer gimbal whisper comfortably in the background.
  context.saveGState()
  context.translateBy(x: center.x, y: center.y)
  context.scaleBy(x: 1.68, y: 1.68)
  context.translateBy(x: -center.x, y: -center.y)
  defer { context.restoreGState() }

  let lensRect = CGRect(x: 298, y: 300, width: 428, height: 428)
  let lensPath = CGPath(ellipseIn: lensRect, transform: nil)

  context.saveGState()
  context.addPath(lensPath)
  context.setFillColor(color(78, 202, 229, alpha: 0.14))
  context.setShadow(
    offset: .zero,
    blur: 38,
    color: color(43, 183, 225, alpha: 0.22)
  )
  context.fillPath()
  context.restoreGState()

  context.saveGState()
  context.addPath(lensPath)
  context.clip()
  let lensGradient = try gradient(
    colors: [
      color(244, 255, 255, alpha: 0.28),
      color(88, 197, 218, alpha: 0.12),
      color(45, 91, 165, alpha: 0.22),
    ],
    locations: [0, 0.48, 1]
  )
  context.drawLinearGradient(
    lensGradient,
    start: CGPoint(x: 360, y: 330),
    end: CGPoint(x: 690, y: 740),
    options: []
  )

  context.setBlendMode(.screen)
  let highlight = try gradient(
    colors: [
      color(255, 255, 255, alpha: 0.22),
      color(255, 255, 255, alpha: 0),
    ],
    locations: [0, 1]
  )
  context.drawRadialGradient(
    highlight,
    startCenter: CGPoint(x: 410, y: 390),
    startRadius: 0,
    endCenter: CGPoint(x: 410, y: 390),
    endRadius: 200,
    options: [.drawsAfterEndLocation]
  )
  context.restoreGState()

  context.addPath(lensPath)
  context.setStrokeColor(color(246, 255, 255, alpha: 0.52))
  context.setLineWidth(6)
  context.strokePath()

  let innerRect = lensRect.insetBy(dx: 27, dy: 27)
  context.addEllipse(in: innerRect)
  context.setStrokeColor(color(255, 255, 255, alpha: 0.12))
  context.setLineWidth(3)
  context.strokePath()

  drawHiddenDJIReflection(in: context, clippingPath: lensPath)

  // A small floating hub finishes the gimbal reference without turning the
  // icon into an obvious camera or drone illustration.
  context.saveGState()
  context.setBlendMode(.screen)
  context.addEllipse(in: CGRect(x: 452, y: 454, width: 120, height: 120))
  context.setFillColor(color(8, 39, 64, alpha: 0.23))
  context.setShadow(
    offset: .zero,
    blur: 18,
    color: color(23, 184, 225, alpha: 0.22)
  )
  context.fillPath()
  context.restoreGState()

  context.addEllipse(in: CGRect(x: 452, y: 454, width: 120, height: 120))
  context.setStrokeColor(color(255, 255, 255, alpha: 0.34))
  context.setLineWidth(4)
  context.strokePath()

  context.setFillColor(color(239, 255, 255, alpha: 0.62))
  context.fillEllipse(in: CGRect(x: 486, y: 479, width: 32, height: 18))

  // One clean specular arc gives the core its liquid-glass edge.
  context.saveGState()
  context.setBlendMode(.screen)
  context.addArc(
    center: center,
    radius: 189,
    startAngle: 3.52,
    endAngle: 5.65,
    clockwise: false
  )
  context.setStrokeColor(color(255, 255, 255, alpha: 0.40))
  context.setLineWidth(5)
  context.strokePath()
  context.restoreGState()
}

let signalBars = try renderPNG { context in
  drawAxisWhisper(in: context)
  try drawGlassLens(in: context)
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
