import Foundation
import Testing

@testable import DJIO

struct SMSAssemblerTests {
  @Test func doesNotCarryIncompletePartsAcrossSnapshots() {
    let assembler = SMSAssembler()
    let first = multipart(index: 1, body: "你", sequence: 1, rawPDU: "PART-1")
    let second = multipart(index: 2, body: "好", sequence: 2, rawPDU: "PART-2")

    #expect(assembler.assemble([first]).isEmpty)
    #expect(assembler.assemble([second]).isEmpty)
  }

  @Test func assemblesOutOfOrderAcrossStoragesAndIsStable() {
    let assembler = SMSAssembler()
    let first = multipart(
      storage: "SM", index: 8, body: "你", sequence: 1, rawPDU: "PART-1")
    let second = multipart(
      storage: "ME", index: 3, body: "好", sequence: 2, rawPDU: "PART-2")
    let snapshot = [second, first]

    let firstResult = assembler.assemble(snapshot)
    let secondResult = assembler.assemble(snapshot)
    #expect(firstResult == secondResult)
    #expect(firstResult.count == 1)
    #expect(firstResult.first?.decoded.body == "你好")
    #expect(Set(firstResult[0].records.map { "\($0.storage):\($0.index)" }) == ["SM:8", "ME:3"])
  }

  @Test func separatesReusedReferencesOutsideTimestampWindow() {
    let assembler = SMSAssembler(maximumTimestampSpan: 5 * 60)
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let parts = [
      multipart(index: 1, body: "旧", sequence: 1, rawPDU: "OLD-1", timestamp: start),
      multipart(index: 2, body: "信", sequence: 2, rawPDU: "OLD-2", timestamp: start),
      multipart(
        index: 3, body: "新", sequence: 1, rawPDU: "NEW-1",
        timestamp: start.addingTimeInterval(600)),
      multipart(
        index: 4, body: "信", sequence: 2, rawPDU: "NEW-2",
        timestamp: start.addingTimeInterval(600)),
    ]

    #expect(assembler.assemble(parts).map(\.decoded.body) == ["旧信", "新信"])
  }

  @Test func rejectsAmbiguousReferenceReuseInsideTimestampWindow() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let parts = [
      multipart(index: 1, body: "甲", sequence: 1, rawPDU: "A-1", timestamp: start),
      multipart(index: 2, body: "乙", sequence: 2, rawPDU: "A-2", timestamp: start),
      multipart(
        index: 3, body: "丙", sequence: 1, rawPDU: "B-1",
        timestamp: start.addingTimeInterval(30)),
    ]

    #expect(SMSAssembler().assemble(parts).isEmpty)
  }

  @Test func keepsAlphabetAndReferenceWidthSeparate() {
    let parts = [
      multipart(index: 1, body: "A", sequence: 1, rawPDU: "A", alphabet: .gsm7),
      multipart(index: 2, body: "B", sequence: 2, rawPDU: "B", alphabet: .ucs2),
      multipart(
        index: 3, body: "C", sequence: 2, rawPDU: "C", alphabet: .gsm7,
        uses16BitReference: true),
    ]

    #expect(SMSAssembler().assemble(parts).isEmpty)
  }

  @Test func mergesDuplicateSinglePartLocations() {
    let decoded = DecodedSMSPart(
      sender: "10086",
      body: "余额提醒",
      receivedAt: Date(timeIntervalSince1970: 1_700_000_000),
      alphabet: .ucs2,
      concatenation: nil,
      rawPDU: "SAME-PDU"
    )
    let parts = [
      StoredDecodedSMSPart(
        record: ModemStoredPDU(storage: "SM", index: 1, pdu: "SAME-PDU", isRead: false),
        decoded: decoded
      ),
      StoredDecodedSMSPart(
        record: ModemStoredPDU(storage: "ME", index: 4, pdu: "SAME-PDU", isRead: true),
        decoded: decoded
      ),
    ]

    let result = SMSAssembler().assemble(parts)
    #expect(result.count == 1)
    #expect(result.first?.records.count == 2)
  }

  private func multipart(
    storage: String = "SM",
    index: Int,
    body: String,
    sequence: Int,
    rawPDU: String,
    timestamp: Date = Date(timeIntervalSince1970: 1_700_000_000),
    alphabet: SMSAlphabet = .ucs2,
    uses16BitReference: Bool = false
  ) -> StoredDecodedSMSPart {
    let decoded = DecodedSMSPart(
      sender: "+8613800138000",
      body: body,
      receivedAt: timestamp,
      alphabet: alphabet,
      concatenation: SMSConcatenation(
        reference: 0xAA,
        uses16BitReference: uses16BitReference,
        totalParts: 2,
        sequence: sequence
      ),
      rawPDU: rawPDU
    )
    return StoredDecodedSMSPart(
      record: ModemStoredPDU(
        storage: storage,
        index: index,
        pdu: rawPDU,
        isRead: false
      ),
      decoded: decoded
    )
  }
}
