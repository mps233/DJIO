import SwiftUI

struct EuiccView: View {
  @EnvironmentObject private var model: AppModel
  @State private var showingAddProfile = false

  var body: some View {
    Form {
      if let issue = model.euicc.issue ?? model.euiccOperation.issue, !issue.isEmpty {
        Section {
          Label {
            Text(issue).textSelection(.enabled)
          } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
          }
        }
      } else if model.euiccOperation.hasResult, let detail = model.euiccOperation.detail {
        Section {
          Label {
            Text(detail)
          } icon: {
            Image(systemName: "checkmark.circle.fill")
              .foregroundStyle(.green)
          }
        }
      }

      Section("卡片信息") {
        LabeledContent("状态") {
          HStack(spacing: 7) {
            Circle()
              .fill(model.euicc.available ? Color.green : Color.secondary.opacity(0.45))
              .frame(width: 7, height: 7)
            Text(model.euicc.available ? "可管理" : "未检测")
          }
        }
        LabeledContent("EID", value: model.euicc.maskedEID)
          .textSelection(.enabled)
        LabeledContent("已安装", value: "\(model.euicc.profiles.count) 个")
        if let updated = model.euicc.lastUpdated {
          LabeledContent("上次读取") {
            Text(updated, format: .dateTime.hour().minute().second())
          }
        }
      }

      Section("已安装的 eSIM") {
        if model.euicc.available, model.euicc.profiles.isEmpty {
          ContentUnavailableView(
            "暂无已安装的 eSIM",
            systemImage: "simcard.2",
            description: Text("这张 eSIM 卡当前为空，可以添加运营商提供的 eSIM 激活码。")
          )
          .frame(maxWidth: .infinity, minHeight: 170)
        } else if model.euicc.profiles.isEmpty {
          ContentUnavailableView(
            "尚未读取 eSIM 卡",
            systemImage: "simcard",
            description: Text("连接模块后点击工具栏中的刷新按钮。")
          )
          .frame(maxWidth: .infinity, minHeight: 170)
        } else {
          ForEach(model.euicc.profiles) { profile in
            EuiccProfileRow(profile: profile)
          }
        }
      }

      Section {
        Label(
          "激活码和 eSIM 数据只在本机处理，不会保存到 DJIO 数据库。",
          systemImage: "lock.shield"
        )
        .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .padding(18)
    .navigationTitle("eSIM")
    .toolbar {
      ToolbarItemGroup {
        Button {
          Task { await model.refreshEuicc() }
        } label: {
          Label("刷新 eSIM", systemImage: "arrow.clockwise")
        }
        .disabled(model.euiccOperation.isActive || model.connection.control == .unavailable)

        Button {
          showingAddProfile = true
        } label: {
          Label("添加 eSIM", systemImage: "plus")
        }
        .disabled(!model.euicc.available || model.euiccOperation.isActive)
      }
    }
    .overlay {
      if model.euiccOperation.isActive {
        ProgressView(model.euiccOperation.phase.title)
          .padding(18)
          .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      }
    }
    .sheet(isPresented: $showingAddProfile) {
      AddEuiccProfileSheet()
        .environmentObject(model)
    }
    .task {
      if !model.euicc.available, model.connection.control != .unavailable {
        await model.refreshEuicc()
      }
    }
  }
}

private struct EuiccProfileRow: View {
  @EnvironmentObject private var model: AppModel
  let profile: EuiccProfile
  @State private var pendingEnabled: Bool?
  @State private var showingRename = false
  @State private var nicknameDraft = ""

