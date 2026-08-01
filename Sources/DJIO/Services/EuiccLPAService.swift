import Foundation

struct EuiccActivationCode: Sendable, Equatable {
  let rawValue: String
  let smdpAddress: String
  let matchingID: String

  init(_ value: String) throws {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let fields = normalized.split(separator: "$", omittingEmptySubsequences: false).map(String.init)
    guard fields.count >= 3, fields[0].uppercased() == "LPA:1" else {
      throw EuiccError.invalidResponse("激活码必须以 LPA:1$ 开头")
    }
    let address = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
    let matchingID = fields[2].trimmingCharacters(in: .whitespacesAndNewlines)
    guard Self.isValidServerAddress(address), !matchingID.isEmpty else {
      throw EuiccError.invalidResponse("激活码缺少有效的 SM-DP+ 地址或 Matching ID")
    }
    rawValue = normalized
    smdpAddress = address
    self.matchingID = matchingID
  }

  private static func isValidServerAddress(_ value: String) -> Bool {
    guard !value.isEmpty, value.count <= 253, !value.contains("/"), !value.contains(":"), !value.contains(" ") else {
      return false
    }
    return value.split(separator: ".").allSatisfy { label in
      !label.isEmpty && label.count <= 63
        && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
  }
}

struct EuiccDownloadResult: Sendable, Equatable {
  let message: String
}

struct EuiccLPAService: Sendable {
  let transport: any ATTransporting

  func download(
    activationCode: EuiccActivationCode,
    confirmationCode: String?,
    onProgress: @escaping @Sendable (String) async -> Void
  ) async throws -> EuiccDownloadResult {
    return try await run(
      arguments: ["profile", "download"],
      credentials: DownloadCredentials(
        activationCode: activationCode,
        confirmationCode: confirmationCode
      ),
      redactedValues: [activationCode.rawValue, activationCode.matchingID],
      onProgress: onProgress
    )
  }

  func setProfileEnabled(
    iccid: String,
    enabled: Bool,
    onProgress: @escaping @Sendable (String) async -> Void
  ) async throws -> EuiccDownloadResult {
    guard !iccid.isEmpty else {
      throw EuiccError.invalidResponse("eSIM ICCID 为空")
    }
    return try await run(
      arguments: ["profile", enabled ? "enable" : "disable", iccid, "1"],
      credentials: nil,
      redactedValues: [iccid],
      onProgress: onProgress
    )
  }

  func setProfileNickname(
    iccid: String,
    nickname: String?,
    onProgress: @escaping @Sendable (String) async -> Void
  ) async throws -> EuiccDownloadResult {
    return try await run(
      arguments: Self.profileNicknameArguments(iccid: iccid, nickname: nickname),
      credentials: nil,
      redactedValues: [iccid],
      onProgress: onProgress
    )
  }

  static func profileNicknameArguments(iccid: String, nickname: String?) throws -> [String] {
    let normalizedICCID = iccid.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedICCID.isEmpty else {
      throw EuiccError.invalidResponse("eSIM ICCID 为空")
    }
    var arguments = ["profile", "nickname", normalizedICCID]
    let normalizedNickname = nickname?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let normalizedNickname, !normalizedNickname.isEmpty {
      arguments.append(normalizedNickname)
    }
    return arguments
  }

  private struct DownloadCredentials: Sendable {
    let activationCode: EuiccActivationCode
    let confirmationCode: String?
  }

