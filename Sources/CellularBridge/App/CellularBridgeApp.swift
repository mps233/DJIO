import AppKit
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
  @MainActor private var openMessageHandler: ((String) -> Void)?
  @MainActor private var pendingMessageID: String?
  @MainActor private var terminationHandler: (() -> Void)?

  func applicationDidFinishLaunching(_ notification: Notification) {
    UNUserNotificationCenter.current().delegate = self
  }

  @MainActor
  func configureNotificationNavigation(
    _ handler: @escaping (String) -> Void,
    onTerminate: @escaping () -> Void
  ) {
    openMessageHandler = handler
    terminationHandler = onTerminate
    if let pendingMessageID {
      self.pendingMessageID = nil
      handler(pendingMessageID)
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
    let messageID =
      content.userInfo["messageID"] as? String ?? response.notification.request.identifier
    Task { @MainActor in
      if let openMessageHandler {
        openMessageHandler(messageID)
      } else {
        pendingMessageID = messageID
      }
      completionHandler()
    }
  }
}

@main
struct CellularBridgeApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @State private var model: AppModel
  @StateObject private var menuBarStatus: MenuBarStatusModel

  init() {
    let menuBarStatus = MenuBarStatusModel()
    _menuBarStatus = StateObject(wrappedValue: menuBarStatus)
    _model = State(initialValue: AppModel(menuBarStatus: menuBarStatus))
  }

  var body: some Scene {
    WindowGroup("蜂窝桥", id: "main") {
      RootView()
        .environmentObject(model)
        .background {
          NotificationNavigationBridge(model: model, appDelegate: appDelegate)
        }
        .frame(minWidth: 640, minHeight: 520)
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
      "蜂窝桥",
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
          { messageID in
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
            Task { await model.openMessageFromNotification(messageID) }
          },
          onTerminate: { model.stop() }
        )
      }
  }
}
