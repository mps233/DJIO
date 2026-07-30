import Combine
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

  @Test func retainsTrafficWithoutPublishingItAsMenuState() {
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
    #expect(publicationCount == 0)
    withExtendedLifetime(observation) {}
  }
}
