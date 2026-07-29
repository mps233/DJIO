import Foundation

struct SMSConversationEntry: Identifiable, Sendable, Hashable {
  enum Content: Sendable, Hashable {
    case incoming(SMSMessage)
    case outgoing(OutgoingSMS)
  }

  let content: Content

  var id: String {
    switch content {
    case .incoming(let message): return "incoming:\(message.id)"
    case .outgoing(let message): return "outgoing:\(message.id)"
    }
  }

  var address: String {
    switch content {
    case .incoming(let message): return message.sender
    case .outgoing(let message): return message.recipient
    }
  }

  var body: String {
    switch content {
    case .incoming(let message): return message.body
    case .outgoing(let message): return message.body
    }
  }

  var timestamp: Date {
    switch content {
    case .incoming(let message): return message.timelineAt
    case .outgoing(let message): return message.sentAt ?? message.createdAt
    }
  }

  var incomingMessage: SMSMessage? {
    guard case .incoming(let message) = content else { return nil }
    return message
  }

  var outgoingMessage: OutgoingSMS? {
    guard case .outgoing(let message) = content else { return nil }
    return message
  }

  var isIncoming: Bool { incomingMessage != nil }
}

struct SMSConversation: Identifiable, Sendable, Hashable {
  let id: String
  let displayAddress: String
  let entries: [SMSConversationEntry]

  var latestEntry: SMSConversationEntry? { entries.last }
  var latestDate: Date { latestEntry?.timestamp ?? .distantPast }
  var unreadCount: Int {
    entries.count(where: { $0.incomingMessage?.isRead == false })
  }

  var incomingMessageIDs: [String] {
    entries.compactMap { $0.incomingMessage?.id }
  }

  var hasOutgoingIssue: Bool {
    entries.contains {
      guard let message = $0.outgoingMessage else { return false }
      return message.state == .failed || message.state == .outcomeUnknown
    }
  }
}

enum SMSConversationBuilder {
  static func conversations(
    incoming: [SMSMessage],
    outgoing: [OutgoingSMS]
  ) -> [SMSConversation] {
    var grouped: [String: [SMSConversationEntry]] = [:]
    for message in incoming {
      grouped[canonicalAddress(message.sender), default: []].append(
        SMSConversationEntry(content: .incoming(message)))
    }
    for message in outgoing {
      grouped[canonicalAddress(message.recipient), default: []].append(
        SMSConversationEntry(content: .outgoing(message)))
    }

    return grouped.map { id, unsortedEntries in
      let entries = unsortedEntries.sorted {
        if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
        return $0.id < $1.id
      }
      return SMSConversation(
        id: id,
        displayAddress: displayAddress(for: entries, canonicalAddress: id),
        entries: entries
      )
    }
    .sorted {
      if $0.latestDate != $1.latestDate { return $0.latestDate > $1.latestDate }
      return $0.id < $1.id
    }
  }

  static func canonicalAddress(_ rawAddress: String) -> String {
    let trimmed = rawAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return trimmed }

    var compact = ""
    compact.reserveCapacity(trimmed.count)
    for character in trimmed {
      if character.isWhitespace || ignoredAddressCharacters.contains(character) {
        continue
      }
      compact.append(character)
    }
    if compact.hasPrefix("00") {
      compact = "+" + compact.dropFirst(2)
    }

    let hasInternationalPrefix = compact.first == "+"
    let digits = hasInternationalPrefix ? compact.dropFirst() : compact[...]
    guard !digits.isEmpty, digits.allSatisfy(isASCIIDigit) else {
      return compact.lowercased()
    }
    if !hasInternationalPrefix, digits.count == 11, digits.first == "1" {
      return "+86" + digits
    }
    return hasInternationalPrefix ? "+" + digits : String(digits)
  }

  private static func displayAddress(
    for entries: [SMSConversationEntry],
    canonicalAddress: String
  ) -> String {
    if canonicalAddress.hasPrefix("+") { return canonicalAddress }
    return entries.last?.address.trimmingCharacters(in: .whitespacesAndNewlines)
      ?? canonicalAddress
  }

  private static func isASCIIDigit(_ character: Character) -> Bool {
    character.unicodeScalars.count == 1
      && character.unicodeScalars.first.map { (48...57).contains($0.value) } == true
  }

  private static let ignoredAddressCharacters: Set<Character> = ["-", "(", ")", "."]
}
