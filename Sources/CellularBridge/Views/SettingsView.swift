import SwiftUI

struct SettingsView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.scenePhase) private var scenePhase

  private var interfaceSelection: Binding<String> {
    Binding(
      get: { model.preferredInterface ?? "" },
      set: { model.updatePreferredInterface($0.isEmpty ? nil : $0) }
    )
  }

  private var apn: Binding<String> {
    Binding(get: { model.apn }, set: { model.updateAPN($0) })
  }

  private var notifications: Binding<Bool> {
    Binding(
      get: { model.notificationsEnabled },
      set: { value in Task { await model.updateNotifications(value) } }
    )
  }

  private var serialPath: Binding<String> {
    Binding(get: { model.preferredSerialPath }, set: { model.updatePreferredSerialPath($0) })
  }

  private var deleteImportedMessages: Binding<Bool> {
    Binding(
      get: { model.deletesImportedMessages },
      set: { model.updateDeletesImportedMessages($0) }
    )
  }

  private var launchAtLogin: Binding<Bool> {
    Binding(get: { model.launchAtLogin }, set: { model.updateLaunchAtLogin($0) })
  }

  var body: some View {
    Form {
      Section {
        Toggle("登录时自动启动", isOn: launchAtLogin)
      } header: {
        Text("通用")
      } footer: {
        if let message = model.launchAtLoginStatusMessage {
          Text(message)
        }
      }

      Section("网络") {
        Picker("ECM 网卡", selection: interfaceSelection) {
          Text("自动").tag("")
          ForEach(model.network.interfaces) { interface in
            Text("\(interface.displayName) (\(interface.name))").tag(interface.name)
          }
        }
        TextField("APN", text: apn, prompt: Text("运营商 APN，可留空"))
      }

      Section("短信") {
        Stepper(
          "状态刷新间隔：\(Int(model.pollInterval)) 秒",
          value: Binding(
            get: { model.pollInterval },
            set: { model.updatePollInterval($0) }
          ),
          in: 3...60,
          step: 1
        )
        Toggle("新短信通知", isOn: notifications)
        Toggle("导入后清理模块短信", isOn: deleteImportedMessages)
      }

      Section("模块") {
        LabeledContent(
          "支持 USB ID",
          value: ModemService.supportedUSBDevices.map(\.description).joined(separator: "、")
        )
        LabeledContent("网络模式", value: "ECM (usbnet=1)")
        LabeledContent(
          "短信保存",
          value: model.deletesImportedMessages ? "本机持久保存，模块逐条清理" : "本机持久保存，模块保留"
        )
      }

      Section("高级") {
        TextField("AT 串口", text: serialPath, prompt: Text("自动探测"))
          .font(.body.monospaced())
      }
    }
    .formStyle(.grouped)
    .padding(18)
    .onAppear {
      model.refreshLaunchAtLoginStatus()
    }
    .onChange(of: scenePhase) { _, newPhase in
      if newPhase == .active {
        model.refreshLaunchAtLoginStatus()
      }
    }
  }
}
