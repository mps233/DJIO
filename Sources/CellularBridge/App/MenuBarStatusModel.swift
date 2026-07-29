import Foundation

@MainActor
final class MenuBarStatusModel: ObservableObject {
  @Published private(set) var statusText = "移动网络未连接"
  @Published private(set) var isConnected = false
  @Published private(set) var unreadCount = 0
  @Published private(set) var isRefreshing = false

  private var latestTraffic = NetworkTrafficSnapshot.unavailable

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

  func updateRefreshing(_ refreshing: Bool) {
    if isRefreshing != refreshing {
      isRefreshing = refreshing
    }
  }

  func updateTraffic(_ traffic: NetworkTrafficSnapshot) {
    latestTraffic = traffic
  }

  func trafficSnapshot() -> NetworkTrafficSnapshot {
    latestTraffic
  }
}