  private func run(
    arguments: [String],
    credentials: DownloadCredentials?,
    redactedValues: [String],
    onProgress: @escaping @Sendable (String) async -> Void
  ) async throws -> EuiccDownloadResult {
    guard let executableURL = Self.executableURL() else {
      throw EuiccError.unsupported("DJIO 未找到内置的 LPA helper，请重新构建应用")
    }

    let process = Process()
    let input = Pipe()
    let output = Pipe()
    let errors = Pipe()
    process.executableURL = executableURL
    process.arguments = arguments
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors
    var environment = ProcessInfo.processInfo.environment
    environment["LPAC_APDU"] = "stdio"
    environment["LPAC_HTTP"] = "curl"
    environment["LPAC_CUSTOM_ES10X_MSS"] = "120"
    if credentials != nil {
      environment["DJIO_LPAC_STDIN_REQUEST"] = "1"
    } else {
      environment.removeValue(forKey: "DJIO_LPAC_STDIN_REQUEST")
    }
    process.environment = environment

    var apduSession = LPAAPDUSession(transport: transport)
    var finalMessage: String?
    var finalData: String?
    var finalCode: Int?
    var suppliedDownloadRequest = false
    let errorTask = Task.detached(priority: .utility) {
      errors.fileHandleForReading.readDataToEndOfFile()
    }

    do {
      try process.run()
      for try await line in output.fileHandleForReading.bytes.lines {
        try Task.checkCancellation()
        guard let json = line.data(using: .utf8),
          let object = try JSONSerialization.jsonObject(with: json) as? [String: Any],
          let type = object["type"] as? String,
          let payload = object["payload"] as? [String: Any]
        else { continue }

        switch type {
        case "apdu":
          let response = await apduSession.response(for: payload)
          try Self.write(response, to: input.fileHandleForWriting)
        case "djio":
          guard payload["func"] as? String == "download_request",
            let credentials,
            !suppliedDownloadRequest
          else {
            throw EuiccError.invalidResponse("LPA helper 请求了未知或重复的私密数据")
          }
          suppliedDownloadRequest = true
          try Self.writeDownloadRequest(
            activationCode: credentials.activationCode,
            confirmationCode: credentials.confirmationCode,
            to: input.fileHandleForWriting
          )
        case "progress":
          if let message = payload["message"] as? String, !message.isEmpty {
            await onProgress(Self.localizedProgress(message))
          }
        case "lpa":
          finalCode = payload["code"] as? Int
          finalMessage = payload["message"] as? String
          finalData = payload["data"] as? String
        default:
          continue
        }
      }
      process.waitUntilExit()
      let stderr = String(data: await errorTask.value, encoding: .utf8) ?? ""
      if process.terminationStatus != 0 || finalCode != 0 {
        let detail = finalData?.nilIfEmpty
          ?? finalMessage?.nilIfEmpty
          ?? stderr.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
          ?? "LPA helper 退出码 \(process.terminationStatus)"
        throw EuiccError.modemRejected(Self.redacted(detail, values: redactedValues))
      }
      return EuiccDownloadResult(message: finalMessage?.nilIfEmpty ?? "eSIM 操作已完成")
    } catch {
      if process.isRunning { process.terminate() }
      await apduSession.closeIfNeeded()
      throw error
    }
  }

  private static func executableURL() -> URL? {
    if let override = ProcessInfo.processInfo.environment["DJIO_LPAC_PATH"],
      FileManager.default.isExecutableFile(atPath: override)
    {
      return URL(fileURLWithPath: override)
    }
    let bundled = Bundle.main.bundleURL
      .appendingPathComponent("Contents/Helpers/lpac", isDirectory: false)
    if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
    let development = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("Packaging/Helpers/lpac/lpac", isDirectory: false)
    return FileManager.default.isExecutableFile(atPath: development.path) ? development : nil
  }

  private static func write(_ object: [String: Any], to handle: FileHandle) throws {
    var data = try JSONSerialization.data(withJSONObject: object)
    data.append(0x0A)
    try handle.write(contentsOf: data)
  }

  private static func writeDownloadRequest(
    activationCode: EuiccActivationCode,
    confirmationCode: String?,
    to handle: FileHandle
  ) throws {
    var request: [String: Any] = ["activationCode": activationCode.rawValue]
    if let confirmationCode = confirmationCode?.trimmingCharacters(in: .whitespacesAndNewlines),
      !confirmationCode.isEmpty
    {
      request["confirmationCode"] = confirmationCode
    }
    try write(request, to: handle)
  }

  private static func localizedProgress(_ value: String) -> String {
    switch value {
    case "es10b_get_euicc_challenge_and_info": return "正在读取 eSIM 卡信息"
    case "es9p_initiate_authentication": return "正在连接 SM-DP+"
    case "es10b_authenticate_server": return "正在验证运营商服务器"
    case "es9p_authenticate_client": return "正在验证 eSIM 卡"
    case "es10b_prepare_download": return "正在准备 eSIM"
    case "es9p_get_bound_profile_package": return "正在下载加密的 eSIM 数据"
    case "es10b_load_bound_profile_package": return "正在写入 eSIM 卡"
    default: return "正在处理 eSIM"
    }
  }

  private static func redacted(_ value: String, values: [String]) -> String {
    values.reduce(value) { result, value in
      result.replacingOccurrences(of: value, with: "<已隐藏 eSIM 标识>")
    }
  }
}

private struct LPAAPDUSession: Sendable {
  let transport: any ATTransporting
  private var channel: UInt8?

