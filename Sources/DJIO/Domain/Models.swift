import Foundation

enum NavigationDestination: String, CaseIterable, Identifiable {
  case connection
  case esim
  case messages
  case calls

  var id: String { rawValue }

  var title: String {
    switch self {
    case .connection: return "连接"
    case .esim: return "eSIM"
    case .messages: return "短信"
    case .calls: return "来电"
    }
  }

  var systemImage: String {
    switch self {
    case .connection: return "point.3.connected.trianglepath.dotted"
    case .esim: return "simcard.2"
    case .messages: return "message"
    case .calls: return "phone.arrow.down.left"
    }
  }
}

struct MessageCompositionRequest: Equatable {
  let id: UUID
  let recipient: String
}

enum LinkCondition: String, Sendable {
  case unavailable
  case checking
  case ready
  case warning

  var label: String {
    switch self {
    case .unavailable: return "未连接"
    case .checking: return "正在检查"
    case .ready: return "正常"
    case .warning: return "需要处理"
    }
  }
}

enum ModuleUsageMode: String, Sendable, Hashable {
  case ecm
  case dji
}

struct ConnectionSnapshot: Sendable, Equatable {
  var device = LinkCondition.unavailable
  var control = LinkCondition.unavailable
  var ecm = LinkCondition.unavailable
  var cellular = LinkCondition.unavailable
  var usbDeviceIdentifier: USBDeviceIdentifier?
  var usbEnumerationIdentifier: USBEnumerationIdentifier?
  var usbNetworkMode: Int?
  var transportDescription = "等待模块"
  var networkInterface: String?
  var networkAddress: String?
  var primaryInterface: String?
  var operatorName: String?
  var registration = "未知"
  var signalRSSI: Int?
  var cellularDetails = CellularDetails()
  var lastUpdated: Date?
  var issue: String?
  var smsIssue: String?

  static let disconnected = ConnectionSnapshot()

  var moduleUsageMode: ModuleUsageMode? {
    if usbDeviceIdentifier == .djiFirstGenerationFactory, usbNetworkMode == 0 {
      return .dji
    }
    if usbNetworkMode == 1,
      usbDeviceIdentifier == .quectelEC25
        || usbDeviceIdentifier == .djiFirstGenerationFactory
    {
      return .ecm
    }
    return nil
  }
}

struct USBDeviceIdentifier: Sendable, Hashable, CustomStringConvertible {
  let vendorID: UInt16
  let productID: UInt16

  var description: String {
    String(format: "%04X:%04X", Int(vendorID), Int(productID))
  }
}

extension USBDeviceIdentifier {
  static let djiFirstGenerationFactory = USBDeviceIdentifier(
    vendorID: 0x2CA3,
    productID: 0x4006
  )
  static let quectelEC25 = USBDeviceIdentifier(
    vendorID: 0x2C7C,
    productID: 0x0125
  )
}

struct USBEnumerationIdentifier: Sendable, Equatable {
  let bus: UInt8
  let address: UInt8
}

struct USBDeviceConfiguration: Sendable, Equatable {
  let deviceIdentifier: USBDeviceIdentifier
  let diag: Int
  let nmea: Int
  let atPort: Int
  let modem: Int
  let rmnet: Int
  let adb: Int
  let uac: Int
}

extension USBDeviceConfiguration {
  static let djiFirstGenerationFactory = USBDeviceConfiguration(
    deviceIdentifier: .djiFirstGenerationFactory,
    diag: 1,
    nmea: 1,
    atPort: 1,
    modem: 1,
    rmnet: 1,
    adb: 0,
    uac: 0
  )
}

enum DJIFactoryUSBRestorePlan: Sendable, Equatable {
  case identityAndNetworkMode
  case networkModeOnly

  var includesIdentityRewrite: Bool {
    self == .identityAndNetworkMode
  }
}

struct USBRestoreTarget: Sendable, Equatable {
  let equipmentIdentity: String
  let enumerationIdentifier: USBEnumerationIdentifier
}

struct ECMModeSwitchResult: Sendable, Equatable {
  let didRewriteUSBIdentity: Bool
  let expectedUSBIdentity: USBDeviceIdentifier?
}

enum ECMModeSwitchError: LocalizedError, Sendable {
  case factoryIdentityRewriteNotAuthorized
  case identityRewriteOutcomeUnknown(String)
  case identityRewriteAcceptedButModeSwitchFailed(String)
  case modeSwitchOutcomeUnknown(
    expectedUSBIdentity: USBDeviceIdentifier?,
    identityRewriteAccepted: Bool,
    detail: String
  )