  var body: some View {
    HStack(alignment: .center, spacing: 16) {
      VStack(alignment: .leading, spacing: 3) {
        Text(profile.displayName)
        HStack(spacing: 8) {
          if let provider = profile.serviceProviderName, !provider.isEmpty {
            Text(provider)
          }
          Text(profile.maskedICCID)
            .monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Spacer(minLength: 16)

      if profile.state == .unknown {
        Text(profile.state.title)
          .foregroundStyle(.secondary)
      } else {
        Toggle("启用此 eSIM", isOn: enabledBinding)
          .labelsHidden()
          .toggleStyle(.switch)
          .controlSize(.small)
          .accessibilityLabel("启用此 eSIM")
          .accessibilityValue(displayedEnabled ? "已启用" : "未启用")
          .help(displayedEnabled ? "停用此 eSIM" : "启用此 eSIM")
          .disabled(model.euiccOperation.isActive || model.connection.control == .unavailable)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contextMenu {
      Button {
        nicknameDraft = profile.nickname ?? ""
        showingRename = true
      } label: {
        Label("重命名…", systemImage: "pencil")
      }
      .disabled(model.euiccOperation.isActive || model.connection.control == .unavailable)

      if profile.nickname?.isEmpty == false {
        Button {
          Task {
            _ = await model.setEuiccProfileNickname(iccid: profile.iccid, nickname: "")
          }
        } label: {
          Label("恢复运营商名称", systemImage: "arrow.uturn.backward")
        }
        .disabled(model.euiccOperation.isActive || model.connection.control == .unavailable)
      }
    }
    .alert("重命名 eSIM", isPresented: $showingRename) {
      TextField("名称", text: $nicknameDraft)
      Button("取消", role: .cancel) {}
      Button("保存") {
        let nickname = nicknameDraft
        Task {
          _ = await model.setEuiccProfileNickname(iccid: profile.iccid, nickname: nickname)
        }
      }
    } message: {
      Text("名称会写入当前 eSIM 卡。留空并保存可恢复运营商提供的名称。")
    }
  }

  private var displayedEnabled: Bool {
    pendingEnabled ?? (profile.state == .enabled)
  }

  private var enabledBinding: Binding<Bool> {
    Binding(
      get: { displayedEnabled },
      set: { enabled in
        guard enabled != (profile.state == .enabled) else { return }
        pendingEnabled = enabled
        Task {
          _ = await model.setEuiccProfileEnabled(iccid: profile.iccid, enabled: enabled)
          pendingEnabled = nil
        }
      }
    )
  }
}

private struct AddEuiccProfileSheet: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var model: AppModel
  @State private var activationCode = ""
  @State private var confirmationCode = ""
  @State private var validationIssue: String?
  @State private var isSubmitting = false
  @State private var isReadingQRCode = false
  @State private var pendingServer: String?
  @State private var showingConfirmation = false
  @State private var showingQRCodeImporter = false
  @FocusState private var activationCodeFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 22) {
        HStack(spacing: 14) {
          Image(systemName: "simcard.2.fill")
            .font(.system(size: 26))
            .foregroundStyle(.tint)
            .frame(width: 34)

          VStack(alignment: .leading, spacing: 3) {
            Text("添加 eSIM")
              .font(.title2.weight(.semibold))
            Text("输入运营商提供的激活码，或从二维码图片导入。")
              .foregroundStyle(.secondary)
          }
        }

        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 14) {
          GridRow(alignment: .firstTextBaseline) {
            Text("激活码")
              .gridColumnAlignment(.trailing)

            HStack(spacing: 8) {
              TextField("LPA:1$…", text: $activationCode)
                .font(.body.monospaced())
                .textFieldStyle(.roundedBorder)
                .focused($activationCodeFocused)

              Button {
                showingQRCodeImporter = true
              } label: {
                Label("选择二维码…", systemImage: "qrcode.viewfinder")
              }
              .disabled(isReadingQRCode || isSubmitting)
            }
          }

          if isReadingQRCode {
            GridRow {
              Color.clear
                .frame(width: 1, height: 1)
              HStack(spacing: 8) {
                ProgressView()
                  .controlSize(.small)
                Text("正在识别二维码…")
                  .foregroundStyle(.secondary)
              }
            }
          }

          GridRow(alignment: .firstTextBaseline) {
            Text("确认码")
              .gridColumnAlignment(.trailing)
            SecureField("可选", text: $confirmationCode)
              .textFieldStyle(.roundedBorder)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        if let validationIssue {
          Label(validationIssue, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .textSelection(.enabled)
        }

        if isSubmitting {
          HStack(spacing: 10) {
            ProgressView()
              .controlSize(.small)
            Text(model.euiccOperation.detail ?? "正在下载 eSIM")
              .foregroundStyle(.secondary)
          }
        }
      }
      .padding(24)

      Divider()

      HStack {
        Button("取消", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Spacer()
        Button("下载到 eSIM") {
          validationIssue = nil
          do {
            pendingServer = try EuiccActivationCode(activationCode).smdpAddress
            showingConfirmation = true
          } catch {
            validationIssue = error.localizedDescription
            return
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(
          activationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting
        )
      }
      .padding(16)
    }
    .frame(width: 540)
    .onAppear {
      activationCodeFocused = true
    }
    .fileImporter(
      isPresented: $showingQRCodeImporter,
      allowedContentTypes: [.image],
      allowsMultipleSelection: false
    ) { result in
      importQRCode(result)
    }
    .confirmationDialog(
      "确认下载并写入 eSIM？",
      isPresented: $showingConfirmation,
      titleVisibility: .visible
    ) {
      Button("下载到 eSIM") {
        isSubmitting = true
        Task {
          let succeeded = await model.downloadEuiccProfile(
            activationCode: activationCode,
            confirmationCode: confirmationCode
          )
          isSubmitting = false
          if succeeded {
            activationCode = ""
            confirmationCode = ""
            dismiss()
          } else {
            validationIssue = model.euiccOperation.issue
          }
        }
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("将从 \(pendingServer ?? "运营商服务器") 下载加密的 eSIM 数据，并写入当前 eSIM 卡。下载期间请保持模块连接。")
    }
  }

  private func importQRCode(_ result: Result<[URL], Error>) {
    guard case .success(let urls) = result, let url = urls.first else {
      return
    }

    validationIssue = nil
    isReadingQRCode = true
    Task {
      do {
        let decoded = try await Task.detached(priority: .userInitiated) {
          try EuiccQRCodeDecoder.activationCode(from: url)
        }.value
        activationCode = decoded.rawValue
      } catch {
        validationIssue = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
      }
      isReadingQRCode = false
    }
  }
}
