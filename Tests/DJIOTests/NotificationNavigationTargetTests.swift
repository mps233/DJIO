import Testing

@testable import DJIO

struct NotificationNavigationTargetTests {
  @Test func resolvesTypedMessageAndIncomingCallTargets() {
    #expect(
      NotificationNavigationTarget.resolve(
        userInfo: ["kind": "message", "messageID": "message-1"],
        identifier: "sms:message-1"
      ) == .message("message-1")
    )
    #expect(
      NotificationNavigationTarget.resolve(
        userInfo: ["kind": "incomingCall", "callID": "call-1"],
        identifier: "call:call-1"
      ) == .incomingCall("call-1")
    )
  }

  @Test func keepsLegacyMessageNotificationsWorking() {
    #expect(
      NotificationNavigationTarget.resolve(
        userInfo: ["messageID": "legacy-1"],
        identifier: "legacy-1"
      ) == .message("legacy-1")
    )
    #expect(
      NotificationNavigationTarget.resolve(
        userInfo: [:],
        identifier: "legacy-2"
      ) == .message("legacy-2")
    )
  }

  @Test func ignoresMalformedTypedNotifications() {
    #expect(
      NotificationNavigationTarget.resolve(
        userInfo: ["kind": "incomingCall"],
        identifier: "call:missing"
      ) == nil
    )
    #expect(
      NotificationNavigationTarget.resolve(
        userInfo: ["kind": "unknown"],
        identifier: "anything"
      ) == nil
    )
  }
}