  var expectedUSBIdentity: USBDeviceIdentifier? {
    switch self {
    case .identityRewriteOutcomeUnknown,
      .identityRewriteAcceptedButModeSwitchFailed:
      return .quectelEC25
    case .modeSwitchOutcomeUnknown(let expectedUSBIdentity, _, _):
      return expectedUSBIdentity
    case .factoryIdentityRewriteNotAuthorized:
      return nil
    }
  }

  var shouldVerifyModeSwitch: Bool {
    if case .factoryIdentityRewriteNotAuthorized = self {
      return false
    }
    return true
  }

  var shouldWaitForReenumeration: Bool {
    if case .modeSwitchOutcomeUnknown = self {
      return true
    }
    return false
  }

  var errorDescription: String? {
    switch self {
    case .factoryIdentityRewriteNotAuthorized:
      return
        "检测到大疆原厂 USB 身份 2CA3:4006，但本次操作未授权永久改写。"
        + "请刷新连接状态后重新确认。"
    case .identityRewriteOutcomeUnknown(let detail):
      return
        "USB 身份改写结果未知：\(detail)。请勿拔出模块；重新连接或重启后确认当前身份。"
    case .identityRewriteAcceptedButModeSwitchFailed(let detail):
      return
        "模块已接受 USB 身份改写，但后续 ECM 配置或重启失败：\(detail)。"
        + "新身份可能在模块下次重启后生效。"
    case .modeSwitchOutcomeUnknown(_, let identityRewriteAccepted, let detail):
      if identityRewriteAccepted {
        return
          "模块已接受 USB 身份改写，但后续 ECM 配置或重启结果未知：\(detail)。"
          + "正在等待设备重新枚举。"
      }
      return "ECM 配置或模块重启结果未知：\(detail)。正在等待设备重新枚举。"
    }
  }
}

struct USBIdentityRestoreResult: Sendable, Equatable {
  let expectedUSBIdentity: USBDeviceIdentifier
  let target: USBRestoreTarget
}

enum USBIdentityRestoreError: LocalizedError, Sendable {
  case notAuthorized
  case unsupportedCurrentIdentity(USBDeviceIdentifier?)
  case equipmentIdentityUnavailable
  case identityRewriteOutcomeUnknown(detail: String, target: USBRestoreTarget)
  case identityVerificationFailed(
    observed: USBDeviceConfiguration?,
    target: USBRestoreTarget
  )
  case identityRewriteAcceptedButRestartFailed(
    detail: String,
    target: USBRestoreTarget
  )
  case restartOutcomeUnknown(detail: String, target: USBRestoreTarget)

  var expectedUSBIdentity: USBDeviceIdentifier? {
    switch self {
    case .identityRewriteOutcomeUnknown,
      .identityVerificationFailed,
      .identityRewriteAcceptedButRestartFailed,
      .restartOutcomeUnknown:
      return .djiFirstGenerationFactory
    case .notAuthorized, .unsupportedCurrentIdentity, .equipmentIdentityUnavailable:
      return nil
    }
  }

  var target: USBRestoreTarget? {
    switch self {
    case .identityRewriteOutcomeUnknown(_, let target),
      .identityVerificationFailed(_, let target),
      .identityRewriteAcceptedButRestartFailed(_, let target),
      .restartOutcomeUnknown(_, let target):
      return target
    case .notAuthorized, .unsupportedCurrentIdentity, .equipmentIdentityUnavailable:
      return nil
    }
  }

  var shouldVerifyIdentityRestore: Bool {
    expectedUSBIdentity != nil
  }

  var shouldWaitForReenumeration: Bool {
    switch self {
    case .identityRewriteOutcomeUnknown, .restartOutcomeUnknown:
      return true
    case .notAuthorized, .unsupportedCurrentIdentity, .equipmentIdentityUnavailable,
      .identityVerificationFailed, .identityRewriteAcceptedButRestartFailed:
      return false
    }
  }

