import AppKit
import QuartzCore
import SwiftUI

@MainActor
final class IncomingCallPanelController {
  private enum Layout {
    static let size = NSSize(width: 344, height: 108)
    static let screenInset: CGFloat = 14
    static let entranceOffset: CGFloat = 12
  }

  private var panel: NSPanel?
  private var currentCallID: String?

  func present(
    call: IncomingCallRecord,
    viewAction: @escaping () -> Void,
    messageAction: @escaping () -> Void,
    hangUpAction: @escaping @MainActor () async -> Bool
  ) {
    let isNewCall = currentCallID != call.id
    currentCallID = call.id

    let content = IncomingCallPanelView(
      call: call,
      viewAction: { [weak self] in
        self?.dismiss()
        viewAction()
      },
      messageAction: { [weak self] in
        self?.dismiss()
        messageAction()
      },
      hangUpAction: hangUpAction
    )

    let panel = panel ?? makePanel()
    panel.contentView = NSHostingView(rootView: content)
    self.panel = panel

    let destination = panelFrame()
    if panel.isVisible {
      panel.setFrame(destination, display: true)
    } else {
      panel.alphaValue = 0
      panel.setFrame(
        destination.offsetBy(dx: 0, dy: Layout.entranceOffset),
        display: false
      )
      panel.orderFrontRegardless()
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.24
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        panel.animator().alphaValue = 1
        panel.animator().setFrame(destination, display: true)
      }
    }

    if isNewCall {
      NSSound.beep()
    }
  }

  func dismiss(animated: Bool = true) {
    currentCallID = nil
    guard let panel, panel.isVisible else { return }
    guard animated else {
      panel.orderOut(nil)
      panel.alphaValue = 1
      return
    }

    let destination = panel.frame.offsetBy(dx: 0, dy: Layout.entranceOffset)
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.18
      context.timingFunction = CAMediaTimingFunction(name: .easeIn)
      panel.animator().alphaValue = 0
      panel.animator().setFrame(destination, display: true)
    } completionHandler: {
      panel.orderOut(nil)
      panel.alphaValue = 1
    }
  }

  private func makePanel() -> NSPanel {
    let panel = NSPanel(
      contentRect: NSRect(origin: .zero, size: Layout.size),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.hidesOnDeactivate = false
    panel.isMovableByWindowBackground = true
    panel.isReleasedWhenClosed = false
    panel.animationBehavior = .none
    return panel
  }

  private func panelFrame() -> NSRect {
    let screen =
      NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
      ?? NSScreen.main
    let visibleFrame = screen?.visibleFrame ?? .zero
    return NSRect(
      x: visibleFrame.maxX - Layout.size.width - Layout.screenInset,
      y: visibleFrame.maxY - Layout.size.height - Layout.screenInset,
      width: Layout.size.width,
      height: Layout.size.height
    )
  }
}

private struct IncomingCallPanelView: View {
  let call: IncomingCallRecord
  let viewAction: () -> Void
  let messageAction: () -> Void
  let hangUpAction: @MainActor () async -> Bool
  @State private var isHangingUp = false

  private var caller: String {
    guard let number = call.callerNumber, !number.isEmpty else {
      return "未知号码"
    }
    return SMSAddressDisplayFormatter.string(for: number)
  }

