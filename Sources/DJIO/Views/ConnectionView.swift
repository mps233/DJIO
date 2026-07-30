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
      RefreshToolbarActions(
        isRefreshing: model.isRefreshing,
        refreshHelp: "刷新连接状态",
        refresh: { Task { await model.refresh() } },
        secondarySystemImage: "arrow.triangle.2.circlepath",
        secondaryHelp: "切换到 ECM",
        isSecondaryDisabled: model.isSwitchingMode || model.isRefreshing || model.isSendingMessage
          || model.connection.control == .unavailable,
        secondaryAction: {
          model.showingModeConfirmation = true
        }
      )
    }
    .confirmationDialog(
      "切换到 ECM 模式？",
      isPresented: $model.showingModeConfirmation,
      titleVisibility: .visible
    ) {
      Button("切换并重启模块") {
        Task { await model.switchToECM() }
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("模块会断开并重新枚举，当前网络连接将短暂中断。")
    }
  }

  private var details: CellularDetails {
    model.connection.cellularDetails
  }

  private var connectionSection: some View {
    Section {
      ConnectionStatusRow(
        title: "4G 模块",
        systemImage: "externaldrive.connected.to.line.below",
        value: model.connection.device.label,
        condition: model.connection.device
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
          Text("上次更新：\(updated.formatted(date: .abbreviated, time: .shortened))")
        }
      }
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

  var body: some View {
    LabeledContent(title) {
      Text(value)
        .font(.body.monospaced())
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
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
