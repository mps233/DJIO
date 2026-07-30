import Foundation
import Testing

@testable import DJIO

struct SMSPDUDecoderTests {
  private let decoder = SMSPDUDecoder()

  @Test func decodesUCS2DeliverPDU() throws {
    let message = try decoder.decode("000404912143000842101021436500044F60597D")

    #expect(message.sender == "+1234")
    #expect(message.body == "你好")
    #expect(message.alphabet == .ucs2)
    #expect(message.concatenation == nil)
    #expect(message.receivedAt == timestamp())
  }

  @Test func decodesGSM7DeliverPDU() throws {
    let message = try decoder.decode("00040481214300004210102143650005C82293F904")

    #expect(message.sender == "1234")
    #expect(message.body == "HELLO")
    #expect(message.alphabet == .gsm7)
  }

  @Test func decodesAndReassemblesUCS2Parts() throws {
    let first = try decoder.decode("00440491214300084210102143650008050003AA02014F60")
    let second = try decoder.decode("00440491214300084210102143650008050003AA0202597D")
    let assembler = SMSAssembler()

    let completed = assembler.assemble([
      StoredDecodedSMSPart(
        record: ModemStoredPDU(storage: "SM", index: 3, pdu: first.rawPDU, isRead: false),
        decoded: first
      ),
      StoredDecodedSMSPart(
        record: ModemStoredPDU(storage: "SM", index: 4, pdu: second.rawPDU, isRead: false),
        decoded: second
      ),
    ])
    #expect(completed.first?.decoded.body == "你好")
    #expect(completed.first?.decoded.concatenation == nil)
    #expect(completed.first?.records.map(\.index) == [3, 4])
  }

  @Test func rejectsTruncatedPDU() {
    #expect(throws: SMSPDUError.self) {
      try decoder.decode("00040491")
    }
  }

  private func timestamp() -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar.date(
      from: DateComponents(
        timeZone: calendar.timeZone,
        year: 2024,
        month: 1,
        day: 1,
        hour: 12,
        minute: 34,
        second: 56
      ))!
  }
}