  var errorDescription: String? {
    switch self {
    case .notAuthorized:
      return
        "本次操作未授权将 USB 标识永久恢复为 2CA3:4006。"
        + "请刷新连接状态后重新确认。"
    case .unsupportedCurrentIdentity(let identifier):
      if let identifier {
        return
          "当前 USB 标识为 \(identifier)，只有明确识别为 2C7C:0125 时才能恢复大疆原厂标识。"
      }
      return "无法确认当前 USB 标识，已停止恢复操作。请使用 USB AT 连接后重试。"
    case .equipmentIdentityUnavailable:
      return "无法读取模块 IMEI，已在写入任何持久配置前停止恢复。"
    case .identityRewriteOutcomeUnknown(let detail, _):
      return
        "恢复大疆 USB 标识的写入结果未知：\(detail)。"
        + "请勿拔出模块；重新连接或重启后确认当前标识。"
    case .identityVerificationFailed(let observed, _):
      if let observed {
        return
          "模块未保存预期的大疆 USB 配置；当前持久配置仍为 "
          + "\(observed.deviceIdentifier)。已停止重启。"
      }
      return "模块接受了 USB 配置写入，但无法读取并确认保存结果。已停止重启。"
    case .identityRewriteAcceptedButRestartFailed(let detail, _):
      return
        "模块已接受大疆 USB 标识恢复，但软重启失败：\(detail)。"
        + "新标识可能在模块下次重启后生效。"
    case .restartOutcomeUnknown(let detail, _):
      return
        "模块已接受大疆 USB 标识恢复，但软重启结果未知：\(detail)。"
        + "正在等待设备重新枚举。"
    }
  }
}

struct USBNetworkModeRestoreResult: Sendable, Equatable {
  let expectedUSBIdentity: USBDeviceIdentifier
  let expectedUSBNetworkMode: Int
  let didChangeMode: Bool
  let target: USBRestoreTarget
}

enum USBNetworkModeRestoreError: LocalizedError, Sendable {
  case notAuthorized
  case unsupportedCurrentIdentity(USBDeviceIdentifier?)
  case equipmentIdentityUnavailable
  case differentDevice
  case currentModeCouldNotBeRead
  case outcomeUnknown(detail: String, target: USBRestoreTarget)

  var expectedUSBIdentity: USBDeviceIdentifier? {
    if case .outcomeUnknown = self {
      return .djiFirstGenerationFactory
    }
    return nil
  }

  var expectedUSBNetworkMode: Int? {
    if case .outcomeUnknown = self {
      return 0
    }
    return nil
  }

  var target: USBRestoreTarget? {
    if case .outcomeUnknown(_, let target) = self {
      return target
    }
    return nil
  }

  var shouldVerifyNetworkModeRestore: Bool {
    expectedUSBNetworkMode != nil
  }

  var shouldWaitForReenumeration: Bool {
    if case .outcomeUnknown = self {
      return true
    }
    return false
  }

  var errorDescription: String? {
    switch self {
    case .notAuthorized:
      return
        "本次操作未授权将 USB 网络模式永久恢复为大疆私有模式。"
        + "请刷新连接状态后重新确认。"
    case .unsupportedCurrentIdentity(let identifier):
      if let identifier {
        return
          "当前 USB 标识为 \(identifier)，"
          + "只有确认恢复为 2CA3:4006 后才能继续恢复大疆私有模式。"
      }
      return "无法确认当前 USB 标识，已停止恢复大疆私有模式。"
    case .equipmentIdentityUnavailable:
      return "无法读取模块 IMEI，已在恢复大疆私有模式前停止操作。"
    case .differentDevice:
      return "重新连接后的模块与确认恢复的模块不是同一设备，已停止写入持久配置。"
    case .currentModeCouldNotBeRead:
      return "无法读取当前 USB 网络模式，已停止完整恢复。"
    case .outcomeUnknown(let detail, _):
      return
        "恢复大疆私有 USB 模式的结果未知：\(detail)。"
        + "正在等待设备重新枚举并查询 usbnet。"
    }
  }
}

struct USBTransportDescriptor: Sendable, Equatable {
  let sessionID: UUID
  let vendorID: UInt16
  let productID: UInt16
  let bus: UInt8
  let address: UInt8
  let interfaceNumber: UInt8
  let alternateSetting: UInt8
  let endpointIn: UInt8
  let endpointOut: UInt8

  var deviceIdentifier: USBDeviceIdentifier {
    USBDeviceIdentifier(vendorID: vendorID, productID: productID)
  }

  var enumerationIdentifier: USBEnumerationIdentifier {
    USBEnumerationIdentifier(bus: bus, address: address)
  }

