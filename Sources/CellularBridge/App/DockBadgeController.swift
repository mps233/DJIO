import AppKit

@MainActor
final class DockBadgeController {
  private let applyLabel: @MainActor (String?) -> Void

  init(
    applyLabel: @escaping @MainActor (String?) -> Void = { label in
      NSApplication.shared.dockTile.badgeLabel = label
    }
  ) {
    self.applyLabel = applyLabel
  }

  func updateUnreadCount(_ count: Int) {
    applyLabel(count > 0 ? String(count) : nil)
  }
}
