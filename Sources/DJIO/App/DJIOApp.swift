import AppKit
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
  @MainActor private var notificationNavigationHandler: ((NotificationNavigationTarget) -> Void)?
  @MainActor private var pendingNotificationTarget: NotificationNavigationTarget?
  @MainActor private var terminationHandler: (() -> Void)?

  func applicationDidFinishLaunching(_ notification: Notification) {
    UNUserNotificationCenter.current().delegate = self
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
    terminationHandler?()
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
    WindowGroup("DJIO", id: "main") {
      RootView()
        .environmentObject(model)
        .background {
          NotificationNavigationBridge(model: model, appDelegate: appDelegate)
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
        trafficProvider: { model.menuBarStatus.trafficSnapshot() },
        refresh: { Task { await model.refresh() } },
        quit: {
          model.stop()
          NSApp.terminate(nil)
        }
      )
    }
    .menuBarExtraStyle(.window)
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
