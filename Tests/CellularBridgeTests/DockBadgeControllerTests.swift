import Testing

@testable import CellularBridge

@MainActor
struct DockBadgeControllerTests {
  @Test func displaysPositiveUnreadCountAndClearsAtZero() {
    var labels: [String?] = []
    let controller = DockBadgeController { labels.append($0) }

    controller.updateUnreadCount(3)
    controller.updateUnreadCount(0)

    #expect(labels.count == 2)
    #expect(labels[0] == "3")
    #expect(labels[1] == nil)
  }

  @Test func clearsBadgeForNegativeDefensiveInput() {
    var label: String? = "existing"
    let controller = DockBadgeController { label = $0 }

    controller.updateUnreadCount(-1)

    #expect(label == nil)
  }
}
