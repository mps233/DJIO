import Foundation

struct IncomingCallRecord: Identifiable, Sendable, Hashable {
  let id: String
  let callerNumber: String?
  let receivedAt: Date
}
