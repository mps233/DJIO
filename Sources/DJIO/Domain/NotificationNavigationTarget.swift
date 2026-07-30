import Foundation

enum NotificationNavigationTarget: Equatable {
  case message(String)
  case incomingCall(String)

  static func resolve(
    userInfo: [AnyHashable: Any],
    identifier: String
  ) -> NotificationNavigationTarget? {
    switch userInfo["kind"] as? String {
    case "message":
      guard let id = nonemptyString(userInfo["messageID"]) else { return nil }
      return .message(id)
    case "incomingCall":
      guard let id = nonemptyString(userInfo["callID"]) else { return nil }
      return .incomingCall(id)
    case .some:
      return nil
    case .none:
      break
    }

    if let id = nonemptyString(userInfo["messageID"]) {
      return .message(id)
    }
    if let id = nonemptyString(userInfo["callID"]) {
      return .incomingCall(id)
    }
    if identifier.hasPrefix("sms:"), identifier.count > "sms:".count {
      return .message(String(identifier.dropFirst("sms:".count)))
    }
    if identifier.hasPrefix("call:"), identifier.count > "call:".count {
      return .incomingCall(String(identifier.dropFirst("call:".count)))
    }
    guard userInfo.isEmpty, !identifier.isEmpty else { return nil }
    return .message(identifier)
  }

  private static func nonemptyString(_ value: Any?) -> String? {
    guard let value = value as? String, !value.isEmpty else { return nil }
    return value
  }
}