  var summary: String {
    String(
      format: "USB AT · %@ · 接口 %d · 0x%02X/0x%02X",
      deviceIdentifier.description,
      interfaceNumber,
      endpointOut,
      endpointIn
    )
  }
}

enum ATTransportDescriptor: Sendable, Equatable {
  case usb(USBTransportDescriptor)
  case serial(path: String, sessionID: UUID)

  var usbDeviceIdentifier: USBDeviceIdentifier? {
    guard case .usb(let info) = self else { return nil }
    return info.deviceIdentifier
  }

  var usbEnumerationIdentifier: USBEnumerationIdentifier? {
    guard case .usb(let info) = self else { return nil }
    return info.enumerationIdentifier
  }

  var summary: String {
    switch self {
    case .usb(let info): return info.summary
    case .serial(let path, _): return "串口 AT · \(path)"
    }
  }
}

struct NetworkInterfaceSnapshot: Identifiable, Sendable, Hashable {
  let name: String
  let displayName: String
  let address: String?
  let isLinkUp: Bool
  let isActive: Bool
  let isPrimary: Bool

  var id: String { name }
}

struct NetworkSnapshot: Sendable, Equatable {
  var interfaces: [NetworkInterfaceSnapshot] = []
  var selectedInterface: NetworkInterfaceSnapshot?
  var primaryInterface: String?
}

struct InterfaceTrafficCounters: Sendable, Equatable {
  let interfaceIndex: UInt32
  let receivedBytes: UInt64
  let sentBytes: UInt64
}

struct NetworkTrafficSnapshot: Sendable, Equatable {
  var interfaceName: String?
  var downloadBytesPerSecond: Double?
  var uploadBytesPerSecond: Double?
  var receivedBytes: UInt64?
  var sentBytes: UInt64?

  static let unavailable = NetworkTrafficSnapshot()
}

struct SMSStorageUsage: Identifiable, Sendable, Hashable {
  let storage: String
  let used: Int
  let total: Int

  var id: String { storage }
}

struct CellularDetails: Sendable, Equatable {
  var simStatus: String?
  var firmwareRevision: String?
  var accessTechnology: String?
  var frequencyBand: String?
  var channel: Int?
  var signalRSRP: Int?
  var signalRSRQ: Int?
  var signalSINR: Double?
  var smsStorageUsage: [SMSStorageUsage] = []
}

struct GNSSLocation: Sendable, Equatable {
  let latitude: Double
  let longitude: Double
  let horizontalDOP: Double?
  let altitudeMeters: Double?
  let fixMode: Int?
  let courseDegrees: Double?
  let speedKmh: Double?
  let speedKnots: Double?
  let utcTime: String?
  let utcDate: String?
  let satellites: Int?
}

struct SMSMessage: Identifiable, Sendable, Hashable {
  let id: String
  let sender: String
  let body: String
  let receivedAt: Date
  let serviceCenterAt: Date
  let usesMacTimestamp: Bool
  let storage: String
  let modemIndex: Int
  let rawPDU: String
  var isRead: Bool

  var preview: String {
    body.replacingOccurrences(of: "\n", with: " ")
  }

  var timelineAt: Date {
    usesMacTimestamp ? receivedAt : serviceCenterAt
  }
}

enum SMSAlphabet: String, Sendable {
  case gsm7
  case eightBit
  case ucs2
}

struct SMSConcatenation: Sendable, Hashable {
  let reference: UInt16
  let uses16BitReference: Bool
  let totalParts: Int
  let sequence: Int
}

struct DecodedSMSPart: Sendable, Hashable {
  let sender: String
  let body: String
  let receivedAt: Date
  let alphabet: SMSAlphabet
  let concatenation: SMSConcatenation?
  let rawPDU: String
}

struct ModemStoredPDU: Sendable, Hashable {
  let storage: String
  let index: Int
  let pdu: String
  let isRead: Bool
}

struct ModemPollResult: Sendable {
  let transport: ATTransportDescriptor
  let usbNetworkMode: Int?
  let signalRSSI: Int?
  let registration: String
  let operatorName: String?
  let cellularDetails: CellularDetails
  let newMessages: [SMSMessage]
  let warnings: [String]
  let smsWarnings: [String]
}

enum ModemMessageEvent: Sendable {
  case received(SMSMessage)
  case incomingCall(IncomingCallRecord)
  case incomingCallUpdated(IncomingCallRecord)
  case incomingCallEnded(String)
  case warning(String)
}
