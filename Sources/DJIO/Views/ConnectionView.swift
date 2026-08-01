import Foundation
import MapKit
import SwiftUI

struct ConnectionView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    Form {
      if let issue = model.connection.issue, !issue.isEmpty {
        Section {
          Label {
            Text(issue)
              .textSelection(.enabled)
          } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
          }
        }
      }

      connectionSection

      Section("网络") {
        ValueRow(title: "ECM 接口", value: model.connection.networkInterface ?? "未选择")
        ValueRow(title: "IP 地址", value: model.connection.networkAddress ?? "未获取")
        ValueRow(title: "默认路由", value: model.connection.primaryInterface ?? "未知")
      }

      Section {
        ValueRow(title: "统计接口", value: model.traffic.interfaceName ?? "未选择")
        TrafficValueRow(
          title: "下行速度",
          systemImage: "arrow.down",
          value: NetworkTrafficFormatter.rate(model.traffic.downloadBytesPerSecond)
        )
        TrafficValueRow(
          title: "上行速度",
          systemImage: "arrow.up",
          value: NetworkTrafficFormatter.rate(model.traffic.uploadBytesPerSecond)
        )
        TrafficUsageRow(title: "本次运行", totals: model.trafficUsage.session)
        TrafficUsageRow(title: "今日", totals: model.trafficUsage.today)
        TrafficUsageRow(title: "本月", totals: model.trafficUsage.month)
      } header: {
        Text("流量")
      } footer: {
        VStack(alignment: .leading, spacing: 5) {
          Text("按 ECM 接口在本机累计；今日和本月数据会保留，不代表运营商计费流量。")
          if let issue = model.trafficPersistenceIssue {
            Label(issue, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
          }
        }
      }

      Section("蜂窝网络") {
        LabeledContent("运营商", value: model.connection.operatorName ?? "未知")
        ConnectionStatusRow(
          title: "注册状态",
          systemImage: "antenna.radiowaves.left.and.right",
          value: model.connection.registration,
          condition: model.connection.cellular
        )
        LabeledContent("SIM 状态", value: details.simStatus ?? "未知")
        LabeledContent("网络制式", value: details.accessTechnology ?? "未知")
        LabeledContent("频段", value: details.frequencyBand ?? "未知")
        ValueRow(title: "信道", value: details.channel.map(String.init) ?? "未知")
        SignalRow(rssi: model.connection.signalRSSI)
        SignalMetricRow(title: "RSRP", value: details.signalRSRP.map(Double.init), unit: "dBm")
        SignalMetricRow(title: "RSRQ", value: details.signalRSRQ.map(Double.init), unit: "dB")
        SignalMetricRow(title: "SINR", value: details.signalSINR, unit: "dB")
        ValueRow(title: "固件版本", value: details.firmwareRevision ?? "未知")
      }

      Section {
        LabeledContent("状态", value: model.gnssStatusText)

        if let location = model.gnssLocation {
          GNSSMapPreview(location: location, isDemo: model.isDemoMode)
            .frame(minHeight: 210)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

          ValueRow(title: "纬度", value: String(format: "%.6f", location.latitude))
          ValueRow(title: "经度", value: String(format: "%.6f", location.longitude))
          if let altitude = location.altitudeMeters {
            ValueRow(title: "海拔", value: String(format: "%.1f 米", altitude))
          }
          if let horizontalDOP = location.horizontalDOP {
            ValueRow(title: "定位精度", value: String(format: "HDOP %.1f", horizontalDOP))
          }
          if let satellites = location.satellites {
            ValueRow(title: "卫星", value: "\(satellites) 颗")
          }
        }

        if let issue = model.gnssIssue, !issue.isEmpty {
          Label(issue, systemImage: "location.slash")
            .foregroundStyle(.orange)
            .textSelection(.enabled)
        }

        Button {
          if model.isGNSSActive {
            model.stopGNSS()
          } else {
            model.startGNSS()
          }
        } label: {
          Label(
            model.isGNSSActive ? "停止定位" : "开始定位",
            systemImage: model.isGNSSActive ? "location.slash" : "location"
          )
        }
        .buttonStyle(.borderedProminent)
        .disabled(gnssActionIsDisabled)
      } header: {
        Text("定位")
      } footer: {
        VStack(alignment: .leading, spacing: 5) {
          Text("定位只在点击开始后启用；首次定位可能需要更长时间。")
          if let updated = model.gnssLastUpdated {
            Text("上次定位：\(updated.formatted(date: .abbreviated, time: .standard))")
          }
        }
      }

      Section {
        if details.smsStorageUsage.isEmpty {
          LabeledContent("短信容量", value: "未获取")
        } else {
          ForEach(details.smsStorageUsage) { usage in
            SMSStorageRow(usage: usage)
          }
        }
      } header: {
        Text("短信存储")
      } footer: {
        Text("SM 为 SIM 卡存储，ME 为模块内部存储。")
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .padding(18)
    .navigationTitle("连接")
    .toolbar {
      ToolbarItem {
        Button {
          Task { await model.refresh() }
        } label: {
          Group {
            if model.isRefreshing {
              ProgressView()
                .controlSize(.small)
            } else {
              Image(systemName: "arrow.clockwise")
            }
          }
          .frame(width: 16, height: 16)
        }
        .disabled(model.isRefreshing)
        .help("刷新连接状态")
        .accessibilityLabel("刷新连接状态")
      }
    }
    .confirmationDialog(
      confirmedFactoryIdentityRewrite ? "转换大疆模块并启用 ECM？" : "切换到 ECM 模式？",
      isPresented: $model.showingModeConfirmation,
      titleVisibility: .visible
    ) {
      Button(
        confirmedFactoryIdentityRewrite ? "转换并重启模块" : "切换并重启模块",
        role: confirmedFactoryIdentityRewrite ? .destructive : nil
      ) {
        Task {
          await model.switchToECM(
            allowFactoryIdentityRewrite: confirmedFactoryIdentityRewrite
          )
        }
      }
      Button("取消", role: .cancel) {}
    } message: {
      if confirmedFactoryIdentityRewrite {
        Text(
          "USB 身份将从 2CA3:4006 持久改为 2C7C:0125，并切换到 ECM。"
            + "模块会重启并重新枚举；操作过程中请勿拔出 USB。"
        )
      } else {
        Text("模块会重启并重新枚举，当前网络连接将短暂中断。")
      }
    }
  }

  private var confirmedFactoryIdentityRewrite: Bool {
    model.modeConfirmationAllowsFactoryIdentityRewrite
  }

  private var modemConfigurationActionIsDisabled: Bool {
    model.isSwitchingMode || model.isRefreshing || model.isSendingMessage
      || model.connection.control == .unavailable
  }

  private var gnssActionIsDisabled: Bool {
    model.isGNSSBusy
      || model.isSwitchingMode
      || (!model.isDemoMode && model.connection.control == .unavailable)
  }

  private var details: CellularDetails {
    model.connection.cellularDetails
  }

  private var displayedModuleUsageMode: ModuleUsageMode? {
    model.modeSwitchDestination ?? model.connection.moduleUsageMode
  }

  private var moduleUsageModeSelection: Binding<ModuleUsageMode?> {
    Binding(
      get: { displayedModuleUsageMode },
      set: { requestedMode in
        guard
          let requestedMode,
          requestedMode != displayedModuleUsageMode,
          !modemConfigurationActionIsDisabled
        else { return }

        switch requestedMode {
        case .ecm:
          guard canConfigureECMMode else { return }
          model.presentModeSwitchConfirmation()
        case .dji:
          guard canConfigureDJIMode else { return }
          Task {
            await model.restoreDJIFactoryUSBConfigurationFromCurrentState()
          }
        }
      }
    )
  }

  private var moduleModeRow: some View {
    Picker(selection: moduleUsageModeSelection) {
                            Label("大疆模式", systemImage: "drone")
        .tag(ModuleUsageMode.dji as ModuleUsageMode?)
                            Label("网卡模式", systemImage: "macbook.and.ipad")
        .tag(ModuleUsageMode.ecm as ModuleUsageMode?)
    } label: {
      Label {
        HStack(spacing: 8) {
          Text("使用模式")
          ProgressView()
            .controlSize(.small)
            .opacity(model.isSwitchingMode ? 1 : 0)
            .frame(width: 16)
            .accessibilityHidden(!model.isSwitchingMode)
        }
      } icon: {
        Image(systemName: "switch.2")
      }
      .alignmentGuide(.firstTextBaseline) { dimensions in
        dimensions[VerticalAlignment.center]
      }
      .offset(y: 5)
    }
    .pickerStyle(.segmented)
    .controlSize(.large)
    .disabled(
      modemConfigurationActionIsDisabled
        || (!canConfigureECMMode && !canConfigureDJIMode)
    )
    .accessibilityLabel("模块使用模式")
  }

  private var canConfigureECMMode: Bool {
    model.connection.usbDeviceIdentifier == .quectelEC25
      || model.connection.usbDeviceIdentifier == .djiFirstGenerationFactory
  }

  private var canConfigureDJIMode: Bool {
    model.connection.usbDeviceIdentifier == .quectelEC25
      || (model.connection.usbDeviceIdentifier == .djiFirstGenerationFactory
        && model.connection.usbNetworkMode != 0)
  }

  private var connectionSection: some View {
    Section {
      ConnectionStatusRow(
        title: "蜂窝模块",
        systemImage: "externaldrive.connected.to.line.below",
        value: model.connection.device.label,
        condition: model.connection.device
      )
      moduleModeRow
      ValueRow(
        title: "USB 标识",
        value: model.connection.usbDeviceIdentifier?.description ?? "未获取",
        systemImage: "number"
      )
      ConnectionStatusRow(
        title: "AT 控制",
        systemImage: "terminal",
        value: model.connection.control.label,
        condition: model.connection.control
      )
      ConnectionStatusRow(
        title: "ECM 网卡",
        systemImage: "network",
        value: model.connection.ecm.label,
        condition: model.connection.ecm
      )
      ConnectionStatusRow(
        title: "移动网络",
        systemImage: "antenna.radiowaves.left.and.right",
        value: model.connection.registration,
        condition: model.connection.cellular
      )
    } header: {
      Text("连接状态")
    } footer: {
      VStack(alignment: .leading, spacing: 3) {
        Text(model.connection.transportDescription)
          .font(.caption.monospaced())
          .textSelection(.enabled)
        if let updated = model.connection.lastUpdated {
          Text("上次更新：\(updated.formatted(date: .abbreviated, time: .standard))")
        }
      }
    }
  }
}

