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
