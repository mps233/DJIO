import Foundation

enum SMSPDUEncodingError: LocalizedError, Equatable {
  case emptyRecipient
  case invalidRecipient
  case recipientTooLong(maximumDigits: Int)
  case emptyMessage
  case messageTooLong(maximumParts: Int)

  var errorDescription: String? {
    switch self {
    case .emptyRecipient:
      return "请输入收件人号码"
    case .invalidRecipient:
      return "收件人号码格式无效"
    case .recipientTooLong(let maximumDigits):
      return "收件人号码不能超过 \(maximumDigits) 位"
    case .emptyMessage:
      return "短信正文不能为空"
    case .messageTooLong(let maximumParts):
      return "短信不能超过 \(maximumParts) 条分段"
    }
  }
}

struct EncodedSMSPart: Sendable, Equatable {
  let recipient: String
  let pdu: String
  let tpduLength: Int
  let alphabet: SMSAlphabet
  let sequence: Int
  let totalParts: Int
  let concatenationReference: UInt8?
}

struct SMSPDUEncoder {
  private static let maximumRecipientDigits = 20
  private static let maximumParts = 255
  private static let singleGSM7Capacity = 160
  private static let concatenatedGSM7Capacity = 153
  private static let singleUCS2Capacity = 70
  private static let concatenatedUCS2Capacity = 67

  private let concatenationReferenceProvider: () -> UInt8

  init(
    concatenationReferenceProvider: @escaping () -> UInt8 = {
      UInt8.random(in: UInt8.min...UInt8.max)
    }
  ) {
    self.concatenationReferenceProvider = concatenationReferenceProvider
  }

  func encode(recipient: String, body: String) throws -> [EncodedSMSPart] {
    let normalizedRecipient = try normalizeRecipient(recipient)
    guard !body.isEmpty else { throw SMSPDUEncodingError.emptyMessage }

    if let tokens = gsm7Tokens(for: body) {
      return try encodeGSM7(tokens, recipient: normalizedRecipient)
    }
    return try encodeUCS2(Array(body.utf16), recipient: normalizedRecipient)
  }

  func normalizeRecipient(_ recipient: String) throws -> String {
    let trimmed = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw SMSPDUEncodingError.emptyRecipient }

    var compact = ""
    compact.reserveCapacity(trimmed.count)
    for character in trimmed {
      if character.isWhitespace || Self.ignoredRecipientCharacters.contains(character) {
        continue
      }
      compact.append(character)
    }

    if compact.hasPrefix("00") {
      compact = "+" + compact.dropFirst(2)
    }

