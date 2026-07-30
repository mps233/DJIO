import Foundation

struct ParsedRadioDetails: Sendable, Equatable {
  var accessTechnology: String?
  var frequencyBand: String?
  var channel: Int?
  var signalRSRP: Int?
  var signalRSRQ: Int?
  var signalSINR: Double?
}

struct ATIncomingVoiceCall: Sendable, Equatable {
  let modemIdentifier: Int
  let callerNumber: String?
}

enum ATFieldParser {
  static func fields(in line: String, prefix: String) -> [String]? {
    guard line.count >= prefix.count,
      String(line.prefix(prefix.count)).caseInsensitiveCompare(prefix) == .orderedSame
    else {
      return nil
    }
    let payload = line.dropFirst(prefix.count)
    var fields: [String] = []
    var field = ""
    var isQuoted = false
    for character in payload {
      switch character {
      case "\"": isQuoted.toggle()
      case "," where !isQuoted:
        fields.append(field.trimmingCharacters(in: .whitespacesAndNewlines))
        field.removeAll(keepingCapacity: true)
      default: field.append(character)
      }
    }
    fields.append(field.trimmingCharacters(in: .whitespacesAndNewlines))
    return fields
  }

  static func phoneNumber(_ value: String?, type: String?) -> String? {
    guard let value else { return nil }
    let number = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !number.isEmpty else { return nil }
    if Int(type?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") == 145,
      !number.hasPrefix("+")
    {
      return "+\(number)"
    }
    return number
  }
}

struct ATResponseParser {
  func sentMessageReference(from response: String) -> Int? {
    guard let line = normalizedLines(response).first(where: { $0.hasPrefix("+CMGS:") }),
      let field = line.dropFirst("+CMGS:".count).split(separator: ",").first
    else {
      return nil
    }
    return Int(field.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  func incomingVoiceCalls(from response: String) -> [ATIncomingVoiceCall] {
    normalizedLines(response).compactMap { line in
      guard let fields = atFields(in: line, prefix: "+CLCC:"), fields.count >= 5,
        let modemIdentifier = Int(fields[0]), modemIdentifier >= 0,
        Int(fields[1]) == 1,
        let status = Int(fields[2]), status == 4 || status == 5,
        Int(fields[3]) == 0
      else {
        return nil
      }
      return ATIncomingVoiceCall(
        modemIdentifier: modemIdentifier,
        callerNumber: ATFieldParser.phoneNumber(
          fields.count > 5 ? fields[5] : nil,
          type: fields.count > 6 ? fields[6] : nil
        )
      )
    }
  }

  func storedPDU(from response: String, storage: String, index: Int) -> ModemStoredPDU? {
    let lines = normalizedLines(response)
    guard let headerIndex = lines.firstIndex(where: { $0.hasPrefix("+CMGR:") }),
      lines.indices.contains(headerIndex + 1),
      Self.isHex(lines[headerIndex + 1]),
      let fields = atFields(in: lines[headerIndex], prefix: "+CMGR:"),
      let status = fields.first
    else {
      return nil
    }
    return ModemStoredPDU(
      storage: storage,
      index: index,
      pdu: lines[headerIndex + 1].uppercased(),
      isRead: Self.isReadStatus(status)
    )
  }

  func storedPDUs(from response: String, storage: String) -> [ModemStoredPDU] {
    let lines =
      response
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .components(separatedBy: "\n")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }

    var records: [ModemStoredPDU] = []
    var index = 0
    while index + 1 < lines.count {
      let header = lines[index]
      guard header.hasPrefix("+CMGL:") else {
        index += 1
        continue
      }
      let fields = header.dropFirst("+CMGL:".count).split(
        separator: ",", omittingEmptySubsequences: false)
      guard
        let first = fields.first,
        let modemIndex = Int(first.trimmingCharacters(in: .whitespaces)),
        Self.isHex(lines[index + 1])
      else {
        index += 1
        continue
      }
      let status = fields.count > 1 ? String(fields[1]) : ""
      records.append(
        ModemStoredPDU(
          storage: storage,
          index: modemIndex,
          pdu: lines[index + 1].uppercased(),
          isRead: Self.isReadStatus(status)
        ))
      index += 2
    }
    return records
  }

  func signalRSSI(from response: String) -> Int? {
    guard let line = normalizedLines(response).first(where: { $0.hasPrefix("+CSQ:") }) else {
      return nil
    }
    let fields = line.dropFirst("+CSQ:".count).split(separator: ",")
    guard let first = fields.first, let raw = Int(first.trimmingCharacters(in: .whitespaces)),
      raw != 99
    else { return nil }
    return -113 + raw * 2
  }

  func registration(from response: String) -> String {
    guard
      let line = normalizedLines(response).first(where: {
        $0.hasPrefix("+CEREG:") || $0.hasPrefix("+CREG:")
      })
    else {
      return "未知"
    }
    let fields = line.split(separator: ":", maxSplits: 1).last?.split(separator: ",") ?? []
    let statusField = fields.count >= 2 ? fields[1] : fields.first
    guard let statusField,
      let raw = Int(statusField.trimmingCharacters(in: .whitespacesAndNewlines))
    else { return "未知" }
    switch raw {
    case 1: return "已注册"
    case 5: return "漫游"
    case 2: return "正在搜索"
    case 3: return "注册被拒绝"
    case 0: return "未注册"
    default: return "未知"
    }
  }

  func operatorName(from response: String) -> String? {
    guard let line = normalizedLines(response).first(where: { $0.hasPrefix("+COPS:") }) else {
      return nil
    }
    guard let fields = atFields(in: line, prefix: "+COPS:"), fields.count >= 3 else {
      return nil
    }
    return nonempty(fields[2])
  }

  func operatorAccessTechnology(from response: String) -> String? {
    guard let line = normalizedLines(response).first(where: { $0.hasPrefix("+COPS:") }),
      let fields = atFields(in: line, prefix: "+COPS:"), fields.count >= 4,
      let code = Int(fields[3])
    else {
      return nil
    }
    switch code {
    case 0: return "GSM"
    case 1: return "GSM Compact"
    case 2: return "UMTS"
    case 3: return "EDGE"
    case 4: return "HSDPA"
    case 5: return "HSUPA"
    case 6: return "HSPA"
    case 7: return "LTE"
    case 8: return "EC-GSM-IoT"
    case 9: return "NB-IoT"
    case 10: return "LTE (5GC)"
    case 11: return "5G NR"
    case 12: return "5G NG-RAN"
    default: return nil
    }
  }

  func simStatus(from response: String) -> String? {
    guard let line = normalizedLines(response).first(where: { $0.hasPrefix("+CPIN:") }),
      let fields = atFields(in: line, prefix: "+CPIN:"),
      let rawStatus = fields.first.flatMap(nonempty)
    else {
      return nil
    }
    switch rawStatus.uppercased() {
    case "READY": return "就绪"
    case "SIM PIN": return "需要 SIM PIN"
    case "SIM PUK": return "需要 SIM PUK"
    case "SIM PIN2": return "需要 SIM PIN2"
    case "SIM PUK2": return "需要 SIM PUK2"
    case "PH-NET PIN": return "需要网络解锁码"
    case "NOT INSERTED": return "未插入"
    default: return rawStatus
    }
  }

  func firmwareRevision(from response: String) -> String? {
    for line in normalizedLines(response) {
      let uppercased = line.uppercased()
      if uppercased == "OK" || uppercased == "ERROR" || uppercased == "AT+CGMR"
        || uppercased.hasPrefix("+CME ERROR:")
      {
        continue
      }
      if line.hasPrefix("+CGMR:") {
        return nonempty(String(line.dropFirst("+CGMR:".count)))
      }
      if uppercased.hasPrefix("REVISION:") {
        return nonempty(String(line.dropFirst("REVISION:".count)))
      }
      return line
    }
    return nil
  }

  func smsStorageUsage(from response: String, storage: String) -> SMSStorageUsage? {
    guard let line = normalizedLines(response).first(where: { $0.hasPrefix("+CPMS:") }),
      let fields = atFields(in: line, prefix: "+CPMS:")
    else {
      return nil
    }

    if fields.count >= 2, let used = Int(fields[0]), let total = Int(fields[1]) {
      return validStorageUsage(storage: storage, used: used, total: total)
    }

    var index = 0
    while index + 2 < fields.count {
      if fields[index].caseInsensitiveCompare(storage) == .orderedSame,
        let used = Int(fields[index + 1]),
        let total = Int(fields[index + 2])
      {
        return validStorageUsage(storage: storage, used: used, total: total)
      }
      index += 3
    }
    return nil
  }

  func networkInformation(from response: String) -> ParsedRadioDetails {
    guard let line = normalizedLines(response).first(where: { $0.hasPrefix("+QNWINFO:") }),
      let fields = atFields(in: line, prefix: "+QNWINFO:")
    else {
      return ParsedRadioDetails()
    }
    return ParsedRadioDetails(
      accessTechnology: fields.first.flatMap(nonempty),
      frequencyBand: fields.count > 2 ? nonempty(fields[2]) : nil,
      channel: fields.count > 3 ? nonnegativeInteger(fields[3]) : nil
    )
  }

  func servingCellDetails(from response: String) -> ParsedRadioDetails {
    let rows = normalizedLines(response).compactMap { line -> [String]? in
      guard line.hasPrefix("+QENG:") else { return nil }
      return atFields(in: line, prefix: "+QENG:")
    }
    for fields in rows {
      let details = servingCellDetails(from: fields)
      if details.accessTechnology != nil || details.signalRSRP != nil {
        return details
      }
    }
    return ParsedRadioDetails()
  }

  private func normalizedLines(_ response: String) -> [String] {
    response
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .components(separatedBy: "\n")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  private func servingCellDetails(from fields: [String]) -> ParsedRadioDetails {
    guard let first = fields.first?.uppercased() else { return ParsedRadioDetails() }

    if first == "SERVINGCELL", fields.count > 2 {
      let technology = fields[2]
      let uppercasedTechnology = technology.uppercased()
      if uppercasedTechnology.contains("NR5G-SA"), fields.count > 14 {
        return ParsedRadioDetails(
          accessTechnology: technology,
          frequencyBand: bandDescription(fields[10], technology: technology),
          channel: nonnegativeInteger(fields[9]),
          signalRSRP: metricInteger(fields[12]),
          signalRSRQ: metricInteger(fields[13]),
          signalSINR: metricDouble(fields[14])
        )
      }
      if uppercasedTechnology.contains("LTE"), fields.count > 16 {
        return ParsedRadioDetails(
          accessTechnology: technology,
          frequencyBand: bandDescription(fields[9], technology: technology),
          channel: nonnegativeInteger(fields[8]),
          signalRSRP: metricInteger(fields[13]),
          signalRSRQ: metricInteger(fields[14]),
          signalSINR: metricDouble(fields[16])
        )
      }
    }

    if first == "LTE", fields.count > 14 {
      return ParsedRadioDetails(
        accessTechnology: fields[0],
        frequencyBand: bandDescription(fields[7], technology: fields[0]),
        channel: nonnegativeInteger(fields[6]),
        signalRSRP: metricInteger(fields[11]),
        signalRSRQ: metricInteger(fields[12]),
        signalSINR: metricDouble(fields[14])
      )
    }
    return ParsedRadioDetails()
  }

  private func atFields(in line: String, prefix: String) -> [String]? {
    ATFieldParser.fields(in: line, prefix: prefix)
  }

  private func nonempty(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func nonnegativeInteger(_ value: String) -> Int? {
    guard let parsed = Int(value), parsed >= 0 else { return nil }
    return parsed
  }

  private func metricInteger(_ value: String) -> Int? {
    guard let parsed = metricDouble(value) else { return nil }
    return Int(parsed.rounded())
  }

  private func metricDouble(_ value: String) -> Double? {
    guard let parsed = Double(value), parsed > -1_000, parsed < 1_000,
      parsed != 99, parsed != 255
    else {
      return nil
    }
    return parsed
  }

  private func bandDescription(_ value: String, technology: String) -> String? {
    guard let value = nonempty(value) else { return nil }
    if value.uppercased().contains("BAND") { return value }
    if technology.uppercased().contains("NR") { return "NR Band n\(value)" }
    if technology.uppercased().contains("LTE") { return "LTE Band \(value)" }
    return value
  }

  private func validStorageUsage(storage: String, used: Int, total: Int) -> SMSStorageUsage? {
    guard used >= 0, total >= 0, used <= total else { return nil }
    return SMSStorageUsage(storage: storage, used: used, total: total)
  }

  private static func isHex(_ value: String) -> Bool {
    !value.isEmpty && value.count.isMultiple(of: 2) && value.allSatisfy { $0.isHexDigit }
  }

  private static func isReadStatus(_ value: String) -> Bool {
    let normalized =
      value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
      .uppercased()
    return normalized != "0" && normalized != "REC UNREAD"
  }
}
