import Foundation

enum SMSPDUError: LocalizedError, Equatable {
  case invalidHex
  case truncated(String)
  case unsupportedMessageType(UInt8)
  case unsupportedEncoding(UInt8)
  case invalidTimestamp
  case invalidUserData

  var errorDescription: String? {
    switch self {
    case .invalidHex: return "短信 PDU 不是有效的十六进制数据"
    case .truncated(let field): return "短信 PDU 在 \(field) 处不完整"
    case .unsupportedMessageType(let value): return String(format: "暂不支持 TPDU 类型 0x%02X", value)
    case .unsupportedEncoding(let value): return String(format: "暂不支持短信编码 DCS 0x%02X", value)
    case .invalidTimestamp: return "短信时间戳无效"
    case .invalidUserData: return "短信正文数据无效"
    }
  }
}

struct SMSPDUDecoder {
  func decode(_ pdu: String) throws -> DecodedSMSPart {
    let bytes = try Self.hexBytes(pdu)
    var reader = ByteReader(bytes: bytes)

    let serviceCenterLength = Int(try reader.byte(field: "SMSC 长度"))
    try reader.skip(serviceCenterLength, field: "SMSC")

    let firstOctet = try reader.byte(field: "首字节")
    guard firstOctet & 0x03 == 0 else {
      throw SMSPDUError.unsupportedMessageType(firstOctet & 0x03)
    }
    let hasUserDataHeader = firstOctet & 0x40 != 0

    let addressLength = Int(try reader.byte(field: "发送方长度"))
    let typeOfAddress = try reader.byte(field: "发送方类型")
    let sender = try decodeAddress(length: addressLength, type: typeOfAddress, reader: &reader)

    _ = try reader.byte(field: "PID")
    let dataCodingScheme = try reader.byte(field: "DCS")
    let timestampBytes = try reader.bytes(7, field: "时间戳")
    let receivedAt = try decodeTimestamp(timestampBytes)
    let userDataLength = Int(try reader.byte(field: "正文长度"))
    let userData = reader.remainingBytes()

    let alphabet = try alphabet(for: dataCodingScheme)
    let header = hasUserDataHeader ? try parseUserDataHeader(userData) : nil
    let body: String

    switch alphabet {
    case .gsm7:
      let headerOctets = header?.octetCount ?? 0
      let headerSeptets = (headerOctets * 8 + 6) / 7
      let textSeptets = userDataLength - headerSeptets
      guard textSeptets >= 0 else { throw SMSPDUError.invalidUserData }
      body = try decodeGSM7(userData, septetCount: textSeptets, bitOffset: headerSeptets * 7)
    case .ucs2:
      guard userDataLength <= userData.count else { throw SMSPDUError.invalidUserData }
      let start = header?.octetCount ?? 0
      guard start <= userDataLength else { throw SMSPDUError.invalidUserData }
      body = try decodeUCS2(Array(userData[start..<userDataLength]))
    case .eightBit:
      guard userDataLength <= userData.count else { throw SMSPDUError.invalidUserData }
      let start = header?.octetCount ?? 0
      guard start <= userDataLength else { throw SMSPDUError.invalidUserData }
      let payload = Data(userData[start..<userDataLength])
      body = String(data: payload, encoding: .isoLatin1) ?? String(decoding: payload, as: UTF8.self)
    }

    return DecodedSMSPart(
      sender: sender,
      body: body,
      receivedAt: receivedAt,
      alphabet: alphabet,
      concatenation: header?.concatenation,
      rawPDU: pdu.uppercased()
    )
  }

  private func decodeAddress(length: Int, type: UInt8, reader: inout ByteReader) throws -> String {
    let typeOfNumber = type & 0x70
    if typeOfNumber == 0x50 {
      let byteCount = (length + 1) / 2
      let encoded = try reader.bytes(byteCount, field: "字母发送方")
      let septetCount = length * 4 / 7
      return try decodeGSM7(encoded, septetCount: septetCount, bitOffset: 0)
    }

    let encoded = try reader.bytes((length + 1) / 2, field: "发送方号码")
    var digits = ""
    for byte in encoded {
      let low = byte & 0x0F
      let high = (byte >> 4) & 0x0F
      if low <= 9 { digits.append(String(low)) }
      if high <= 9 && digits.count < length { digits.append(String(high)) }
    }
    return typeOfNumber == 0x10 ? "+" + digits : digits
  }

  private func alphabet(for dcs: UInt8) throws -> SMSAlphabet {
    if dcs & 0xC0 == 0 {
      if dcs & 0x20 != 0 {
        throw SMSPDUError.unsupportedEncoding(dcs)
      }
      switch (dcs >> 2) & 0x03 {
      case 0: return .gsm7
      case 1: return .eightBit
      case 2: return .ucs2
      default: throw SMSPDUError.unsupportedEncoding(dcs)
      }
    }
    if dcs & 0xF0 == 0xF0 {
      return dcs & 0x04 == 0 ? .gsm7 : .eightBit
    }
    throw SMSPDUError.unsupportedEncoding(dcs)
  }