private struct GNSSMapPreview: View {
  let location: GNSSLocation
  let isDemo: Bool

  private var coordinate: CLLocationCoordinate2D {
    CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)
  }

  var body: some View {
    Map(
      initialPosition: .region(
        MKCoordinateRegion(
          center: coordinate,
          latitudinalMeters: 1_200,
          longitudinalMeters: 1_200
        )
      )
    ) {
      Marker("DJIO", coordinate: coordinate)
        .tint(.blue)
    }
    .mapControlVisibility(.hidden)
    .overlay(alignment: .topLeading) {
      Label(isDemo ? "演示定位" : "当前位置", systemImage: "location.fill")
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .padding(10)
    }
  }
}

private struct ConnectionStatusRow: View {
  let title: String
  let systemImage: String
  let value: String
  let condition: LinkCondition

  var body: some View {
    LabeledContent {
      HStack(spacing: 6) {
        if condition == .checking {
          ProgressView()
            .controlSize(.small)
        } else {
          Image(systemName: condition.statusSystemImage)
            .foregroundStyle(condition.color)
            .accessibilityHidden(true)
        }
        Text(value)
          .foregroundStyle(.secondary)
      }
    } label: {
      Label(title, systemImage: systemImage)
    }
  }
}

private struct ValueRow: View {
  let title: String
  let value: String
  var systemImage: String? = nil

