import AppKit
import SwiftUI

struct MenuBarView: View {
  @Environment(\.openWindow) private var openWindow
  @ObservedObject var status: MenuBarStatusModel
  let refresh: @MainActor () -> Void
  let openMessage: @MainActor (String) -> Void
  let quit: @MainActor () -> Void

  @State private var hoveredMenuRow: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      connectionHeader

      if let latestUnreadMessage = status.latestUnreadMessage {
        latestMessageCard(latestUnreadMessage)
      }

      if status.traffic.interfaceName != nil {
        trafficCard
      }

      VStack(spacing: 0) {
        Divider()

        menuRow(title: "打开 DJIO", shortcut: "⌘M") {
          openWindow(id: "main")
          NSApp.activate(ignoringOtherApps: true)
        }

        Divider()

        menuRow(title: "检查新短信", shortcut: "⌘R") {
          refresh()
        }
        .disabled(status.isRefreshing)

        Divider()

        menuRow(title: "退出", shortcut: "⌘Q") {
          quit()
        }
      }
      .frame(maxWidth: .infinity)
    }
    .frame(width: 270)
    .padding(.top, 12)
    .padding(.horizontal, 12)
    .padding(.bottom, 2)
  }

  private func menuRow(
    title: String,
    shortcut: String?,
    systemImage: String? = nil,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 8) {
        if let systemImage {
          Image(systemName: systemImage)
            .frame(width: 18)
        }

        Text(title)

        Spacer(minLength: 12)

        if let shortcut {
          Text(shortcut)
            .foregroundStyle(
              hoveredMenuRow == title ? .white.opacity(0.95) : .secondary
            )
            .font(.body.monospacedDigit())
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .foregroundStyle(hoveredMenuRow == title ? .white : .primary)
      .background(
        hoveredMenuRow == title
          ? Color.accentColor
          : Color.clear,
        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
      )
      .contentShape(Rectangle())
      .padding(.vertical, 3)
    }
    .buttonStyle(.plain)
    .keyboardShortcut(shortcutKeyEquivalent(for: shortcut), modifiers: .command)
    .onHover { isHovered in
      hoveredMenuRow = isHovered ? title : nil
    }
  }

  private func shortcutKeyEquivalent(for shortcut: String?) -> KeyEquivalent {
    switch shortcut {
    case "⌘M": return "m"
    case "⌘R": return "r"
    default: return "q"
    }
  }

  private var connectionHeader: some View {
    HStack(spacing: 10) {
      Image(
        systemName: status.isConnected
          ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash"
      )
      .font(.title3.weight(.semibold))
      .foregroundStyle(status.isConnected ? .green : .orange)
      .frame(width: 32, height: 32)
      .background(.quaternary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

      VStack(alignment: .leading, spacing: 2) {
        Text("DJIO")
          .font(.headline)
        Text(status.statusText)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer(minLength: 8)

      if status.unreadCount > 0 {
        Text("\(status.unreadCount)")
          .font(.caption.weight(.semibold).monospacedDigit())
          .foregroundStyle(.white)
          .padding(.horizontal, 7)
          .padding(.vertical, 4)
          .background(.tint, in: Capsule())
          .accessibilityLabel("未读短信 \(status.unreadCount) 条")
      }
    }
  }

  private func latestMessageCard(_ message: MenuBarMessagePreview) -> some View {
    Button {
      openWindow(id: "main")
      NSApp.activate(ignoringOtherApps: true)
      openMessage(message.id)
    } label: {
      VStack(alignment: .leading, spacing: 7) {
        HStack(spacing: 6) {
          Label("最新未读短信", systemImage: "message.badge.fill")
            .font(.caption.weight(.semibold))
          Spacer(minLength: 8)
          Text(MessageTimestampFormatter.string(for: message.date))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }

        Text(message.sender)
          .font(.subheadline.weight(.semibold))
          .lineLimit(1)

        Text(message.body)
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .multilineTextAlignment(.leading)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(11)
      .background(.quaternary, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityLabel("打开最新未读短信")
    .accessibilityValue("来自 \(message.sender)：\(message.body)")
  }

  private var trafficCard: some View {
    let traffic = status.traffic

    return VStack(alignment: .leading, spacing: 8) {
      Text("流量")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)

      HStack(spacing: 0) {
        trafficMetric(
          title: "下载",
          value: NetworkTrafficFormatter.rate(traffic.downloadBytesPerSecond),
          systemImage: "arrow.down"
        )
        Divider()
          .frame(height: 24)
          .padding(.horizontal, 10)
        trafficMetric(
          title: "上传",
          value: NetworkTrafficFormatter.rate(traffic.uploadBytesPerSecond),
          systemImage: "arrow.up"
        )
      }

      if let interfaceName = traffic.interfaceName {
        Text(interfaceName)
          .font(.caption2.monospaced())
          .foregroundStyle(.tertiary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(11)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
  }

  private func trafficMetric(title: String, value: String, systemImage: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Label(title, systemImage: systemImage)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.caption.monospacedDigit().weight(.medium))
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
