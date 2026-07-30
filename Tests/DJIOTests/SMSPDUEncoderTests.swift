import Testing

@testable import DJIO

struct SMSPDUEncoderTests {
  @Test func encodesGSM7SubmitPDUAndNormalizesInternationalRecipient() throws {
    let part = try encoder().encode(recipient: "+86 (138) 0013-8000", body: "HELLO").first!

    #expect(part.recipient == "+8613800138000")
    #expect(part.pdu == "0001000D91683108108300F0000005C82293F904")
    #expect(part.tpduLength == 19)
    #expect(part.alphabet == .gsm7)
    #expect(part.sequence == 1)
    #expect(part.totalParts == 1)
    #expect(part.concatenationReference == nil)
    #expect(part.pdu == part.pdu.uppercased())
  }

  @Test func encodesShortCodeAsNationalAddress() throws {
    let part = try encoder().encode(recipient: "10086", body: "A").first!
    let bytes = try SMSPDUDecoder.hexBytes(part.pdu)

    #expect(part.recipient == "10086")
    #expect(Array(bytes[3...7]) == [0x05, 0x81, 0x01, 0x80, 0xF6])
  }

  @Test func normalizesDoubleZeroInternationalPrefix() throws {
    let part = try encoder().encode(recipient: "0086 13800138000", body: "A").first!

    #expect(part.recipient == "+8613800138000")
  }

  @Test func keeps160GSM7SeptetsInOnePart() throws {
    let parts = try encoder().encode(recipient: "10086", body: String(repeating: "A", count: 160))

    #expect(parts.count == 1)
    #expect(parts[0].alphabet == .gsm7)
    #expect(userDataLength(parts[0]) == 160)
  }

  @Test func splits161GSM7SeptetsAt153AndUsesInjectedReference() throws {
    let parts = try encoder(reference: 0xA7).encode(
      recipient: "10086",
      body: String(repeating: "A", count: 161)
    )

    #expect(parts.count == 2)
    #expect(parts.map(\.sequence) == [1, 2])
    #expect(parts.allSatisfy { $0.totalParts == 2 })
    #expect(parts.allSatisfy { $0.concatenationReference == 0xA7 })
    #expect(parts.allSatisfy { $0.tpduLength == $0.pdu.count / 2 - 1 })
    #expect(parts.map(userDataLength) == [160, 15])
    #expect(userDataHeader(parts[0]) == [0x05, 0x00, 0x03, 0xA7, 0x02, 0x01])
    #expect(userDataHeader(parts[1]) == [0x05, 0x00, 0x03, 0xA7, 0x02, 0x02])
  }

  @Test func usesGSM7ExtensionTableWithoutSplittingEscapeSequence() throws {
    let single = try encoder().encode(
      recipient: "10086",
      body: String(repeating: "^", count: 80)
    )
    let multipart = try encoder(reference: 0x21).encode(
      recipient: "10086",
      body: String(repeating: "^", count: 81)
    )

    #expect(single.count == 1)
    #expect(single[0].alphabet == .gsm7)
    #expect(userDataLength(single[0]) == 160)
    #expect(multipart.count == 2)
    #expect(multipart.map(userDataLength) == [159, 17])
    #expect(unpackedGSM7Payload(multipart[0]).count == 152)
    #expect(unpackedGSM7Payload(multipart[0]).last == 0x14)
    #expect(unpackedGSM7Payload(multipart[1]).first == 0x1B)
  }

  @Test func keeps70UCS2CodeUnitsInOnePartAndSplits71() throws {
    let single = try encoder().encode(
      recipient: "10086",
      body: String(repeating: "你", count: 70)
    )
    let multipart = try encoder(reference: 0x43).encode(
      recipient: "10086",
      body: String(repeating: "你", count: 71)
    )

    #expect(single.count == 1)
    #expect(single[0].alphabet == .ucs2)
    #expect(userDataLength(single[0]) == 140)
    #expect(multipart.count == 2)
    #expect(multipart.map(userDataLength) == [140, 14])
    #expect(decodeUCS2Payload(multipart[0]) == String(repeating: "你", count: 67))
    #expect(decodeUCS2Payload(multipart[1]) == String(repeating: "你", count: 4))
  }