  var body: some View {
    LabeledContent {
      Text(value)
        .font(.body.monospaced())
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    } label: {
      if let systemImage {
        Label(title, systemImage: systemImage)
      } else {
        Text(title)
      }
    }
  }
}

private struct TrafficValueRow: View {
  let title: String
  let systemImage: String
  let value: String

  var body: some View {
    LabeledContent {
      Text(value)
        .font(.body.monospacedDigit())
        .foregroundStyle(.secondary)
    } label: {
      Label(title, systemImage: systemImage)
    }
  }
}

private struct TrafficUsageRow: View {
  let title: String
  let totals: TrafficUsageTotals

  var body: some View {
    LabeledContent(title) {
      HStack(spacing: 16) {
        Label(
          NetworkTrafficFormatter.byteCount(totals.receivedBytes),
          systemImage: "arrow.down"
        )
        Label(
          NetworkTrafficFormatter.byteCount(totals.sentBytes),
          systemImage: "arrow.up"
        )
      }
      .font(.body.monospacedDigit())
      .foregroundStyle(.secondary)
    }
  }
}

private struct SMSStorageRow: View {
  let usage: SMSStorageUsage

  private var storageName: String {
    switch usage.storage {
    case "SM": return "SIM 卡"
    case "ME": return "模块"
    default: return usage.storage
    }
  }

