import CModemBridge
import Foundation

struct ATCommand: Sendable {
  let text: String
  let timeout: TimeInterval

  init(_ text: String, timeout: TimeInterval = 3) {
    self.text = text
    self.timeout = timeout
  }
}

struct ATResponse: Sendable {
  let command: String
  let raw: String
}

enum ATURCKind: Sendable, Equatable {
  case messageStorage
  case ring
  case callerID(String?)
  case noCarrier
  case other
}

struct ATURC: Sendable, Equatable {
  let raw: String
  let storage: String?
  let index: Int?
  let kind: ATURCKind

  init(raw: String) {
    let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    self.raw = normalized
    let uppercased = normalized.uppercased()
    if uppercased == "RING" || uppercased.hasPrefix("+CRING:") {
      storage = nil
      index = nil
      kind = .ring
      return
    }
    if uppercased == "NO CARRIER" || uppercased == "BUSY" || uppercased == "NO ANSWER" {
      storage = nil
      index = nil
      kind = .noCarrier
      return
    }
    if uppercased.hasPrefix("+CLIP:") {
      let fields = ATFieldParser.fields(in: normalized, prefix: "+CLIP:")
      storage = nil
      index = nil
      kind = .callerID(
        ATFieldParser.phoneNumber(
          fields?.first,
          type: fields.flatMap { $0.count > 1 ? $0[1] : nil }
        ))
      return
    }
    guard uppercased.hasPrefix("+CMTI:") else {
      storage = nil
      index = nil
      kind = .other
      return
    }
    kind = .messageStorage
    let fields = normalized.dropFirst("+CMTI:".count).split(
      separator: ",", omittingEmptySubsequences: false)
    guard fields.count >= 2 else {
      storage = nil
      index = nil
      return
    }
    let parsedStorage = fields[0]
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
      .uppercased()
    storage = parsedStorage.isEmpty ? nil : parsedStorage
    index = Int(fields[1].trimmingCharacters(in: .whitespacesAndNewlines))
  }
}

enum ModemTransportError: LocalizedError, Sendable {
  case notConnected(String)
  case modemRejected(command: String, response: String)
  case timeout(command: String, detail: String)
  case disconnected(String)
  case io(String)
  case invalidCommand(String)
  case submissionOutcomeUnknown(String)

  var errorDescription: String? {
    switch self {
    case .notConnected(let detail): return detail
    case .modemRejected(let command, let response): return "模块拒绝 \(command)：\(response)"
    case .timeout(let command, let detail): return "\(command) 超时：\(detail)"
    case .disconnected(let detail): return detail
    case .io(let detail): return detail
    case .invalidCommand(let detail): return detail
    case .submissionOutcomeUnknown(let detail):
      return "短信提交结果未知，重试可能导致重复发送：\(detail)"
    }
  }
}

protocol ATTransporting: Sendable {
  func connect(
    supportedUSBDevices: [USBDeviceIdentifier],
    preferredSerialPath: String?
  ) async throws -> ATTransportDescriptor
  func perform(_ commands: [ATCommand]) async throws -> [ATResponse]
  func sendMessagePDU(_ pdu: String, tpduLength: Int, timeout: TimeInterval) async throws
    -> ATResponse
  func unsolicitedEvents() async -> AsyncStream<ATURC>
  func disconnect() async
}

extension ATTransporting {
  func sendMessagePDU(_ pdu: String, tpduLength: Int, timeout: TimeInterval) async throws
    -> ATResponse
  {
    throw ModemTransportError.invalidCommand("当前 AT 传输不支持发送短信")
  }

  func unsolicitedEvents() async -> AsyncStream<ATURC> {
    AsyncStream { $0.finish() }
  }
}

final class ATTransportWorker: ATTransporting, @unchecked Sendable {
  private enum PendingPhase {
    case response
    case prompt
    case awaitingPayload
    case submitResponse
  }

  private final class PendingTransaction: @unchecked Sendable {
    let command: String
    var phase: PendingPhase
    var raw = ""
    var sawMessageReference = false
    var result: Result<ATResponse, ModemTransportError>?
    let promptSignal = DispatchSemaphore(value: 0)
    let finalSignal = DispatchSemaphore(value: 0)

    init(command: String, phase: PendingPhase) {
      self.command = command
      self.phase = phase
    }
  }

