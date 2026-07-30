import SwiftUI

struct IncomingCallsView: View {
  @EnvironmentObject private var model: AppModel
  @State private var columnVisibility: NavigationSplitViewVisibility = .all

  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      AppSidebar()
    } detail: {
      Group {
        if model.incomingCalls.isEmpty {
          ContentUnavailableView("暂无来电记录", systemImage: "phone")
        } else {
          List(model.incomingCalls) { call in
            IncomingCallRow(call: call)
          }
          .listStyle(.inset)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .navigationTitle("来电")
    }
    .navigationSplitViewStyle(.balanced)
  }
}

private struct IncomingCallRow: View {
  let call: IncomingCallRecord

  private var caller: String {
    guard let callerNumber = call.callerNumber, !callerNumber.isEmpty else {
      return "未知号码"
    }
    return SMSAddressDisplayFormatter.string(for: callerNumber)
  }

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "phone.arrow.down.left")
        .font(.body.weight(.medium))
        .foregroundStyle(.green)
        .frame(width: 24)

      VStack(alignment: .leading, spacing: 3) {
        Text(caller)
          .font(.body.weight(.medium))
          .lineLimit(1)
        Text(call.receivedAt.formatted(date: .abbreviated, time: .shortened))
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .padding(.vertical, 5)
  }
}
