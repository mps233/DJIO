import Foundation

struct MenuBarMessagePreview: Equatable, Sendable {
  let id: String
  let sender: String
  let body: String
  let date: Date

  init(message: SMSMessage) {
    id = message.id
    sender = message.sender
    body = message.preview
    date = message.timelineAt
  }
}

@MainActor
final class MenuBarStatusModel: ObservableObject {
  @Published private(set) var statusText = "移动网络未连接"
  @Published private(set) var isConnected = false
  @Published private(set) var unreadCount = 0
  @Published private(set) var latestUnreadMessage: MenuBarMessagePreview?
  @Published private(set) var isRefreshing = false
  @Published private(set) var traffic = NetworkTrafficSnapshot.unavailable

  func update(connection: ConnectionSnapshot) {
    let connected = connection.cellular == .ready
    let text = connected ? (connection.operatorName ?? "移动网络已连接") : "移动网络未连接"
    if isConnected != connected {
      isConnected = connected
    }
    if statusText != text {
      statusText = text
    }
  }

  func updateUnreadCount(_ count: Int) {
    if unreadCount != count {
      unreadCount = count
    }
  }

  func updateLatestUnreadMessage(_ message: SMSMessage?) {
    let preview = message.map(MenuBarMessagePreview.init)
    if latestUnreadMessage != preview {
      latestUnreadMessage = preview
    }
  }

  func updateRefreshing(_ refreshing: Bool) {
    if isRefreshing != refreshing {
      isRefreshing = refreshing
    }
  }

  func updateTraffic(_ traffic: NetworkTrafficSnapshot) {
    if self.traffic != traffic {
      self.traffic = traffic
    }
  }

  func trafficSnapshot() -> NetworkTrafficSnapshot {
    traffic
  }
}