  init(transport: any ATTransporting) {
    self.transport = transport
    channel = nil
  }

  mutating func response(for payload: [String: Any]) async -> [String: Any] {
    guard let function = payload["func"] as? String else { return response(ecode: -1) }
    do {
      switch function {
      case "connect":
        return response(ecode: 0)
      case "disconnect":
        try await closeIfNeededThrowing()
        return response(ecode: 0)
      case "logic_channel_open":
        guard let parameter = payload["param"] as? String else { return response(ecode: -1) }
        let opened = try await open(aid: Data(hex: parameter))
        return response(ecode: Int(opened))
      case "logic_channel_close":
        try await closeIfNeededThrowing()
        return response(ecode: 0)
      case "transmit":
        guard let parameter = payload["param"] as? String else { return response(ecode: -1) }
        let result = try await transmit(Data(hex: parameter), patchLogicalChannel: true)
        return response(ecode: 0, data: result.hexString)
      default:
        return response(ecode: -1)
      }
    } catch {
      return response(ecode: -1)
    }
  }

  mutating func closeIfNeeded() async {
    try? await closeIfNeededThrowing()
  }

  private mutating func open(aid: Data) async throws -> UInt8 {
    try await closeIfNeededThrowing()
    let opened = try await transmit(Data([0x00, 0x70, 0x00, 0x00, 0x01]), patchLogicalChannel: false)
    guard opened.count == 3, opened.suffix(2) == Data([0x90, 0x00]),
      let newChannel = opened.first, newChannel > 0, newChannel <= 3
    else { throw EuiccError.notEuicc }

    let selected = try await transmit(
      Data([newChannel, 0xA4, 0x04, 0x00, UInt8(aid.count)]) + aid,
      patchLogicalChannel: false
    )
    guard selected.count >= 2 else { throw EuiccError.notEuicc }
    let sw1 = selected[selected.count - 2]
    let sw2 = selected[selected.count - 1]
    guard sw1 == 0x90 || sw1 == 0x61 else { throw EuiccError.notEuicc }
    if sw1 == 0x61 {
      _ = try await transmit(Data([newChannel, 0xC0, 0x00, 0x00, sw2]), patchLogicalChannel: false)
    }
    channel = newChannel
    return newChannel
  }

  private mutating func closeIfNeededThrowing() async throws {
    guard let channel else { return }
    self.channel = nil
    _ = try await transmit(Data([0x00, 0x70, 0x80, channel, 0x00]), patchLogicalChannel: false)
  }

  private func transmit(_ rawAPDU: Data, patchLogicalChannel: Bool) async throws -> Data {
    var apdu = rawAPDU
    if patchLogicalChannel, let channel, !apdu.isEmpty {
      apdu[apdu.startIndex] = (apdu[apdu.startIndex] & 0xFC) | channel
    }
    let response = try await transport.perform([
      ATCommand("AT+CSIM=\(apdu.count * 2),\"\(apdu.hexString)\"", timeout: 120)
    ]).first?.raw ?? ""
    guard let payload = EuiccCSIM.payload(from: response) else {
      throw EuiccError.invalidResponse("CSIM 响应无法解析")
    }
    return payload
  }

  private func response(ecode: Int, data: String? = nil) -> [String: Any] {
    var payload: [String: Any] = ["ecode": ecode]
    if let data { payload["data"] = data }
    return ["type": "apdu", "payload": payload]
  }
}

enum EuiccCSIM {
  static func payload(from response: String) -> Data? {
    guard let line = response
      .replacingOccurrences(of: "\r", with: "\n")
      .split(separator: "\n")
      .map(String.init)
      .first(where: { $0.uppercased().hasPrefix("+CSIM:") }),
      let firstQuote = line.firstIndex(of: "\""),
      let lastQuote = line.lastIndex(of: "\""),
      lastQuote > firstQuote
    else { return nil }
    return Data(hex: String(line[line.index(after: firstQuote)..<lastQuote]))
  }
}

extension Data {
  init(hex: String) {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(hex.count / 2)
    var index = hex.startIndex
    while index < hex.endIndex {
      guard let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex), next > index,
        let byte = UInt8(hex[index..<next], radix: 16)
      else {
        self.init()
        return
      }
      bytes.append(byte)
      index = next
    }
    self.init(bytes)
  }

  var hexString: String { map { String(format: "%02X", $0) }.joined() }
}

private extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}
