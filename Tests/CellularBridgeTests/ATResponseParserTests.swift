import Testing

@testable import CellularBridge

struct ATResponseParserTests {
  @Test func parsesSentMessageReference() {
    let response = "\r\n+CMGS: 42\r\n\r\nOK\r\n"

    #expect(ATResponseParser().sentMessageReference(from: response) == 42)
    #expect(ATResponseParser().sentMessageReference(from: "\r\nOK\r\n") == nil)
  }

  private let parser = ATResponseParser()

  @Test func parsesCMGLRecordsAndKeepsIndexes() {
    let response = """
      AT+CMGL=4\r\n
      +CMGL: 7,0,,20\r\n
      000404912143000842101021436500044F60597D\r\n
      +CMGL: 11,1,,20\r\n
      00040481214300004210102143650005C82293F904\r\n
      OK\r\n
      """

    let records = parser.storedPDUs(from: response, storage: "ME")
    #expect(records.count == 2)
    #expect(records.map(\.index) == [7, 11])
    #expect(records.map(\.isRead) == [false, true])
    #expect(records.allSatisfy { $0.storage == "ME" })
  }

  @Test func parsesTextualCMGLStatuses() {
    let response = """
      +CMGL: 2,"REC UNREAD",,20\r\n
      000404912143000842101021436500044F60597D\r\n
      +CMGL: 3,"REC READ",,20\r\n
      00040481214300004210102143650005C82293F904\r\n
      OK\r\n
      """

    #expect(parser.storedPDUs(from: response, storage: "SM").map(\.isRead) == [false, true])
  }

  @Test func parsesIndexedCMGRRecord() {
    let response = """
      +CMGR: 0,,20\r\n
      000404912143000842101021436500044F60597D\r\n
      OK\r\n
      """

    let record = parser.storedPDU(from: response, storage: "ME", index: 17)

    #expect(record?.storage == "ME")
    #expect(record?.index == 17)
    #expect(record?.pdu == "000404912143000842101021436500044F60597D")
    #expect(record?.isRead == false)
  }

  @Test func parsesSignalAndRegistration() {
    #expect(parser.signalRSSI(from: "\r\n+CSQ: 20,99\r\nOK\r\n") == -73)
    #expect(parser.signalRSSI(from: "+CSQ: 99,99\r\nOK") == nil)
    #expect(parser.registration(from: "+CEREG: 0,1\r\nOK") == "已注册")
    #expect(parser.registration(from: "+CEREG: 0,5\r\nOK") == "漫游")
    #expect(parser.registration(from: "+CEREG: 2,1,\"01AB\",\"00112233\",7\r\nOK") == "已注册")
    #expect(parser.operatorName(from: "+COPS: 0,0,\"中国移动\",7\r\nOK") == "中国移动")
  }
}
