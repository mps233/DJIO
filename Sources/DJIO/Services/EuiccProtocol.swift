import Foundation

struct EuiccAPDUClient: Sendable {
  let transport: any ATTransporting

  func inspect() async throws -> EuiccSnapshot {
    let channel = try await openLogicalChannel()
    do {
      let eidResponse = try await sendES10x(Data([0xBF, 0x3E, 0x03, 0x5C, 0x01, 0x5A]), channel: channel)
      guard let eid = TLVParser.find(tag: 0x5A, in: eidResponse)?.value.hexString.uppercased(), eid.count == 32 else {
        throw EuiccError.invalidResponse("未找到有效 EID")
      }

      let profilesResponse = try await sendES10x(Data([0xBF, 0x2D, 0x00]), channel: channel)
      let profiles = TLVParser.profileList(from: profilesResponse)
      try? await closeLogicalChannel(channel)
      return EuiccSnapshot(available: true, eid: eid, profiles: profiles, lastUpdated: Date(), issue: nil)
    } catch {
      try? await closeLogicalChannel(channel)
      throw error
    }
  }

  private func openLogicalChannel() async throws -> UInt8 {
    let response = try await transmit(Data([0x00, 0x70, 0x00, 0x00, 0x01]))
    guard response.statusWord == 0x9000, let channel = response.data.first, channel > 0, channel < 20 else {
      throw EuiccError.notEuicc
    }

    let aid: Data = Data(hex: "A0000005591010FFFFFFFF8900000100")
    let select = Data([channel, 0xA4, 0x04, 0x00, UInt8(aid.count)]) + aid
    let selected = try await transmit(select)
    guard selected.statusWord == 0x9000 || selected.sw1 == 0x61 else {
      throw EuiccError.notEuicc
    }
    if selected.sw1 == 0x61 {
      _ = try await transmit(Data([channel, 0xC0, 0x00, 0x00, selected.sw2]))
    }
    return channel
  }

  private func closeLogicalChannel(_ channel: UInt8) async throws {
    _ = try await transmit(Data([0x00, 0x70, 0x80, channel, 0x00]))
  }

  private func sendES10x(_ body: Data, channel: UInt8) async throws -> Data {
    guard body.count <= 255 else { throw EuiccError.unsupported("eSIM 请求分段尚未启用") }
    let request = Data([0x80 | channel, 0xE2, 0x91, 0x00, UInt8(body.count)]) + body
    return try await transmitWithContinuation(request)
  }

  private func transmitWithContinuation(_ apdu: Data) async throws -> Data {
    var response = try await transmit(apdu)
    var data = response.data
    while response.sw1 == 0x61 {
      response = try await transmit(Data([apdu[0], 0xC0, 0x00, 0x00, response.sw2]))
      data.append(response.data)
    }
    guard response.statusWord == 0x9000 else {
      throw EuiccError.modemRejected(String(format: "APDU 状态字 %04X", response.statusWord))
    }
    return data
  }

  private func transmit(_ apdu: Data) async throws -> APDUResponse {
    let hex = apdu.hexString
    let response = try await transport.perform([
      ATCommand("AT+CSIM=\(apdu.count * 2),\"\(hex)\"", timeout: 30)
    ]).first?.raw ?? ""
    guard let payload = EuiccCSIM.payload(from: response) else {
      throw EuiccError.invalidResponse(response)
    }
    guard payload.count >= 2 else { throw EuiccError.invalidResponse("CSIM 响应过短") }
    return APDUResponse(data: Data(payload.dropLast(2)), sw1: payload[payload.count - 2], sw2: payload[payload.count - 1])
  }
}

private struct APDUResponse: Sendable {
  let data: Data
  let sw1: UInt8
  let sw2: UInt8
  var statusWord: UInt16 { UInt16(sw1) << 8 | UInt16(sw2) }
}

private enum TLVParser {
  struct Node {
    let tag: Int
    let value: Data
  }

  static func find(tag: Int, in data: Data) -> Node? {
    parse(data).first { $0.tag == tag } ?? parse(data).compactMap { find(tag: tag, in: $0.value) }.first
  }

  static func profileList(from data: Data) -> [EuiccProfile] {
    let entries = descendants(in: data, matching: 0xE3)
    return entries.enumerated().compactMap { index, entry in
      let nodes = parse(entry.value)
      guard let iccidNode = nodes.first(where: { $0.tag == 0x5A }) else { return nil }
      let iccid = iccidNode.value.gsmBcdString
      guard !iccid.isEmpty else { return nil }
      let state: EuiccProfileState
      switch nodes.first(where: { $0.tag == 0x9F70 })?.value.last {
      case 0: state = .disabled
      case 1: state = .enabled
      default: state = .unknown
      }
      return EuiccProfile(
        id: iccid,
        iccid: iccid,
        nickname: nodes.first(where: { $0.tag == 0x90 })?.value.utf8String,
        serviceProviderName: nodes.first(where: { $0.tag == 0x91 })?.value.utf8String,
        profileName: nodes.first(where: { $0.tag == 0x92 })?.value.utf8String,
        state: state,
        profileClass: nodes.first(where: { $0.tag == 0x95 })?.value.first.map { String($0) }
      )
    }
  }

  private static func descendants(in data: Data, matching tag: Int) -> [Node] {
    parse(data).flatMap { node in
      (node.tag == tag ? [node] : []) + descendants(in: node.value, matching: tag)
    }
  }

  private static func parse(_ data: Data) -> [Node] {
    var result: [Node] = []
    var index = 0
    while index < data.count {
      guard let (tag, tagLength) = readTag(data, at: index) else { break }
      index += tagLength
      guard let (length, lengthBytes) = readLength(data, at: index) else { break }
      index += lengthBytes
      guard index + length <= data.count else { break }
      result.append(Node(tag: tag, value: Data(data[index..<(index + length)])))
      index += length
    }
    return result
  }

  private static func readTag(_ data: Data, at index: Int) -> (Int, Int)? {
    guard index < data.count else { return nil }
    var tag = Int(data[index])
    var length = 1
    if data[index] & 0x1F == 0x1F {
      tag &= 0xFF
      while index + length < data.count {
        let byte = data[index + length]
        tag = (tag << 8) | Int(byte)
        length += 1
        if byte & 0x80 == 0 { break }
      }
    }
    return (tag, length)
  }

  private static func readLength(_ data: Data, at index: Int) -> (Int, Int)? {
    guard index < data.count else { return nil }
    let first = data[index]
    if first & 0x80 == 0 { return (Int(first), 1) }
    let byteCount = Int(first & 0x7F)
    guard byteCount > 0, byteCount <= 4, index + byteCount < data.count else { return nil }
    var value = 0
    for offset in 0..<byteCount { value = (value << 8) | Int(data[index + 1 + offset]) }
    return (value, byteCount + 1)
  }
}

private extension Data {
  var utf8String: String? {
    guard let value = String(data: self, encoding: .utf8), !value.isEmpty else { return nil }
    return value
  }

  var gsmBcdString: String {
    var result = ""
    for byte in self {
      let low = byte & 0x0F
      let high = (byte >> 4) & 0x0F
      if low <= 9 { result.append(String(low)) }
      if high <= 9 { result.append(String(high)) }
    }
    return result
  }
}
