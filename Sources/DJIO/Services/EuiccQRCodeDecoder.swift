import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

enum EuiccQRCodeError: LocalizedError, Sendable, Equatable {
  case unreadableImage
  case noQRCode
  case invalidActivationCode

  var errorDescription: String? {
    switch self {
    case .unreadableImage:
      return "无法读取这张图片，请选择 PNG、JPEG 或 HEIC 图片。"
    case .noQRCode:
      return "图片中没有检测到二维码。"
    case .invalidActivationCode:
      return "二维码内容不是有效的 LPA eSIM 激活码。"
    }
  }
}

struct EuiccQRCodeDecoder: Sendable {
  static func activationCode(from url: URL) throws -> EuiccActivationCode {
    let didStartAccessing = url.startAccessingSecurityScopedResource()
    defer {
      if didStartAccessing {
        url.stopAccessingSecurityScopedResource()
      }
    }

    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
      throw EuiccQRCodeError.unreadableImage
    }
    return try activationCode(from: image)
  }

  static func activationCode(from image: CGImage) throws -> EuiccActivationCode {
    let request = VNDetectBarcodesRequest()
    request.symbologies = [.qr]

    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    try handler.perform([request])

    let payloads = request.results?.compactMap(\.payloadStringValue) ?? []
    guard !payloads.isEmpty else {
      throw EuiccQRCodeError.noQRCode
    }

    for payload in payloads {
      if let activationCode = try? EuiccActivationCode(payload) {
        return activationCode
      }
    }
    throw EuiccQRCodeError.invalidActivationCode
  }
}