  var body: some View {
    LabeledContent {
      VStack(alignment: .trailing, spacing: 5) {
        Text("\(usage.used) / \(usage.total) 条")
          .font(.body.monospacedDigit())
          .foregroundStyle(.secondary)
        ProgressView(value: Double(usage.used), total: Double(max(1, usage.total)))
          .frame(width: 180)
      }
    } label: {
      Text("\(storageName) (\(usage.storage))")
    }
    .accessibilityElement(children: .combine)
    .accessibilityValue("已用 \(usage.used) 条，共 \(usage.total) 条")
  }
}

private struct SignalMetricRow: View {
  let title: String
  let value: Double?
  let unit: String

  var body: some View {
    LabeledContent(title) {
      Text(formattedValue)
        .font(.body.monospacedDigit())
        .foregroundStyle(.secondary)
    }
  }

  private var formattedValue: String {
    guard let value else { return "未知" }
    let number = value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    return "\(number) \(unit)"
  }
}

private struct SignalRow: View {
  let rssi: Int?

  var body: some View {
    LabeledContent("信号") {
      if let rssi {
        HStack(spacing: 10) {
          Gauge(value: Double(max(-113, min(-51, rssi))), in: -113 ... -51) {
            Text("信号")
          }
          .gaugeStyle(.accessoryLinearCapacity)
          .labelsHidden()
          Text("\(rssi) dBm · \(quality(for: rssi))")
            .font(.body.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      } else {
        Text("未知")
          .foregroundStyle(.secondary)
      }
    }
  }

  private func quality(for rssi: Int) -> String {
    switch rssi {
    case -75...Int.max: return "强"
    case -90 ... -76: return "良好"
    case -103 ... -91: return "较弱"
    default: return "弱"
    }
  }
}

extension LinkCondition {
  fileprivate var statusSystemImage: String {
    switch self {
    case .ready: return "checkmark.circle.fill"
    case .warning: return "exclamationmark.triangle.fill"
    case .unavailable: return "xmark.circle.fill"
    case .checking: return "circle.dotted"
    }
  }
}
