import AppKit
import SwiftUI

struct RootView: View {
  @EnvironmentObject private var model: AppModel
  @State private var connectionColumnVisibility: NavigationSplitViewVisibility = .all

  var body: some View {
    Group {
      switch model.selection ?? .connection {
      case .connection:
        NavigationSplitView(columnVisibility: $connectionColumnVisibility) {
          AppSidebar()
        } detail: {
          ConnectionView()
        }
        .navigationSplitViewStyle(.balanced)
      case .esim:
        NavigationSplitView(columnVisibility: $connectionColumnVisibility) {
          AppSidebar()
        } detail: {
          EuiccView()
        }
        .navigationSplitViewStyle(.balanced)
      case .messages:
        MessagesView()
      case .calls:
        IncomingCallsView()
      }
    }
    .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
    .toolbarBackground(.hidden, for: .windowToolbar)
  }
}

struct AppSidebar: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
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
        SidebarStatusRow(
          label: "eSIM",
          condition: model.euicc.available ? .ready : (model.euicc.issue == nil ? .unavailable : .warning)
        )
      }
    }
    .listStyle(.sidebar)
    .navigationTitle("DJIO")
    .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 245)
    .safeAreaInset(edge: .bottom) {
      HStack {
        if model.isDemoMode {
          Label("演示模式", systemImage: "play.rectangle")
        } else {
          Text("DJIO · v\(appVersion)")
        }
        Spacer()
      }
      .font(.caption)
      .foregroundStyle(.tertiary)
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
    }
  }

  private var appVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.4"
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
