import Foundation

struct EuiccSnapshot: Sendable, Equatable {
  var available = false
  var eid: String?
  var profiles: [EuiccProfile] = []
  var lastUpdated: Date?
  var issue: String?

  static let unavailable = EuiccSnapshot()

  var maskedEID: String {
    guard let eid, eid.count > 8 else { return eid ?? "未读取" }
    return "\(eid.prefix(4))••••••••\(eid.suffix(4))"
  }

  var hasEnabledProfile: Bool {
    profiles.contains { $0.state == .enabled }
  }

  var hasProfilesButNoneEnabled: Bool {
    available && !profiles.isEmpty && !hasEnabledProfile
  }
}

struct EuiccProfile: Sendable, Equatable, Identifiable {
  let id: String
  let iccid: String
  let nickname: String?
  let serviceProviderName: String?
  let profileName: String?
  let state: EuiccProfileState
  let profileClass: String?

  var displayName: String {
    nickname.nilIfEmpty ?? profileName.nilIfEmpty ?? serviceProviderName.nilIfEmpty ?? "未命名 eSIM"
  }

  var maskedICCID: String {
    guard iccid.count > 8 else { return iccid }
    return "\(iccid.prefix(4))••••••••\(iccid.suffix(4))"
  }
}

enum EuiccProfileState: String, Sendable, Equatable {
  case disabled
  case enabled
  case unknown

  var title: String {
    switch self {
    case .disabled: return "未启用"
    case .enabled: return "已启用"
    case .unknown: return "未知"
    }
  }
}

enum EuiccOperationPhase: Sendable, Equatable {
  case idle
  case inspecting
  case downloading
  case installing
  case enabling
  case disabling
  case renaming
  case deleting
  case finished

  var title: String {
    switch self {
    case .idle: return ""
    case .inspecting: return "正在读取 eSIM 卡"
    case .downloading: return "正在从运营商下载 eSIM"
    case .installing: return "正在写入 eSIM 卡"
    case .enabling: return "正在启用 eSIM"
    case .disabling: return "正在停用 eSIM"
    case .renaming: return "正在保存 eSIM 名称"
    case .deleting: return "正在删除 eSIM"
    case .finished: return "已完成"
    }
  }
}

struct EuiccOperationState: Sendable, Equatable {
  var phase: EuiccOperationPhase = .idle
  var progress: Double?
  var detail: String?
  var issue: String?
  var isActive: Bool { phase != .idle && phase != .finished }
  var hasResult: Bool {
    phase == .finished && (detail?.isEmpty == false || issue?.isEmpty == false)
  }
}

enum EuiccError: LocalizedError, Sendable, Equatable {
  case notConnected
  case notEuicc
  case invalidResponse(String)
  case modemRejected(String)
  case cancelled
  case unsupported(String)

  var errorDescription: String? {
    switch self {
    case .notConnected: return "模块尚未连接"
    case .notEuicc: return "当前 SIM 卡不支持 eSIM 管理"
    case .invalidResponse(let detail): return "eSIM 卡返回了无法解析的数据：\(detail)"
    case .modemRejected(let detail): return "模块拒绝了 eSIM 操作：\(detail)"
    case .cancelled: return "操作已取消"
    case .unsupported(let detail): return detail
    }
  }
}

private extension Optional where Wrapped == String {
  var nilIfEmpty: String? {
    flatMap { $0.isEmpty ? nil : $0 }
  }
}
