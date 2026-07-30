import Foundation

enum NavigationDestination: String, CaseIterable, Identifiable {
  case connection
  case messages
  case calls

  var id: String { rawValue }

  var title: String {
    switch self {
    case .connection: return "连接"
    case .messages: return "短信"
    case .calls: return "来电"
    }
  }

  var systemImage: String {
    switch self {
    case .connection: return "point.3.connected.trianglepath.dotted"
    case .messages: return "message"
    case .calls: return "phone.arrow.down.left"
    }
  }
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

struct ConnectionSnapshot: Sendable, Equatable {
  var device = LinkCondition.unavailable
  var control = LinkCondition.unavailable
  var ecm = LinkCondition.unavailable
  var cellular = LinkCondition.unavailable
  var usbDeviceIdentifier: USBDeviceIdentifier?
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

  static let disconnected = ConnectionSnapshot()
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
  let signalRSSI: Int?
  let registration: String
  let operatorName: String?
  let cellularDetails: CellularDetails
  let newMessages: [SMSMessage]
  let warnings: [String]
}

enum ModemMessageEvent: Sendable {
  case received(SMSMessage)
  case incomingCall(IncomingCallRecord)
  case incomingCallUpdated(IncomingCallRecord)
  case warning(String)
}
