import SwiftUI

struct RootView: View {
  @EnvironmentObject private var model: AppModel
  @State private var columnVisibility: NavigationSplitViewVisibility = .all

  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      List(selection: $model.selection) {
        Section {
          ForEach(NavigationDestination.allCases) { destination in
            Label {
              HStack {
                Text(destination.title)
                Spacer()
                if destination == .messages, model.unreadCount > 0 {
                  Text("\(model.unreadCount)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .frame(minHeight: 18)
                    .background(.red, in: Capsule())
                }
              }
            } icon: {
              Image(systemName: destination.systemImage)
            }
            .tag(destination)
          }
        }

        Section("当前链路") {
          SidebarStatusRow(label: "ECM", condition: model.connection.ecm)
          SidebarStatusRow(label: "短信", condition: model.connection.control)
        }
      }
      .listStyle(.sidebar)
      .navigationTitle("蜂窝桥")
      .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 245)
      .safeAreaInset(edge: .bottom) {
        if model.isDemoMode {
          Label("演示模式", systemImage: "play.rectangle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.vertical, 10)
        }
      }
    } detail: {
      switch model.selection ?? .connection {
      case .connection:
        ConnectionView()
      case .messages:
        MessagesView()
      }
    }
    .navigationSplitViewStyle(.balanced)
  }
}

private struct SidebarStatusRow: View {
  let label: String
  let condition: LinkCondition

  var body: some View {
    HStack {
      Text(label)
      Spacer()
      Circle()
        .fill(condition.color)
        .frame(width: 7, height: 7)
        .accessibilityLabel(condition.label)
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }
}

extension LinkCondition {
  var color: Color {
    switch self {
    case .ready: return .green
    case .checking: return .blue
    case .warning: return .orange
    case .unavailable: return .secondary.opacity(0.45)
    }
  }
}