    let hasInternationalPrefix = compact.first == "+"
    let digits = hasInternationalPrefix ? compact.dropFirst() : compact[...]
    guard !digits.isEmpty, digits.allSatisfy(\.isASCIIDigit) else {
      throw SMSPDUEncodingError.invalidRecipient
    }
    guard digits.count <= Self.maximumRecipientDigits else {
      throw SMSPDUEncodingError.recipientTooLong(
        maximumDigits: Self.maximumRecipientDigits
      )
    }
    return hasInternationalPrefix ? "+" + digits : String(digits)
  }

  private func encodeGSM7(
    _ tokens: [[UInt8]],
    recipient: String
  ) throws -> [EncodedSMSPart] {
    let septetCount = tokens.reduce(into: 0) { $0 += $1.count }
    if septetCount <= Self.singleGSM7Capacity {
      let userData = packGSM7(tokens.flatMap { $0 })
      return [
        makePart(
          recipient: recipient,
          alphabet: .gsm7,
          userDataLength: septetCount,
          userData: userData,
          sequence: 1,
          totalParts: 1,
          reference: nil
        )
      ]
    }

    let segments = splitGSM7(tokens, capacity: Self.concatenatedGSM7Capacity)
    return try makeConcatenatedParts(
      segments: segments,
      recipient: recipient,
      alphabet: .gsm7
    ) { segment, header in
      let headerSeptets = (header.count * 8 + 6) / 7
      return (
        headerSeptets + segment.count,
        packGSM7(segment, header: header, payloadBitOffset: headerSeptets * 7)
      )
    }
  }

  private func encodeUCS2(
    _ codeUnits: [UInt16],
    recipient: String
  ) throws -> [EncodedSMSPart] {
    if codeUnits.count <= Self.singleUCS2Capacity {
      let userData = bigEndianBytes(codeUnits)
      return [
        makePart(
          recipient: recipient,
          alphabet: .ucs2,
          userDataLength: userData.count,
          userData: userData,
          sequence: 1,
          totalParts: 1,
          reference: nil
        )
      ]
    }

    let segments = splitUTF16(codeUnits, capacity: Self.concatenatedUCS2Capacity)
    return try makeConcatenatedParts(
      segments: segments,
      recipient: recipient,
      alphabet: .ucs2
    ) { segment, header in
      let userData = header + bigEndianBytes(segment)
      return (userData.count, userData)
    }
  }

  private func makeConcatenatedParts<Segment>(
    segments: [Segment],
    recipient: String,
    alphabet: SMSAlphabet,
    makeUserData: (Segment, [UInt8]) -> (length: Int, bytes: [UInt8])
  ) throws -> [EncodedSMSPart] {
    guard segments.count <= Self.maximumParts else {
      throw SMSPDUEncodingError.messageTooLong(maximumParts: Self.maximumParts)
    }

    let reference = concatenationReferenceProvider()
    return segments.enumerated().map { offset, segment in
      let sequence = offset + 1
      let header: [UInt8] = [
        0x05, 0x00, 0x03, reference, UInt8(segments.count), UInt8(sequence),
      ]
      let userData = makeUserData(segment, header)
      return makePart(
        recipient: recipient,
        alphabet: alphabet,
        userDataLength: userData.length,
        userData: userData.bytes,
        sequence: sequence,
        totalParts: segments.count,
        reference: reference
      )
    }
  }

  private func makePart(
    recipient: String,
    alphabet: SMSAlphabet,
    userDataLength: Int,
    userData: [UInt8],
    sequence: Int,
    totalParts: Int,
    reference: UInt8?
  ) -> EncodedSMSPart {
    let address = encodeAddress(recipient)
    let firstOctet: UInt8 = totalParts > 1 ? 0x41 : 0x01
    let dataCodingScheme: UInt8 = alphabet == .gsm7 ? 0x00 : 0x08
    let tpdu =
      [
        firstOctet,
        0x00,
        UInt8(address.digitCount),
        address.type,
      ] + address.bytes + [
        0x00,
        dataCodingScheme,
        UInt8(userDataLength),
      ] + userData
    let completePDU = [UInt8(0x00)] + tpdu

    return EncodedSMSPart(
      recipient: recipient,
      pdu: completePDU.map { String(format: "%02X", $0) }.joined(),
      tpduLength: tpdu.count,
      alphabet: alphabet,
      sequence: sequence,
      totalParts: totalParts,
      concatenationReference: reference
    )
  }

  private func encodeAddress(_ recipient: String) -> (
    digitCount: Int,
    type: UInt8,
    bytes: [UInt8]
  ) {
    let international = recipient.first == "+"
    let digits = international ? recipient.dropFirst() : recipient[...]
    var bytes: [UInt8] = []
    bytes.reserveCapacity((digits.count + 1) / 2)
    var index = digits.startIndex

    while index < digits.endIndex {
      let low = digits[index].wholeNumberValue!
      index = digits.index(after: index)
      let high: Int
      if index < digits.endIndex {
        high = digits[index].wholeNumberValue!
        index = digits.index(after: index)
      } else {
        high = 0x0F
      }
      bytes.append(UInt8(low | high << 4))
    }
    return (digits.count, international ? 0x91 : 0x81, bytes)
  }

  private func gsm7Tokens(for body: String) -> [[UInt8]]? {
    var result: [[UInt8]] = []
    result.reserveCapacity(body.count)
    for character in body {
      if let value = Self.gsm7Default[character] {
        result.append([value])
      } else if let value = Self.gsm7Extension[character] {
        result.append([0x1B, value])
      } else {
        return nil
      }
    }
    return result
  }

  private func splitGSM7(_ tokens: [[UInt8]], capacity: Int) -> [[UInt8]] {
    var segments: [[UInt8]] = []
    var current: [UInt8] = []
    current.reserveCapacity(capacity)

    for token in tokens {
      if current.count + token.count > capacity {
        segments.append(current)
        current = []
        current.reserveCapacity(capacity)
      }
      current.append(contentsOf: token)
    }
    if !current.isEmpty { segments.append(current) }
    return segments
  }

  private func splitUTF16(_ codeUnits: [UInt16], capacity: Int) -> [[UInt16]] {
    var segments: [[UInt16]] = []
    var start = 0

    while start < codeUnits.count {
      var end = min(start + capacity, codeUnits.count)
      if end < codeUnits.count,
        Self.isHighSurrogate(codeUnits[end - 1]),
        Self.isLowSurrogate(codeUnits[end])
      {
        end -= 1
      }
      segments.append(Array(codeUnits[start..<end]))
      start = end
    }
    return segments
  }

  private func packGSM7(
    _ septets: [UInt8],
    header: [UInt8] = [],
    payloadBitOffset: Int = 0
  ) -> [UInt8] {
    let bitOffset = header.isEmpty ? 0 : payloadBitOffset
    let byteCount = (bitOffset + septets.count * 7 + 7) / 8
    var bytes = [UInt8](repeating: 0, count: byteCount)
    if !header.isEmpty {
      bytes.replaceSubrange(0..<header.count, with: header)
    }

    for (index, septet) in septets.enumerated() {
      let bitIndex = bitOffset + index * 7
      let byteIndex = bitIndex / 8
      let shift = bitIndex % 8
      bytes[byteIndex] |= septet << shift
      if shift > 1 {
        bytes[byteIndex + 1] |= septet >> (8 - shift)
      }
    }
    return bytes
  }

  private func bigEndianBytes(_ codeUnits: [UInt16]) -> [UInt8] {
    codeUnits.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
  }

  private static func isHighSurrogate(_ value: UInt16) -> Bool {
    (0xD800...0xDBFF).contains(value)
  }

  private static func isLowSurrogate(_ value: UInt16) -> Bool {
    (0xDC00...0xDFFF).contains(value)
  }

  private static let ignoredRecipientCharacters: Set<Character> = ["-", "(", ")", "."]

  private static let gsm7Default: [Character: UInt8] = {
    let characters = Array(
      "@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞ\u{001B}ÆæßÉ !\"#¤%&'()*+,-./0123456789:;<=>?¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà"
    )
    var mapping = Dictionary(
      uniqueKeysWithValues: characters.enumerated().map { ($1, UInt8($0)) }
    )
    mapping.removeValue(forKey: "\u{001B}")
    return mapping
  }()

  private static let gsm7Extension: [Character: UInt8] = [
    "\u{000C}": 0x0A,
    "^": 0x14,
    "{": 0x28,
    "}": 0x29,
    "\\": 0x2F,
    "[": 0x3C,
    "~": 0x3D,
    "]": 0x3E,
    "|": 0x40,
    "€": 0x65,
  ]
}

extension Character {
  fileprivate var isASCIIDigit: Bool {
    unicodeScalars.count == 1
      && unicodeScalars.first.map { (0x30...0x39).contains($0.value) } == true
  }
}