  @Test func doesNotSplitEmojiSurrogatePair() throws {
    let body = String(repeating: "😀", count: 36)
    let parts = try encoder(reference: 0x55).encode(recipient: "+1234", body: body)

    #expect(parts.count == 2)
    #expect(parts.map(userDataLength) == [138, 18])
    #expect(parts.map(decodeUCS2Payload).joined() == body)
    #expect(decodeUCS2Payload(parts[0]) == String(repeating: "😀", count: 33))
  }

  @Test func choosesUCS2ForCharactersOutsideGSM7() throws {
    let unicode = try encoder().encode(recipient: "10086", body: "你好🙂")
    let escapeControl = try encoder().encode(recipient: "10086", body: "A\u{001B}B")

    #expect(unicode.count == 1)
    #expect(unicode[0].alphabet == .ucs2)
    #expect(decodeUCS2Payload(unicode[0]) == "你好🙂")
    #expect(escapeControl[0].alphabet == .ucs2)
    #expect(decodeUCS2Payload(escapeControl[0]) == "A\u{001B}B")
  }

  @Test(arguments: ["", "   "])
  func rejectsEmptyRecipient(_ recipient: String) {
    #expect(throws: SMSPDUEncodingError.emptyRecipient) {
      try encoder().encode(recipient: recipient, body: "hello")
    }
  }

  @Test(arguments: ["+", "12A34", "12+34", "１２３４", "123/45"])
  func rejectsInvalidRecipient(_ recipient: String) {
    #expect(throws: SMSPDUEncodingError.invalidRecipient) {
      try encoder().encode(recipient: recipient, body: "hello")
    }
  }

  @Test func rejectsRecipientLongerThan20Digits() {
    #expect(throws: SMSPDUEncodingError.recipientTooLong(maximumDigits: 20)) {
      try encoder().encode(recipient: String(repeating: "1", count: 21), body: "hello")
    }
  }

  @Test func rejectsEmptyMessage() {
    #expect(throws: SMSPDUEncodingError.emptyMessage) {
      try encoder().encode(recipient: "10086", body: "")
    }
  }

  @Test func rejectsMoreThan255Parts() {
    #expect(throws: SMSPDUEncodingError.messageTooLong(maximumParts: 255)) {
      try encoder().encode(
        recipient: "10086",
        body: String(repeating: "你", count: 67 * 255 + 1)
      )
    }
  }

  private func encoder(reference: UInt8 = 0x12) -> SMSPDUEncoder {
    SMSPDUEncoder(concatenationReferenceProvider: { reference })
  }

  private func bytes(_ part: EncodedSMSPart) -> [UInt8] {
    try! SMSPDUDecoder.hexBytes(part.pdu)
  }

  private func addressByteCount(_ bytes: [UInt8]) -> Int {
    (Int(bytes[3]) + 1) / 2
  }

  private func userDataLengthIndex(_ part: EncodedSMSPart) -> Int {
    let pdu = bytes(part)
    return 1 + 4 + addressByteCount(pdu) + 2
  }

  private func userDataLength(_ part: EncodedSMSPart) -> Int {
    let pdu = bytes(part)
    return Int(pdu[userDataLengthIndex(part)])
  }

  private func userData(_ part: EncodedSMSPart) -> [UInt8] {
    let pdu = bytes(part)
    return Array(pdu[(userDataLengthIndex(part) + 1)...])
  }

  private func userDataHeader(_ part: EncodedSMSPart) -> [UInt8] {
    Array(userData(part).prefix(6))
  }

  private func unpackedGSM7Payload(_ part: EncodedSMSPart) -> [UInt8] {
    let data = userData(part)
    let headerSeptets = 7
    let count = userDataLength(part) - headerSeptets
    return (0..<count).map { index in
      let bitIndex = headerSeptets * 7 + index * 7
      let byteIndex = bitIndex / 8
      let shift = bitIndex % 8
      var value = UInt16(data[byteIndex]) >> shift
      if shift > 1, byteIndex + 1 < data.count {
        value |= UInt16(data[byteIndex + 1]) << (8 - shift)
      }
      return UInt8(value & 0x7F)
    }
  }

  private func decodeUCS2Payload(_ part: EncodedSMSPart) -> String {
    let hasHeader = part.totalParts > 1
    let payload = hasHeader ? Array(userData(part).dropFirst(6)) : userData(part)
    let values = stride(from: 0, to: payload.count, by: 2).map {
      UInt16(payload[$0]) << 8 | UInt16(payload[$0 + 1])
    }
    return String(decoding: values, as: UTF16.self)
  }
}
