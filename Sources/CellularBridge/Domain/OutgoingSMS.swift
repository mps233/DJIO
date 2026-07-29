import Foundation

enum OutgoingSMSState: String, CaseIterable, Codable, Sendable {
  case queued
  case sending
  case sent
  case failed
  case outcomeUnknown
}

struct OutgoingSMSPart: Identifiable, Codable, Sendable, Hashable {
  let index: Int
  let pdu: String
  let tpduLength: Int
  let state: OutgoingSMSState
  let attemptCount: Int
  let modemReference: Int?
  let lastError: String?
  let updatedAt: Date

  var id: Int { index }
  var sequenceNumber: Int { index + 1 }
}

struct OutgoingSMS: Identifiable, Codable, Sendable, Hashable {
  let id: String
  let recipient: String
  let body: String
  let concatenationReference: UInt8?
  let state: OutgoingSMSState
  let createdAt: Date
  let updatedAt: Date
  let sentAt: Date?
  let attemptCount: Int
  let lastError: String?
  let parts: [OutgoingSMSPart]

  var totalPartCount: Int { parts.count }
  var sentPartCount: Int { parts.count(where: { $0.state == .sent }) }

  var progress: Double {
    guard !parts.isEmpty else { return 0 }
    return Double(sentPartCount) / Double(parts.count)
  }

  var pendingPartIndexes: [Int] {
    parts.filter { $0.state != .sent }.map(\.index)
  }
}