  private func decodeTimestamp(_ bytes: [UInt8]) throws -> Date {
    guard bytes.count == 7 else { throw SMSPDUError.invalidTimestamp }
    func decimal(_ byte: UInt8, signed: Bool = false) -> (value: Int, negative: Bool)? {
      let first = Int(byte & 0x0F)
      let second = Int((byte >> 4) & 0x0F)
      let negative = signed && first & 0x08 != 0
      let firstDigit = signed ? first & 0x07 : first
      guard firstDigit <= 9, second <= 9 else { return nil }
      return (firstDigit * 10 + second, negative)
    }

    guard
      let year = decimal(bytes[0])?.value,
      let month = decimal(bytes[1])?.value,
      let day = decimal(bytes[2])?.value,
      let hour = decimal(bytes[3])?.value,
      let minute = decimal(bytes[4])?.value,
      let second = decimal(bytes[5])?.value,
      let zone = decimal(bytes[6], signed: true)
    else { throw SMSPDUError.invalidTimestamp }

    let offset = zone.value * 15 * 60 * (zone.negative ? -1 : 1)
    guard let timeZone = TimeZone(secondsFromGMT: offset) else {
      throw SMSPDUError.invalidTimestamp
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let components = DateComponents(
      timeZone: timeZone,
      year: 2000 + year,
      month: month,
      day: day,
      hour: hour,
      minute: minute,
      second: second
    )
    guard let date = calendar.date(from: components) else { throw SMSPDUError.invalidTimestamp }
    return date
  }

  private func parseUserDataHeader(_ bytes: [UInt8]) throws -> UserDataHeader {
    guard let declaredLength = bytes.first else { throw SMSPDUError.invalidUserData }
    let totalLength = Int(declaredLength) + 1
    guard totalLength <= bytes.count else { throw SMSPDUError.invalidUserData }
    var cursor = 1
    var concatenation: SMSConcatenation?

    while cursor < totalLength {
      guard cursor + 1 < totalLength else { throw SMSPDUError.invalidUserData }
      let identifier = bytes[cursor]
      let length = Int(bytes[cursor + 1])
      cursor += 2
      guard cursor + length <= totalLength else { throw SMSPDUError.invalidUserData }
      let data = Array(bytes[cursor..<(cursor + length)])
      cursor += length

      if identifier == 0x00, data.count == 3 {
        concatenation = SMSConcatenation(
          reference: UInt16(data[0]),
          uses16BitReference: false,
          totalParts: Int(data[1]),
          sequence: Int(data[2])
        )
      } else if identifier == 0x08, data.count == 4 {
        concatenation = SMSConcatenation(
          reference: UInt16(data[0]) << 8 | UInt16(data[1]),
          uses16BitReference: true,
          totalParts: Int(data[2]),
          sequence: Int(data[3])
        )
      }
    }
    return UserDataHeader(octetCount: totalLength, concatenation: concatenation)
  }

  private func decodeUCS2(_ bytes: [UInt8]) throws -> String {
    guard bytes.count.isMultiple(of: 2) else { throw SMSPDUError.invalidUserData }
    var values: [UInt16] = []
    values.reserveCapacity(bytes.count / 2)
    for index in stride(from: 0, to: bytes.count, by: 2) {
      values.append(UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1]))
    }
    return String(decoding: values, as: UTF16.self)
  }

  private func decodeGSM7(_ bytes: [UInt8], septetCount: Int, bitOffset: Int) throws -> String {
    guard septetCount >= 0 else { throw SMSPDUError.invalidUserData }
    var result = ""
    var escaped = false

    for index in 0..<septetCount {
      let bitIndex = bitOffset + index * 7
      let byteIndex = bitIndex / 8
      let shift = bitIndex % 8
      guard byteIndex < bytes.count else { throw SMSPDUError.invalidUserData }
      var value = UInt16(bytes[byteIndex]) >> shift
      if shift > 1, byteIndex + 1 < bytes.count {
        value |= UInt16(bytes[byteIndex + 1]) << (8 - shift)
      }
      let septet = UInt8(value & 0x7F)

      if escaped {
        result.append(Self.gsm7Extension[septet] ?? "�")
        escaped = false
      } else if septet == 0x1B {
        escaped = true
      } else {
        result.append(Self.gsm7Default[Int(septet)])
      }
    }
    if escaped { result.append("�") }
    return result
  }

  static func hexBytes(_ value: String) throws -> [UInt8] {
    let compact = value.filter { !$0.isWhitespace }
    guard compact.count.isMultiple(of: 2), !compact.isEmpty else { throw SMSPDUError.invalidHex }
    var output: [UInt8] = []
    output.reserveCapacity(compact.count / 2)
    var cursor = compact.startIndex
    while cursor < compact.endIndex {
      let next = compact.index(cursor, offsetBy: 2)
      guard let byte = UInt8(compact[cursor..<next], radix: 16) else {
        throw SMSPDUError.invalidHex
      }
      output.append(byte)
      cursor = next
    }
    return output
  }

  private static let gsm7Default: [Character] = Array(
    "@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞ\u{001B}ÆæßÉ !\"#¤%&'()*+,-./0123456789:;<=>?¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà"
  )

  private static let gsm7Extension: [UInt8: Character] = [
    0x0A: "\u{000C}",
    0x14: "^",
    0x28: "{",
    0x29: "}",
    0x2F: "\\",
    0x3C: "[",
    0x3D: "~",
    0x3E: "]",
    0x40: "|",
    0x65: "€",
  ]
}

private struct UserDataHeader {
  let octetCount: Int
  let concatenation: SMSConcatenation?
}

private struct ByteReader {
  let bytes: [UInt8]
  var position = 0

  mutating func byte(field: String) throws -> UInt8 {
    guard position < bytes.count else { throw SMSPDUError.truncated(field) }
    defer { position += 1 }
    return bytes[position]
  }

  mutating func bytes(_ count: Int, field: String) throws -> [UInt8] {
    guard count >= 0, position + count <= bytes.count else { throw SMSPDUError.truncated(field) }
    defer { position += count }
    return Array(bytes[position..<(position + count)])
  }

  mutating func skip(_ count: Int, field: String) throws {
    _ = try bytes(count, field: field)
  }

  func remainingBytes() -> [UInt8] {
    Array(bytes[position...])
  }
}
