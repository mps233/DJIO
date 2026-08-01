import AppKit
import SwiftUI
import UserNotifications

enum DJIONotificationCategory {
  static let message = "DJIO.message"
  static let incomingCall = "DJIO.incomingCall"
}

enum DJIONotificationAction {
  static let viewMessage = "DJIO.viewMessage"
  static let viewIncomingCall = "DJIO.viewIncomingCall"
  static let dismissIncomingCall = "DJIO.dismissIncomingCall"
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
  @MainActor private var notificationNavigationHandler: ((NotificationNavigationTarget) -> Void)?
  @MainActor private var pendingNotificationTarget: NotificationNavigationTarget?
  @MainActor private var terminationHandler: (() -> Void)?
  @MainActor private let incomingCallPanelController = IncomingCallPanelController()

  func applicationDidFinishLaunching(_ notification: Notification) {
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    center.setNotificationCategories([
      UNNotificationCategory(
        identifier: DJIONotificationCategory.message,
        actions: [
          UNNotificationAction(
            identifier: DJIONotificationAction.viewMessage,
            title: "查看短信",
            options: [.foreground]
          )
        ],
        intentIdentifiers: []
      ),
      UNNotificationCategory(
        identifier: DJIONotificationCategory.incomingCall,
        actions: [
          UNNotificationAction(
            identifier: DJIONotificationAction.viewIncomingCall,
            title: "查看来电",
            options: [.foreground]
          ),
          UNNotificationAction(
            identifier: DJIONotificationAction.dismissIncomingCall,
            title: "忽略",
            options: []
          ),
        ],
        intentIdentifiers: []
      ),
    ])
  }

  @MainActor
  func configureNotificationNavigation(
    _ handler: @escaping (NotificationNavigationTarget) -> Void,
    onTerminate: @escaping () -> Void
  ) {
    notificationNavigationHandler = handler
    terminationHandler = onTerminate
    if let pendingNotificationTarget {
      self.pendingNotificationTarget = nil
      handler(pendingNotificationTarget)
    }
  }

  @MainActor
  func applicationWillTerminate(_ notification: Notification) {
    incomingCallPanelController.dismiss(animated: false)
    terminationHandler?()
  }

  @MainActor
  func updateIncomingCallPanel(
    call: IncomingCallRecord?,
    viewAction: @escaping () -> Void,
    messageAction: @escaping () -> Void,
    hangUpAction: @escaping @MainActor () async -> Bool
  ) {
    if let call {
      incomingCallPanelController.present(
        call: call,
        viewAction: viewAction,
        messageAction: messageAction,
        hangUpAction: hangUpAction
      )
    } else {
      incomingCallPanelController.dismiss()
    }
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound])
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    if response.actionIdentifier == DJIONotificationAction.dismissIncomingCall
      || response.actionIdentifier == UNNotificationDismissActionIdentifier
    {
      completionHandler()
      return
    }

    let content = response.notification.request.content
    let target = NotificationNavigationTarget.resolve(
      userInfo: content.userInfo,
      identifier: response.notification.request.identifier
    )
    Task { @MainActor in
      if let target {
        if let notificationNavigationHandler {
          notificationNavigationHandler(target)
        } else {
          pendingNotificationTarget = target
        }
      }
      completionHandler()
    }
  }
}

@main
struct DJIOApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @State private var model: AppModel
  @StateObject private var menuBarStatus: MenuBarStatusModel

  init() {
    let menuBarStatus = MenuBarStatusModel()
    _menuBarStatus = StateObject(wrappedValue: menuBarStatus)
    _model = State(initialValue: AppModel(menuBarStatus: menuBarStatus))
  }

  var body: some Scene {
    Window("DJIO", id: "main") {
      RootView()
        .environmentObject(model)
        .background {
          NotificationNavigationBridge(model: model, appDelegate: appDelegate)
        }
        .background {
          IncomingCallPresentationBridge(model: model, appDelegate: appDelegate)
        }
        .frame(minWidth: 860, minHeight: 520)
        .task { model.start() }
    }
    .defaultSize(width: 1_020, height: 680)
    .commands {
      CommandGroup(after: .sidebar) {
        Button("刷新") {
          Task { await model.refresh() }
        }
        .keyboardShortcut("r", modifiers: .command)
      }
    }

    Settings {
      SettingsView()
        .environmentObject(model)
        .frame(width: 520)
    }

    MenuBarExtra(
      "DJIO",
      systemImage: menuBarStatus.isConnected
        ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash"
    ) {
      MenuBarView(
        status: menuBarStatus,
        refresh: { Task { await model.refresh() } },
        openMessage: { id in
          Task { await model.openMessageFromNotification(id) }
        },
        quit: {
          model.stop()
          NSApp.terminate(nil)
        }
      )
    }
    .menuBarExtraStyle(.window)
  }
}

private struct IncomingCallPresentationBridge: View {
  let model: AppModel
  let appDelegate: AppDelegate
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Color.clear
      .frame(width: 0, height: 0)
      .onAppear {
        updatePanel(for: model.presentedIncomingCall)
      }
      .onReceive(model.$presentedIncomingCall) { call in
        updatePanel(for: call)
      }
  }

  private func updatePanel(for call: IncomingCallRecord?) {
    appDelegate.updateIncomingCallPanel(
      call: call,
      viewAction: {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
        model.openIncomingCallPresentation()
      },
      messageAction: {
        guard let number = call?.callerNumber else { return }
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
        model.openMessageComposer(for: number)
      },
      hangUpAction: {
        await model.hangUpIncomingCall()
      }
    )
  }
}

private struct NotificationNavigationBridge: View {
  let model: AppModel
  let appDelegate: AppDelegate
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Color.clear
      .frame(width: 0, height: 0)
      .onAppear {
        appDelegate.configureNotificationNavigation(
          { target in
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
            Task {
              switch target {
              case .message(let messageID):
                await model.openMessageFromNotification(messageID)
              case .incomingCall:
                model.openIncomingCallsFromNotification()
              }
            }
          },
          onTerminate: { model.stop() }
        )
      }
  }
}
