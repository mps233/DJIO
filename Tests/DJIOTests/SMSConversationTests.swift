import Foundation
import Testing

@testable import DJIO

struct SMSConversationTests {
  @Test func mergesEquivalentChineseAddressesIntoOneTimeline() throws {
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let received = incoming(
      id: "received",
      sender: "+86 138 0013 8000",
      body: "收到",
      date: base,
      isRead: false
    )
    let sent = outgoing(
      id: "sent",
      recipient: "138-0013-8000",
      body: "回复",
      date: base.addingTimeInterval(60)
    )

    let conversations = SMSConversationBuilder.conversations(
      incoming: [received], outgoing: [sent])
    let conversation = try #require(conversations.first)

    #expect(conversations.count == 1)
    #expect(conversation.id == "+8613800138000")
    #expect(conversation.displayAddress == "+8613800138000")
    #expect(conversation.entries.map(\.body) == ["收到", "回复"])
    #expect(conversation.unreadCount == 1)
    #expect(conversation.incomingMessageIDs == ["received"])
  }

  @Test func keepsShortCodesSeparateAndSortsByLatestEntry() throws {
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let older = incoming(
      id: "older", sender: "10086", body: "较早", date: base, isRead: true)
    let newer = incoming(
      id: "newer", sender: "10690000", body: "较新",
      date: base.addingTimeInterval(120), isRead: true)

    let conversations = SMSConversationBuilder.conversations(
      incoming: [older, newer], outgoing: [])

    #expect(conversations.map(\.id) == ["10690000", "10086"])
  }

  @Test func outgoingIssueDoesNotMoveMessageToAnotherMailbox() throws {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let failed = outgoing(
      id: "failed", recipient: "10086", body: "失败", date: date, state: .failed)
    let conversation = try #require(
      SMSConversationBuilder.conversations(incoming: [], outgoing: [failed]).first)

    #expect(conversation.entries.count == 1)
    #expect(conversation.entries[0].outgoingMessage?.id == "failed")
    #expect(conversation.hasOutgoingIssue)
  }

  private func incoming(
    id: String,
    sender: String,
    body: String,
    date: Date,
    isRead: Bool
  ) -> SMSMessage {
    SMSMessage(
      id: id,
      sender: sender,
      body: body,
      receivedAt: date,
      serviceCenterAt: date,
      usesMacTimestamp: true,
      storage: "ME",
      modemIndex: 1,
      rawPDU: "",
      isRead: isRead
    )
  }

  private func outgoing(
    id: String,
    recipient: String,
    body: String,
    date: Date,
    state: OutgoingSMSState = .sent
  ) -> OutgoingSMS {
    OutgoingSMS(
      id: id,
      recipient: recipient,
      body: body,
      concatenationReference: nil,
      state: state,
      createdAt: date,
      updatedAt: date,
      sentAt: state == .sent ? date : nil,
      attemptCount: 1,
      lastError: state == .failed ? "测试失败" : nil,
      parts: [
        OutgoingSMSPart(
          index: 0,
          pdu: "00",
          tpduLength: 1,
          state: state,
          attemptCount: 1,
          modemReference: nil,
          lastError: state == .failed ? "测试失败" : nil,
          updatedAt: date
        )
      ]
    )
  }
}
