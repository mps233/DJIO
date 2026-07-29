import SwiftUI

struct RefreshToolbarActions: ToolbarContent {
  let isRefreshing: Bool
  let refreshHelp: String
  let refresh: () -> Void
  let secondarySystemImage: String
  let secondaryHelp: String
  let isSecondaryDisabled: Bool
  let secondaryAction: () -> Void

  var body: some ToolbarContent {
    ToolbarItemGroup {
      Button(action: refresh) {
        Group {
          if isRefreshing {
            ProgressView()
              .controlSize(.small)
          } else {
            Image(systemName: "arrow.clockwise")
          }
        }
        .frame(width: 16, height: 16)
      }
      .disabled(isRefreshing)
      .help(refreshHelp)
      .accessibilityLabel(refreshHelp)

      Button(action: secondaryAction) {
        Image(systemName: secondarySystemImage)
      }
      .disabled(isSecondaryDisabled)
      .help(secondaryHelp)
      .accessibilityLabel(secondaryHelp)
    }
  }
}
