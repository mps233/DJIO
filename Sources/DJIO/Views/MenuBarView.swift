import AppKit
import SwiftUI

struct MenuBarView: View {
  @Environment(\.openWindow) private var openWindow
  @ObservedObject var status: MenuBarStatusModel
  let trafficProvider: @MainActor () -> NetworkTrafficSnapshot
  let refresh: @MainActor () -> Void
  let quit: @MainActor () -> Void

  @State private var traffic = NetworkTrafficSnapshot.unavailable

  var body: some View {
    VStack(alignment: .leading) {
      Label(
        status.statusText,
        systemImage: status.isConnected
          ? "antenna.radiowaves.left.and.right" : "exclamationmark.triangle"
      )
      if status.unreadCount > 0 {
        Text("\(status.unreadCount) 条未读短信")
          .foregroundStyle(.secondary)
      }
      if traffic.interfaceName != nil {
        HStack(spacing: 12) {
          Label(
            NetworkTrafficFormatter.rate(traffic.downloadBytesPerSecond),
            systemImage: "arrow.down")
          Label(
            NetworkTrafficFormatter.rate(traffic.uploadBytesPerSecond),
            systemImage: "arrow.up")
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
      }
      Divider()
      Button("打开 DJIO") {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
      }
      Button("检查新短信") {
        refresh()
      }
      .disabled(status.isRefreshing)
      Divider()
      Button("退出") {
        quit()
      }
      .keyboardShortcut("q")
    }
    .frame(width: 230)
    .padding(12)
    .onAppear {
      let snapshot = trafficProvider()
      DispatchQueue.main.async {
        traffic = snapshot
      }
    }
  }
}