  private var canMessageCaller: Bool {
    guard let number = call.callerNumber else { return false }
    return !number.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    VStack(spacing: 8) {
      HStack(spacing: 10) {
        ZStack {
          Circle()
            .fill(
              LinearGradient(
                colors: [
                  Color(red: 0.30, green: 0.27, blue: 0.48),
                  Color(red: 0.12, green: 0.17, blue: 0.29),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
              )
            )
          Image(systemName: "person.fill")
            .font(.system(size: 21, weight: .semibold))
            .foregroundStyle(.white.opacity(0.94))
        }
        .frame(width: 44, height: 44)
        .overlay {
          Circle()
            .stroke(.white.opacity(0.18), lineWidth: 1)
        }
        .overlay(alignment: .bottomTrailing) {
          Image(systemName: "antenna.radiowaves.left.and.right")
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 17, height: 17)
            .background(.black.opacity(0.72), in: Circle())
            .overlay {
              Circle()
                .stroke(.white.opacity(0.28), lineWidth: 1)
            }
        }

        VStack(alignment: .leading, spacing: 4) {
          Text(caller)
            .font(.system(size: 16, weight: .semibold))
            .lineLimit(1)
          Text("来自蜂窝模块")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }

        Spacer(minLength: 8)
        IncomingCallWaveform()
      }

      HStack(spacing: 10) {
        CallPanelButton(
          systemImage: "message.fill",
          accessibilityLabel: "给来电号码发短信",
          foreground: .white,
          background: .white.opacity(0.14),
          size: 38,
          isDisabled: !canMessageCaller,
          action: messageAction
        )
        .help(canMessageCaller ? "给来电号码发短信" : "未知号码无法发送短信")

        Spacer()

        CallPanelButton(
          systemImage: "phone.down.fill",
          accessibilityLabel: isHangingUp ? "正在挂断" : "挂断来电",
          foreground: .white,
          background: Color(red: 1.00, green: 0.27, blue: 0.29),
          size: 38,
          isLoading: isHangingUp,
          action: hangUp
        )
        .help("挂断来电")

        CallPanelButton(
          systemImage: "phone.fill",
          accessibilityLabel: "打开来电界面",
          foreground: .white,
          background: Color(red: 0.16, green: 0.84, blue: 0.37),
          size: 38,
          action: viewAction
        )
        .help("打开来电界面")
      }
      .padding(.horizontal, 4)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .frame(width: 344, height: 108)
    .modifier(IncomingCallGlassBackground())
    .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
  }

  private func hangUp() {
    guard !isHangingUp else { return }
    isHangingUp = true
    Task { @MainActor in
      let succeeded = await hangUpAction()
      if !succeeded {
        isHangingUp = false
      }
    }
  }
}

private struct IncomingCallGlassBackground: ViewModifier {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast

  private let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)

  @ViewBuilder
  func body(content: Content) -> some View {
    if reduceTransparency {
      content
        .background(Color(nsColor: .windowBackgroundColor), in: shape)
        .overlay {
          shape.stroke(
            Color(nsColor: .separatorColor).opacity(contrast == .increased ? 0.85 : 0.45),
            lineWidth: contrast == .increased ? 1.25 : 0.75
          )
        }
    } else {
      content
        .background(Color.primary.opacity(0.035), in: shape)
        .glassEffect(.regular, in: shape)
        .glassEffectTransition(.materialize)
        .overlay {
          shape.stroke(
            LinearGradient(
              colors: [
                .white.opacity(contrast == .increased ? 0.72 : 0.46),
                .white.opacity(0.08),
                .white.opacity(contrast == .increased ? 0.42 : 0.22),
              ],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            ),
            lineWidth: contrast == .increased ? 1.25 : 0.75
          )
        }
    }
  }
}

private struct CallPanelButton: View {
  let systemImage: String
  let accessibilityLabel: String
  let foreground: Color
  let background: Color
  var size: CGFloat = 54
  var isLoading = false
  var isDisabled = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Group {
        if isLoading {
          ProgressView()
            .controlSize(.small)
            .tint(foreground)
        } else {
          Image(systemName: systemImage)
            .font(.system(size: size * 0.38, weight: .semibold))
            .foregroundStyle(foreground)
        }
      }
        .frame(width: size, height: size)
        .background(background, in: Circle())
    }
    .buttonStyle(CallPanelCircleButtonStyle())
    .disabled(isLoading || isDisabled)
    .opacity(isDisabled ? 0.45 : 1)
    .contentShape(Circle())
    .accessibilityLabel(accessibilityLabel)
  }
}

private struct CallPanelCircleButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.94 : 1)
      .brightness(configuration.isPressed ? -0.08 : 0)
      .animation(.snappy(duration: 0.18), value: configuration.isPressed)
  }
}

private struct IncomingCallWaveform: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    TimelineView(.animation(minimumInterval: 0.09)) { context in
      HStack(spacing: 3) {
        ForEach(0..<7, id: \.self) { index in
          let time = context.date.timeIntervalSinceReferenceDate
          let phase = reduceMotion ? 0.5 : (sin(time * 6 + Double(index) * 0.82) + 1) / 2
          Capsule()
            .fill(
              LinearGradient(
                colors: [.yellow, .mint],
                startPoint: .bottom,
                endPoint: .top
              )
            )
            .frame(width: 2.5, height: 6 + phase * 15)
        }
      }
      .frame(width: 45, height: 24)
    }
    .accessibilityHidden(true)
  }
}
