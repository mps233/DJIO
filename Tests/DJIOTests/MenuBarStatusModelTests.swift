import Combine
import Foundation
import Testing

@testable import DJIO

@MainActor
struct MenuBarStatusModelTests {
  @Test func reflectsConnectionUnreadAndRefreshState() {
    let model = MenuBarStatusModel()
    var connection = ConnectionSnapshot.disconnected
    connection.cellular = .ready
    connection.operatorName = "测试运营商"

    model.update(connection: connection)
    model.updateUnreadCount(3)
    model.updateRefreshing(true)

    #expect(model.isConnected)
    #expect(model.statusText == "测试运营商")
    #expect(model.unreadCount == 3)
    #expect(model.isRefreshing)
  }

  @Test func keepsLatestUnreadMessagePreview() {
    let model = MenuBarStatusModel()
    let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
    let message = SMSMessage(
      id: "message-1",
      sender: "10086",
      body: "您的验证码是 123456",
      receivedAt: timestamp,
      serviceCenterAt: timestamp,
      usesMacTimestamp: true,
      storage: "ME",
      modemIndex: 1,
      rawPDU: "",
      isRead: false
    )

    model.updateLatestUnreadMessage(message)

    #expect(model.latestUnreadMessage?.id == "message-1")
    #expect(model.latestUnreadMessage?.sender == "10086")
    #expect(model.latestUnreadMessage?.body == "您的验证码是 123456")
    #expect(model.latestUnreadMessage?.date == timestamp)

    model.updateLatestUnreadMessage(nil)
    #expect(model.latestUnreadMessage == nil)
  }

  @Test func publishesLatestTrafficForMenuState() {
    let model = MenuBarStatusModel()
    var publicationCount = 0
    let observation = model.objectWillChange.sink {
      publicationCount += 1
    }
    let traffic = NetworkTrafficSnapshot(
      interfaceName: "en9",
      downloadBytesPerSecond: 1_024,
      uploadBytesPerSecond: 512,
      receivedBytes: 10_000,
      sentBytes: 5_000
    )

    model.updateTraffic(traffic)

    #expect(model.trafficSnapshot() == traffic)
    #expect(publicationCount > 0)
    withExtendedLifetime(observation) {}
  }
}
