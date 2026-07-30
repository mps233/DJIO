import Testing

@testable import DJIO

struct CellularDetailsParserTests {
  private let parser = ATResponseParser()

  @Test func parsesSIMFirmwareStorageAndOperatorTechnology() {
    #expect(parser.operatorAccessTechnology(from: "+COPS: 0,0,\"中国移动\",7\r\nOK") == "LTE")
    #expect(parser.simStatus(from: "+CPIN: READY\r\nOK") == "就绪")
    #expect(parser.simStatus(from: "+CPIN: SIM PIN\r\nOK") == "需要 SIM PIN")
    #expect(
      parser.firmwareRevision(from: "AT+CGMR\r\nEG25GGBR07A08M2G\r\nOK") == "EG25GGBR07A08M2G")
    #expect(parser.firmwareRevision(from: "+CGMR: EC25EFAR06A12M4G\r\nOK") == "EC25EFAR06A12M4G")
    #expect(
      parser.smsStorageUsage(from: "+CPMS: 3,50,3,50,3,50\r\nOK", storage: "SM")
        == SMSStorageUsage(storage: "SM", used: 3, total: 50))
    #expect(
      parser.smsStorageUsage(
        from: "+CPMS: \"SM\",3,50,\"ME\",7,255,\"ME\",7,255\r\nOK",
        storage: "ME"
      ) == SMSStorageUsage(storage: "ME", used: 7, total: 255))
    #expect(parser.smsStorageUsage(from: "+CPMS: 51,50\r\nOK", storage: "SM") == nil)
  }

  @Test func parsesQuectelNetworkAndServingCellDetails() {
    let network = parser.networkInformation(
      from: "+QNWINFO: \"FDD LTE\",\"46000\",\"LTE BAND 3\",1300\r\nOK")
    #expect(network.accessTechnology == "FDD LTE")
    #expect(network.frequencyBand == "LTE BAND 3")
    #expect(network.channel == 1300)

    let servingCell = parser.servingCellDetails(
      from:
        "+QENG: \"servingcell\",\"NOCONN\",\"LTE\",\"FDD\",460,00,5F1EA01,383,1650,3,5,5,3A7D,-94,-10,-67,11,13\r\nOK"
    )
    #expect(servingCell.accessTechnology == "LTE")
    #expect(servingCell.frequencyBand == "LTE Band 3")
    #expect(servingCell.channel == 1650)
    #expect(servingCell.signalRSRP == -94)
    #expect(servingCell.signalRSRQ == -10)
    #expect(servingCell.signalSINR == 11)
  }
}