  private final class ReaderSession: @unchecked Sendable {
    let handle: OpaquePointer

    private let lock = NSLock()
    private var stopped = false

    init(handle: OpaquePointer) {
      self.handle = handle
    }

    var isStopped: Bool {
      lock.withLock { stopped }
    }

    func stop() {
      lock.withLock { stopped = true }
    }
  }

  private let queue = DispatchQueue(label: "com.djio.at-transport", qos: .userInitiated)
  private let readerQueue = DispatchQueue(
    label: "com.djio.at-transport.reader", qos: .userInitiated)
  private let stateQueue: DispatchQueue
  private let readerGroup = DispatchGroup()
  private let queueKey = DispatchSpecificKey<UInt8>()
  private let readerQueueKey = DispatchSpecificKey<UInt8>()
  private let stateQueueKey = DispatchSpecificKey<UInt8>()

  private var handle: OpaquePointer?
  private var descriptor: ATTransportDescriptor?
  private var readerRunning = false
  private var readerSession: ReaderSession?
  private var inputBuffer = ""
  private var pending: PendingTransaction?
  private var readerFailure: ModemTransportError?
  private var eventContinuations: [UUID: AsyncStream<ATURC>.Continuation] = [:]

  init(
    stateQueue: DispatchQueue = DispatchQueue(label: "com.djio.at-transport.state")
  ) {
    self.stateQueue = stateQueue
    queue.setSpecific(key: queueKey, value: 1)
    readerQueue.setSpecific(key: readerQueueKey, value: 1)
    stateQueue.setSpecific(key: stateQueueKey, value: 1)
  }

  deinit {
    if DispatchQueue.getSpecific(key: readerQueueKey) != nil {
      closeLocked(waitForReader: false)
    } else if DispatchQueue.getSpecific(key: stateQueueKey) != nil {
      closeLocked()
    } else {
      withQueueSync { closeLocked() }
    }
    withStateQueueSync {
      for continuation in eventContinuations.values {
        continuation.finish()
      }
      eventContinuations.removeAll()
    }
  }

