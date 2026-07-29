import AppKit
import SwiftUI

struct NativeSearchField: NSViewRepresentable {
  @Binding var text: String
  let prompt: String

  func makeCoordinator() -> Coordinator {
    Coordinator(text: $text)
  }

  func makeNSView(context: Context) -> NSSearchField {
    let searchField = MessageSearchField()
    searchField.placeholderString = prompt
    searchField.controlSize = .extraLarge
    searchField.delegate = context.coordinator
    searchField.sendsSearchStringImmediately = true
    searchField.sendsWholeSearchString = false
    searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
    searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return searchField
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize,
    nsView: NSSearchField,
    context: Context
  ) -> CGSize? {
    let fittingSize = nsView.fittingSize
    return CGSize(
      width: proposal.width ?? fittingSize.width,
      height: fittingSize.height
    )
  }

  func updateNSView(_ searchField: NSSearchField, context: Context) {
    context.coordinator.text = $text
    if searchField.controlSize != .extraLarge {
      searchField.controlSize = .extraLarge
      searchField.invalidateIntrinsicContentSize()
    }
    if searchField.stringValue != text {
      searchField.stringValue = text
    }
    if searchField.placeholderString != prompt {
      searchField.placeholderString = prompt
    }
  }

  final class Coordinator: NSObject, NSSearchFieldDelegate {
    var text: Binding<String>

    init(text: Binding<String>) {
      self.text = text
    }

    func controlTextDidChange(_ notification: Notification) {
      guard let searchField = notification.object as? NSSearchField else { return }
      if text.wrappedValue != searchField.stringValue {
        text.wrappedValue = searchField.stringValue
      }
    }
  }
}

private final class MessageSearchField: NSSearchField {
  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)

    NSColor(deviceRed: 46 / 255, green: 44 / 255, blue: 45 / 255, alpha: 1).setFill()
    NSBezierPath(
      roundedRect: bounds,
      xRadius: bounds.height / 2,
      yRadius: bounds.height / 2
    ).fill()
    cell?.drawInterior(withFrame: bounds, in: self)
  }
}