  func connect(
    supportedUSBDevices: [USBDeviceIdentifier],
    preferredSerialPath: String? = nil
  ) async throws -> ATTransportDescriptor {
    try await withCheckedThrowingContinuation { continuation in
      queue.async {
        let readerFailure = self.withStateQueueSync { self.readerFailure }
        if let descriptor = self.descriptor,
          self.handle != nil,
          readerFailure == nil,
          Self.isCompatible(descriptor, with: supportedUSBDevices)
        {
          continuation.resume(returning: descriptor)
          return
        }
        do {
          let descriptor = try self.connectLocked(
            supportedUSBDevices: supportedUSBDevices,
            preferredSerialPath: preferredSerialPath
          )
          continuation.resume(returning: descriptor)
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  func perform(_ commands: [ATCommand]) async throws -> [ATResponse] {
    try await withCheckedThrowingContinuation { continuation in
      queue.async {
        guard self.handle != nil else {
          continuation.resume(throwing: ModemTransportError.notConnected("AT 控制通道尚未连接"))
          return
        }
        if let readerFailure = self.withStateQueueSync({ self.readerFailure }) {
          self.closeLocked()
          continuation.resume(throwing: readerFailure)
          return
        }
        do {
          var responses: [ATResponse] = []
          responses.reserveCapacity(commands.count)
          for command in commands {
            responses.append(try self.commandLocked(command))
          }
          continuation.resume(returning: responses)
        } catch {
          if Self.invalidatesConnection(error) {
            self.closeLocked()
          }
          continuation.resume(throwing: error)
        }
      }
    }
  }

  func sendMessagePDU(_ pdu: String, tpduLength: Int, timeout: TimeInterval = 60) async throws
    -> ATResponse
  {
    try await withCheckedThrowingContinuation { continuation in
      queue.async {
        if let readerFailure = self.withStateQueueSync({ self.readerFailure }) {
          self.closeLocked()
          continuation.resume(throwing: readerFailure)
          return
        }
        do {
          let response = try self.sendMessagePDULocked(
            pdu, tpduLength: tpduLength, timeout: timeout)
          continuation.resume(returning: response)
        } catch {
          if Self.invalidatesConnection(error) {
            self.closeLocked()
          }
          continuation.resume(throwing: error)
        }
      }
    }
  }

  func unsolicitedEvents() async -> AsyncStream<ATURC> {
    let id = UUID()
    return AsyncStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
      self.withStateQueueSync {
        self.eventContinuations[id] = continuation
      }
      continuation.onTermination = { [weak self] _ in
        self?.stateQueue.async {
          self?.eventContinuations.removeValue(forKey: id)
        }
      }
    }
  }

  func disconnect() async {
    await withCheckedContinuation { continuation in
      queue.async {
        self.closeLocked()
        continuation.resume()
      }
    }
  }

  func currentDescriptor() async -> ATTransportDescriptor? {
    await withCheckedContinuation { continuation in
      queue.async {
        continuation.resume(returning: self.descriptor)
      }
    }
  }

  private func connectLocked(
    supportedUSBDevices: [USBDeviceIdentifier],
    preferredSerialPath: String?
  ) throws -> ATTransportDescriptor {
    closeLocked()
    var usbFailures: [(device: USBDeviceIdentifier, detail: String)] = []
    for device in supportedUSBDevices {
      var usbInfo = CBUSBInfo()
      var usbError = [CChar](repeating: 0, count: 512)
      let usbHandle = usbError.withUnsafeMutableBufferPointer { errorBuffer in
        cb_at_open_usb(
          device.vendorID,
          device.productID,
          &usbInfo,
          errorBuffer.baseAddress,
          errorBuffer.count
        )
      }
      if let usbHandle {
        let usbDescriptor = USBTransportDescriptor(
          sessionID: UUID(),
          vendorID: usbInfo.vendor_id,
          productID: usbInfo.product_id,
          bus: usbInfo.bus_number,
          address: usbInfo.device_address,
          interfaceNumber: usbInfo.interface_number,
          alternateSetting: usbInfo.alternate_setting,
          endpointIn: usbInfo.endpoint_in,
          endpointOut: usbInfo.endpoint_out
        )
        handle = usbHandle
        descriptor = .usb(usbDescriptor)
        startReaderLocked(handle: usbHandle)
        return .usb(usbDescriptor)
      }
      usbFailures.append((device, String(cString: usbError)))
    }

    var serialFailures: [String] = []
    for path in Self.serialCandidates(preferred: preferredSerialPath) {
      var serialError = [CChar](repeating: 0, count: 512)
      let serialHandle = path.withCString { pathPointer in
        serialError.withUnsafeMutableBufferPointer { errorBuffer in
          cb_at_open_serial(pathPointer, 115_200, errorBuffer.baseAddress, errorBuffer.count)
        }
      }
      if let serialHandle {
        let serialDescriptor = ATTransportDescriptor.serial(path: path, sessionID: UUID())
        handle = serialHandle
        descriptor = serialDescriptor
        startReaderLocked(handle: serialHandle)
        return serialDescriptor
      }
      let detail = String(cString: serialError)
      if !detail.isEmpty {
        serialFailures.append(detail)
      }
    }

    let usbDetail = Self.usbFailureDescription(
      failures: usbFailures,
      supportedDevices: supportedUSBDevices
    )
    let serialDetail = serialFailures.joined(separator: "；")
    let detail = serialDetail.isEmpty ? usbDetail : "\(usbDetail)；串口回退失败：\(serialDetail)"
    throw ModemTransportError.notConnected(
      detail.isEmpty ? "未找到可用的 AT 控制通道" : detail
    )
  }

  private func commandLocked(_ command: ATCommand) throws -> ATResponse {
    guard let handle else { throw ModemTransportError.notConnected("AT 控制通道尚未连接") }
    let trimmed = command.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.uppercased().hasPrefix("AT") else {
      throw ModemTransportError.invalidCommand("AT 指令必须以 AT 开头")
    }
    guard command.timeout.isFinite, command.timeout > 0 else {
      throw ModemTransportError.invalidCommand("AT 指令超时时间必须大于 0")
    }

    let transaction = try beginTransaction(command: trimmed, phase: .response)
    do {
      try writeLocked(Data((trimmed + "\r").utf8), handle: handle, timeout: command.timeout)
    } catch {
      fail(transaction, with: error)
      throw error
    }

    guard transaction.finalSignal.wait(timeout: deadline(after: command.timeout)) == .success else {
      let error = ModemTransportError.timeout(
        command: trimmed, detail: "等待最终响应超时")
      fail(transaction, with: error)
      throw error
    }
    return try result(of: transaction).get()
  }

  private func sendMessagePDULocked(
    _ rawPDU: String,
    tpduLength: Int,
    timeout: TimeInterval
  ) throws -> ATResponse {
    guard let handle else { throw ModemTransportError.notConnected("AT 控制通道尚未连接") }
    guard timeout.isFinite, timeout > 0 else {
      throw ModemTransportError.invalidCommand("短信发送超时时间必须大于 0")
    }
    let pdu = rawPDU.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard pdu.count >= 4, pdu.count.isMultiple(of: 2),
      pdu.allSatisfy({ $0.isASCII && $0.isHexDigit })
    else {
      throw ModemTransportError.invalidCommand("短信 PDU 必须是完整的十六进制字节")
    }
    let bytes = Self.hexBytes(pdu)
    guard let serviceCenterLength = bytes.first,
      Int(serviceCenterLength) + 1 <= bytes.count,
      tpduLength == bytes.count - Int(serviceCenterLength) - 1,
      tpduLength > 0
    else {
      throw ModemTransportError.invalidCommand("短信 TPDU 长度与 PDU 内容不一致")
    }
    let command = "AT+CMGS=\(tpduLength)"
    let transaction = try beginTransaction(command: command, phase: .prompt)
    do {
      try writeLocked(Data((command + "\r").utf8), handle: handle, timeout: min(timeout, 10))
    } catch {
      fail(transaction, with: error)
      throw error
    }

    guard transaction.promptSignal.wait(timeout: deadline(after: min(timeout, 10))) == .success
    else {
      try? writeLocked(Data([0x1B]), handle: handle, timeout: min(timeout, 1))
      let error = ModemTransportError.timeout(command: command, detail: "等待 > 提示符超时")
      fail(transaction, with: error)
      throw error
    }
    let earlyResult = stateQueue.sync { () -> Result<ATResponse, ModemTransportError>? in
      if let result = transaction.result { return result }
      guard pending === transaction, transaction.phase == .awaitingPayload else {
        return .failure(.io("AT 短信提交状态无效"))
      }
      transaction.phase = .submitResponse
      return nil
    }
    if let earlyResult { return try earlyResult.get() }
    var payload = Data(pdu.utf8)
    payload.append(0x1A)
    do {
      try writeLocked(payload, handle: handle, timeout: min(timeout, 10))
    } catch {
      let unknown = ModemTransportError.submissionOutcomeUnknown(error.localizedDescription)
      fail(transaction, with: unknown)
      throw unknown
    }

    guard transaction.finalSignal.wait(timeout: deadline(after: timeout)) == .success else {
      let error = ModemTransportError.submissionOutcomeUnknown("等待 +CMGS 回执超时")
      fail(transaction, with: error)
      throw error
    }
    switch result(of: transaction) {
    case .success(let response):
      return response
    case .failure(let error):
      switch error {
      case .modemRejected: throw error
      case .invalidCommand, .notConnected, .timeout: throw error
      case .disconnected, .io:
        throw ModemTransportError.submissionOutcomeUnknown(error.localizedDescription)
      case .submissionOutcomeUnknown: throw error
      }
    }
  }

  private func beginTransaction(command: String, phase: PendingPhase) throws -> PendingTransaction {
    try stateQueue.sync {
      guard pending == nil else {
        throw ModemTransportError.io("AT 响应状态机仍有未完成指令")
      }
      let transaction = PendingTransaction(command: command, phase: phase)
      pending = transaction
      return transaction
    }
  }

  private func result(of transaction: PendingTransaction)
    -> Result<ATResponse, ModemTransportError>
  {
    stateQueue.sync {
      transaction.result
        ?? .failure(ModemTransportError.io("AT 响应状态机没有返回结果"))
    }
  }

  private func fail(_ transaction: PendingTransaction, with error: any Error) {
    let transportError = error as? ModemTransportError ?? .io(error.localizedDescription)
    stateQueue.sync {
      guard transaction.result == nil else { return }
      transaction.result = .failure(transportError)
      if pending === transaction { pending = nil }
      transaction.promptSignal.signal()
      transaction.finalSignal.signal()
    }
  }

  private func writeLocked(_ data: Data, handle: OpaquePointer, timeout: TimeInterval) throws {
    var error = [CChar](repeating: 0, count: 1024)
    let timeoutMilliseconds = Self.timeoutMilliseconds(timeout)
    let result = data.withUnsafeBytes { bytes in
      error.withUnsafeMutableBufferPointer { errorBuffer in
        cb_at_write(
          handle,
          bytes.bindMemory(to: UInt8.self).baseAddress,
          bytes.count,
          timeoutMilliseconds,
          errorBuffer.baseAddress,
          errorBuffer.count
        )
      }
    }
    guard result == CB_AT_RESULT_OK else {
      throw Self.transportError(
        result: result,
        command: "写入 AT 通道",
        response: "",
        detail: String(cString: error)
      )
    }
  }

  private func startReaderLocked(handle: OpaquePointer) {
    let session = ReaderSession(handle: handle)
    readerSession = session
    withStateQueueSync {
      inputBuffer = ""
      pending = nil
      readerFailure = nil
    }
    readerRunning = true
    readerGroup.enter()
    let readerGroup = readerGroup
    readerQueue.async { [weak self, session] in
      defer { readerGroup.leave() }
      Self.readerLoop(
        session: session,
        receive: { [weak self] input in
          guard let self else { return false }
          self.routeInput(input)
          return true
        },
        fail: { [weak self] error in
          guard let self else { return }
          self.stateQueue.sync {
            self.readerFailure = error
            self.finishPending(with: .failure(error))
          }
        }
      )
    }
  }

  private static func readerLoop(
    session: ReaderSession,
    receive: (String) -> Bool,
    fail: (ModemTransportError) -> Void
  ) {
    var buffer = [UInt8](repeating: 0, count: 4096)
    while !session.isStopped {
      var count = 0
      var error = [CChar](repeating: 0, count: 1024)
      let result = buffer.withUnsafeMutableBufferPointer { bufferPointer in
        error.withUnsafeMutableBufferPointer { errorPointer in
          cb_at_read(
            session.handle,
            bufferPointer.baseAddress,
            bufferPointer.count,
            &count,
            200,
            errorPointer.baseAddress,
            errorPointer.count
          )
        }
      }
      if session.isStopped { break }
      if result == CB_AT_RESULT_TIMEOUT { continue }
      if result == CB_AT_RESULT_OK {
        if count > 0 {
          guard receive(String(decoding: buffer.prefix(count), as: UTF8.self)) else { break }
        }
        continue
      }
      let transportError = Self.transportError(
        result: result,
        command: "读取 AT 通道",
        response: "",
        detail: String(cString: error)
      )
      fail(transportError)
      break
    }
  }

  private func routeInput(_ input: String) {
    stateQueue.sync {
      inputBuffer.append(input)
      if inputBuffer.utf8.count > 256 * 1024 {
        inputBuffer.removeAll(keepingCapacity: true)
        finishPending(with: .failure(.io("AT 输入缓冲区超过 256 KiB")))
        return
      }
      routePromptIfPresent()
      while let delimiter = inputBuffer.firstIndex(where: \.isNewline) {
        let line = String(inputBuffer[..<delimiter])
        var next = inputBuffer.index(after: delimiter)
        while next < inputBuffer.endIndex, inputBuffer[next].isNewline {
          next = inputBuffer.index(after: next)
        }
        inputBuffer.removeSubrange(inputBuffer.startIndex..<next)
        routeLine(line)
        routePromptIfPresent()
      }
    }
  }

  private func routePromptIfPresent() {
    guard let transaction = pending, transaction.phase == .prompt,
      let promptIndex = inputBuffer.firstIndex(of: ">")
    else { return }

    let beforePrompt = String(inputBuffer[..<promptIndex])
    for line in beforePrompt.split(whereSeparator: \.isNewline) {
      routeLine(String(line))
    }
    var next = inputBuffer.index(after: promptIndex)
    if next < inputBuffer.endIndex, inputBuffer[next] == " " {
      next = inputBuffer.index(after: next)
    }
    inputBuffer.removeSubrange(inputBuffer.startIndex..<next)
    guard pending === transaction, transaction.result == nil else { return }
    transaction.raw.append("> ")
    transaction.phase = .awaitingPayload
    transaction.promptSignal.signal()
  }

  private func routeLine(_ rawLine: String) {
    let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !line.isEmpty else { return }
    if Self.isUnsolicitedLine(line) {
      yield(ATURC(raw: line))
      return
    }
    guard let transaction = pending else {
      yield(ATURC(raw: line))
      return
    }
    transaction.raw.append("\r\n\(line)\r\n")
    if transaction.raw.utf8.count > 256 * 1024 {
      finishPending(with: .failure(.io("AT 响应超过 256 KiB")))
      return
    }

    if transaction.phase == .submitResponse, Self.isMessageReferenceLine(line) {
      transaction.sawMessageReference = true
    }

    if Self.isSuccessLine(line) {
      if transaction.command.hasPrefix("AT+CMGS=") {
        guard transaction.phase == .submitResponse else {
          finishPending(with: .failure(.io("模块未返回短信 PDU 提示符")))
          return
        }
        guard transaction.sawMessageReference else {
          finishPending(
            with: .failure(
              .submissionOutcomeUnknown("模块返回 OK，但缺少 +CMGS 回执")))
          return
        }
      }
      finishPending(
        with: .success(ATResponse(command: transaction.command, raw: transaction.raw)))
    } else if Self.isErrorLine(line) {
      if transaction.command.hasPrefix("AT+CMGS="), transaction.phase == .submitResponse {
        finishPending(
          with: .failure(
            .submissionOutcomeUnknown("短信提交后的最终响应为 \(line)")))
      } else {
        finishPending(
          with: .failure(
            .modemRejected(command: transaction.command, response: transaction.raw)))
      }
    }
  }

  private func finishPending(with result: Result<ATResponse, ModemTransportError>) {
    guard let transaction = pending, transaction.result == nil else { return }
    transaction.result = result
    pending = nil
    transaction.promptSignal.signal()
    transaction.finalSignal.signal()
  }

  private func yield(_ event: ATURC) {
    for continuation in eventContinuations.values {
      continuation.yield(event)
    }
  }

  private func closeLocked(waitForReader: Bool = true) {
    if readerRunning {
      readerSession?.stop()
      withStateQueueSync {
        finishPending(with: .failure(.disconnected("AT 控制通道已关闭")))
      }
      if waitForReader {
        readerGroup.wait()
      }
      readerRunning = false
    }
    if let handle {
      cb_at_close(handle)
    }
    handle = nil
    descriptor = nil
    readerSession = nil
    withStateQueueSync {
      inputBuffer = ""
      pending = nil
      readerFailure = nil
    }
  }

  private static func isSuccessLine(_ line: String) -> Bool {
    line.caseInsensitiveCompare("OK") == .orderedSame
  }

  private static func isErrorLine(_ line: String) -> Bool {
    let uppercased = line.uppercased()
    return uppercased == "ERROR" || uppercased.hasPrefix("+CME ERROR:")
      || uppercased.hasPrefix("+CMS ERROR:")
  }

  private static func isMessageReferenceLine(_ line: String) -> Bool {
    let uppercased = line.uppercased()
    guard uppercased.hasPrefix("+CMGS:"),
      let field = line.dropFirst("+CMGS:".count).split(separator: ",").first,
      let reference = Int(field.trimmingCharacters(in: .whitespacesAndNewlines))
    else { return false }
    return reference >= 0
  }

  private static func isUnsolicitedLine(_ line: String) -> Bool {
    let uppercased = line.uppercased()
    return uppercased.hasPrefix("+CMTI:") || uppercased.hasPrefix("+CDSI:")
      || uppercased.hasPrefix("+CLIP:")
      || uppercased == "RING" || uppercased.hasPrefix("+CRING:")
      || uppercased == "NO CARRIER" || uppercased == "BUSY" || uppercased == "NO ANSWER"
      || uppercased == "SMS READY" || uppercased == "CALL READY"
  }

  private static func hexBytes(_ value: String) -> [UInt8] {
    stride(from: 0, to: value.count, by: 2).compactMap { offset in
      let start = value.index(value.startIndex, offsetBy: offset)
      let end = value.index(start, offsetBy: 2)
      return UInt8(value[start..<end], radix: 16)
    }
  }

  private static func timeoutMilliseconds(_ timeout: TimeInterval) -> Int32 {
    Int32(max(1, min(Double(Int32.max), timeout * 1_000)))
  }

  private func deadline(after timeout: TimeInterval) -> DispatchTime {
    .now() + .milliseconds(Int(Self.timeoutMilliseconds(timeout)))
  }

  private func withQueueSync<T>(_ operation: () throws -> T) rethrows -> T {
    if DispatchQueue.getSpecific(key: queueKey) != nil {
      return try operation()
    }
    return try queue.sync(execute: operation)
  }

  private func withStateQueueSync<T>(_ operation: () throws -> T) rethrows -> T {
    if DispatchQueue.getSpecific(key: stateQueueKey) != nil {
      return try operation()
    }
    return try stateQueue.sync(execute: operation)
  }

  private static func transportError(
    result: CBATResult,
    command: String,
    response: String,
    detail: String
  ) -> ModemTransportError {
    let fallback = detail.isEmpty ? "AT 传输失败" : detail
    switch result {
    case CB_AT_RESULT_MODEM_ERROR:
      return .modemRejected(command: command, response: response)
    case CB_AT_RESULT_TIMEOUT:
      return .timeout(command: command, detail: fallback)
    case CB_AT_RESULT_DISCONNECTED:
      return .disconnected(fallback)
    case CB_AT_RESULT_INVALID_ARGUMENT:
      return .invalidCommand(fallback)
    default:
      return .io(fallback)
    }
  }

  private static func invalidatesConnection(_ error: any Error) -> Bool {
    guard let error = error as? ModemTransportError else { return false }
    switch error {
    case .timeout, .disconnected, .io, .submissionOutcomeUnknown: return true
    case .notConnected, .modemRejected, .invalidCommand: return false
    }
  }

  private static func serialCandidates(preferred: String?) -> [String] {
    var candidates: [String] = []
    if let preferred, !preferred.isEmpty {
      candidates.append(preferred)
    }
    let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
    let markers = ["usbmodem", "usbserial", "wchusbserial", "slab_usb", "quectel", "dji"]
    let discovered =
      names
      .filter { name in
        guard name.hasPrefix("cu.") else { return false }
        let lowercased = name.lowercased()
        return markers.contains { lowercased.contains($0) }
      }
      .sorted()
      .map { "/dev/\($0)" }
    for path in discovered where !candidates.contains(path) {
      candidates.append(path)
    }
    return candidates
  }

  private static func isCompatible(
    _ descriptor: ATTransportDescriptor,
    with supportedUSBDevices: [USBDeviceIdentifier]
  ) -> Bool {
    switch descriptor {
    case .usb(let usb): return supportedUSBDevices.contains(usb.deviceIdentifier)
    case .serial: return true
    }
  }

  private static func usbFailureDescription(
    failures: [(device: USBDeviceIdentifier, detail: String)],
    supportedDevices: [USBDeviceIdentifier]
  ) -> String {
    let supportedDescription = supportedDevices.map(\.description).joined(separator: "、")
    guard !supportedDescription.isEmpty else {
      return "未配置支持的 USB ID"
    }

    let detectedFailures = failures.filter { !$0.detail.contains("was not found") }
    let summary: String
    if detectedFailures.isEmpty {
      summary = "未检测到支持的 4G 模块"
    } else {
      summary = detectedFailures.map { failure in
        localizedUSBError(failure.detail, device: failure.device)
      }.joined(separator: "；")
    }
    return "\(summary)（支持 USB ID：\(supportedDescription)）"
  }

  private static func localizedUSBError(_ value: String, device: USBDeviceIdentifier) -> String {
    if value.contains("No vendor-specific bulk") {
      return "检测到 \(device)，但没有可用的 AT bulk interface：\(value)"
    }
    if value.contains("Unable to open USB device") {
      return "检测到 \(device)，但无法打开 USB 设备：\(value)"
    }
    if value.contains("did not pass the SMS AT probe") {
      return "检测到 \(device)，但短信 AT 探测失败：\(value)"
    }
    return "\(device)：\(value.isEmpty ? "USB AT 探测失败" : value)"
  }
}
