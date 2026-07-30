import Darwin
import Foundation
import Testing

@testable import DJIO

struct ATTransportWorkerTests {
  @Test func continuouslyRoutesCMTIAndCompletesInteractiveCMGS() async throws {
    let modem = try PseudoTerminalModem()
    defer { modem.close() }
    let transport = ATTransportWorker()
    let events = await transport.unsolicitedEvents()
    let incomingEvent = Task { () -> ATURC? in
      for await event in events where event.storage != nil {
        return event
      }
      return nil
    }

    let descriptor = try await transport.connect(
      supportedUSBDevices: [], preferredSerialPath: modem.path)
    guard case .serial(let path, _) = descriptor else {
      Issue.record("应使用伪终端串口")
      return
    }
    #expect(path == modem.path)

    let response = try await transport.perform([ATCommand("AT+CSQ", timeout: 2)]).first
    #expect(response?.raw.contains("+CSQ: 20,99") == true)
    #expect(response?.raw.contains("+CMTI") == false)
    let event = await incomingEvent.value
    #expect(event?.storage == "ME")
    #expect(event?.index == 17)

    let part = try SMSPDUEncoder(concatenationReferenceProvider: { 1 }).encode(
      recipient: "10086", body: "HELLO")[0]
    let submit = try await transport.sendMessagePDU(
      part.pdu, tpduLength: part.tpduLength, timeout: 2)
    #expect(submit.raw.contains("+CMGS: 42"))
    #expect(modem.submittedPDU == part.pdu)

    await transport.disconnect()
  }

  @Test func parsesCMTIFieldsDefensively() {
    #expect(ATURC(raw: "+CMTI: \"SM\",7").storage == "SM")
    #expect(ATURC(raw: "+CMTI: \"SM\",7").index == 7)
    #expect(ATURC(raw: "+cmti: \"me\",8").storage == "ME")
    #expect(ATURC(raw: "+CMTI: broken").storage == nil)
    #expect(ATURC(raw: "RING").index == nil)
  }

  @Test func parsesIncomingCallURCsDefensively() {
    #expect(ATURC(raw: "RING").kind == .ring)
    #expect(ATURC(raw: "+CRING: VOICE").kind == .ring)
    #expect(
      ATURC(raw: "+CLIP: \"8613800138000\",145,,,,0").kind
        == .callerID("+8613800138000"))
    #expect(ATURC(raw: "+CLIP: \"\",128").kind == .callerID(nil))
    #expect(ATURC(raw: "NO CARRIER").kind == .noCarrier)
    #expect(ATURC(raw: "BUSY").kind == .noCarrier)
    #expect(ATURC(raw: "NO ANSWER").kind == .noCarrier)
  }

  @Test func routesCallURCsWithoutRemovingCLCCCommandResponses() async throws {
    let modem = try PseudoTerminalModem(
      csqUnsolicitedLines: [
        "RING",
        "+CLIP: \"8613800138000\",145,,,,0",
      ])
    defer { modem.close() }
    let transport = ATTransportWorker()
    let events = await transport.unsolicitedEvents()
    let receivedEvents = Task { () -> [ATURC] in
      var result: [ATURC] = []
      for await event in events {
        result.append(event)
        if result.count == 2 { return result }
      }
      return result
    }
    _ = try await transport.connect(supportedUSBDevices: [], preferredSerialPath: modem.path)

    let signalResponse = try #require(
      await transport.perform([ATCommand("AT+CSQ", timeout: 2)]).first)
    #expect(signalResponse.raw.contains("+CSQ: 20,99"))
    #expect(!signalResponse.raw.contains("RING"))
    #expect(!signalResponse.raw.contains("+CLIP"))
    #expect(
      await receivedEvents.value.map(\.kind) == [
        .ring,
        .callerID("+8613800138000"),
      ])

    let callListResponse = try #require(
      await transport.perform([ATCommand("AT+CLCC", timeout: 2)]).first)
    #expect(callListResponse.raw.contains("+CLCC: 1,1,4,0,0,\"8613800138000\",145"))
    await transport.disconnect()
  }

  @Test func promptTimeoutRemainsSafeToRetry() async throws {
    let modem = try PseudoTerminalModem(promptBehavior: .ignore)
    defer { modem.close() }
    let transport = ATTransportWorker()
    _ = try await transport.connect(supportedUSBDevices: [], preferredSerialPath: modem.path)

    let part = try SMSPDUEncoder().encode(recipient: "10086", body: "HELLO")[0]
    do {
      _ = try await transport.sendMessagePDU(
        part.pdu, tpduLength: part.tpduLength, timeout: 0.2)
      Issue.record("等待提示符超时应当失败")
    } catch let error as ModemTransportError {
      guard case .timeout(let command, _) = error else {
        Issue.record("Ctrl-Z 之前应返回可重试的 timeout，实际为 \(error)")
        return
      }
      #expect(command.hasPrefix("AT+CMGS="))
    }
    for _ in 0..<100 where !modem.receivedEscape {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(modem.receivedEscape)
  }

  @Test func submissionTimeoutHasUnknownOutcome() async throws {
    let modem = try PseudoTerminalModem(submissionBehavior: .ignore)
    defer { modem.close() }
    let transport = ATTransportWorker()
    _ = try await transport.connect(supportedUSBDevices: [], preferredSerialPath: modem.path)

    let part = try SMSPDUEncoder().encode(recipient: "10086", body: "HELLO")[0]
    do {
      _ = try await transport.sendMessagePDU(
        part.pdu, tpduLength: part.tpduLength, timeout: 0.2)
      Issue.record("提交后缺少回执应当失败")
    } catch let error as ModemTransportError {
      guard case .submissionOutcomeUnknown = error else {
        Issue.record("Ctrl-Z 之后超时必须标记为结果未知，实际为 \(error)")
        return
      }
      #expect(error.localizedDescription.contains("重试可能导致重复发送"))
    }
    #expect(modem.submittedPDU == part.pdu)
  }

  @Test func submittedCMSFailureHasUnknownOutcome() async throws {
    let modem = try PseudoTerminalModem(submissionBehavior: .reject)
    defer { modem.close() }
    let transport = ATTransportWorker()
    _ = try await transport.connect(supportedUSBDevices: [], preferredSerialPath: modem.path)

    let part = try SMSPDUEncoder().encode(recipient: "10086", body: "HELLO")[0]
    do {
      _ = try await transport.sendMessagePDU(
        part.pdu, tpduLength: part.tpduLength, timeout: 1)
      Issue.record("提交后的模块错误应当失败")
    } catch let error as ModemTransportError {
      guard case .submissionOutcomeUnknown(let detail) = error else {
        Issue.record("Ctrl-Z 后的 +CMS ERROR 必须标记为结果未知，实际为 \(error)")
        return
      }
      #expect(detail.contains("+CMS ERROR: 500"))
    }
  }

  @Test func rejectionBeforePromptIsDefinite() async throws {
    let modem = try PseudoTerminalModem(promptBehavior: .reject)
    defer { modem.close() }
    let transport = ATTransportWorker()
    _ = try await transport.connect(supportedUSBDevices: [], preferredSerialPath: modem.path)

    let part = try SMSPDUEncoder().encode(recipient: "10086", body: "HELLO")[0]
    do {
      _ = try await transport.sendMessagePDU(
        part.pdu, tpduLength: part.tpduLength, timeout: 1)
      Issue.record("提示符之前的模块拒绝应当失败")
    } catch let error as ModemTransportError {
      guard case .modemRejected(_, let response) = error else {
        Issue.record("Ctrl-Z 前的 +CMS ERROR 应是确定失败，实际为 \(error)")
        return
      }
      #expect(response.contains("+CMS ERROR: 302"))
      #expect(modem.submittedPDU == nil)
    }
  }

  @Test func rejectionAfterCMGSReferenceHasUnknownOutcome() async throws {
    let modem = try PseudoTerminalModem(submissionBehavior: .referenceThenReject)
    defer { modem.close() }
    let transport = ATTransportWorker()
    _ = try await transport.connect(supportedUSBDevices: [], preferredSerialPath: modem.path)

    let part = try SMSPDUEncoder().encode(recipient: "10086", body: "HELLO")[0]
    do {
      _ = try await transport.sendMessagePDU(
        part.pdu, tpduLength: part.tpduLength, timeout: 1)
      Issue.record("收到 +CMGS 回执后又报错时不应报告确定失败")
    } catch let error as ModemTransportError {
      guard case .submissionOutcomeUnknown(let detail) = error else {
        Issue.record("收到 +CMGS 回执后的错误必须标记为结果未知，实际为 \(error)")
        return
      }
      #expect(detail.contains("+CMS ERROR: 500"))
    }
  }

  @Test func successfulFinalResultWithoutCMGSReferenceIsUnknown() async throws {
    let modem = try PseudoTerminalModem(submissionBehavior: .succeedWithoutReference)
    defer { modem.close() }
    let transport = ATTransportWorker()
    _ = try await transport.connect(supportedUSBDevices: [], preferredSerialPath: modem.path)

    let part = try SMSPDUEncoder().encode(recipient: "10086", body: "HELLO")[0]
    do {
      _ = try await transport.sendMessagePDU(
        part.pdu, tpduLength: part.tpduLength, timeout: 1)
      Issue.record("缺少 +CMGS 回执时不应报告发送成功")
    } catch let error as ModemTransportError {
      guard case .submissionOutcomeUnknown = error else {
        Issue.record("缺少 +CMGS 回执必须标记为结果未知，实际为 \(error)")
        return
      }
    }
  }

  @Test func reconnectsAfterIdleReaderDetectsDisconnect() async throws {
    let firstModem = try PseudoTerminalModem()
    let transport = ATTransportWorker()
    _ = try await transport.connect(
      supportedUSBDevices: [], preferredSerialPath: firstModem.path)
    firstModem.close()
    try await Task.sleep(for: .milliseconds(350))

    let secondModem = try PseudoTerminalModem()
    defer { secondModem.close() }
    let descriptor = try await transport.connect(
      supportedUSBDevices: [], preferredSerialPath: secondModem.path)
    guard case .serial(let path, _) = descriptor else {
      Issue.record("重连后应使用新的伪终端串口")
      return
    }
    #expect(path == secondModem.path)
    let response = try await transport.perform([ATCommand("AT+CSQ", timeout: 1)]).first
    #expect(response?.raw.contains("+CSQ: 20,99") == true)
    await transport.disconnect()
  }

  @Test func connectedTransportDeinitializesWithoutExplicitDisconnect() async throws {
    let modem = try PseudoTerminalModem()
    defer { modem.close() }

    let transportReference = try await makeReleasedConnectedTransport(path: modem.path)
    for _ in 0..<100 where transportReference.value != nil {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(transportReference.value == nil)
  }

  @Test func lastReferenceReleasedOnStateQueueDoesNotDeadlock() async throws {
    let modem = try PseudoTerminalModem()
    defer { modem.close() }
    let stateQueue = DispatchQueue(label: "com.djio.tests.transport-state")
    var transport: ATTransportWorker? = ATTransportWorker(stateQueue: stateQueue)
    let transportReference = WeakReference(try #require(transport))
    _ = try await transport?.connect(
      supportedUSBDevices: [], preferredSerialPath: modem.path)

    let releaseTransport = DispatchSemaphore(value: 0)
    await withCheckedContinuation { continuation in
      stateQueue.async {
        guard let retainedTransport = transportReference.value else {
          continuation.resume()
          return
        }
        continuation.resume()
        releaseTransport.wait()
        withExtendedLifetime(retainedTransport) {}
      }
    }
    transport = nil
    releaseTransport.signal()

    for _ in 0..<100 where transportReference.value != nil {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(transportReference.value == nil)
  }

}

private final class WeakReference<Value: AnyObject>: @unchecked Sendable {
  weak var value: Value?

  init(_ value: Value) {
    self.value = value
  }
}

private func makeReleasedConnectedTransport(path: String) async throws
  -> WeakReference<ATTransportWorker>
{
  let transport = ATTransportWorker()
  let reference = WeakReference(transport)
  _ = try await transport.connect(supportedUSBDevices: [], preferredSerialPath: path)
  return reference
}

private final class PseudoTerminalModem: @unchecked Sendable {
  enum PromptBehavior: Equatable {
    case send
    case ignore
    case reject
  }

  enum SubmissionBehavior {
    case succeed
    case succeedWithoutReference
    case ignore
    case reject
    case referenceThenReject
  }

  let path: String

  private let master: Int32
  private let bootstrapSlave: Int32
  private let queue = DispatchQueue(label: "com.djio.tests.fake-modem")
  private let lock = NSLock()
  private var isClosed = false
  private var submittedPDUStorage: String?
  private var receivedEscapeStorage = false
  private let promptBehavior: PromptBehavior
  private let submissionBehavior: SubmissionBehavior
  private let csqUnsolicitedLines: [String]

  var submittedPDU: String? {
    lock.withLock { submittedPDUStorage }
  }

  var receivedEscape: Bool {
    lock.withLock { receivedEscapeStorage }
  }

  init(
    promptBehavior: PromptBehavior = .send,
    submissionBehavior: SubmissionBehavior = .succeed,
    csqUnsolicitedLines: [String] = ["+CMTI: \"ME\",17"]
  ) throws {
    self.promptBehavior = promptBehavior
    self.submissionBehavior = submissionBehavior
    self.csqUnsolicitedLines = csqUnsolicitedLines
    var masterDescriptor: Int32 = -1
    var slaveDescriptor: Int32 = -1
    var name = [CChar](repeating: 0, count: 1_024)
    guard openpty(&masterDescriptor, &slaveDescriptor, &name, nil, nil) == 0 else {
      throw POSIXError(.ENXIO)
    }
    master = masterDescriptor
    bootstrapSlave = slaveDescriptor
    path = String(cString: name)
    _ = fcntl(master, F_SETFL, O_NONBLOCK)
    queue.async { [weak self] in self?.run() }
  }

  func close() {
    let shouldClose = lock.withLock { () -> Bool in
      guard !isClosed else { return false }
      isClosed = true
      return true
    }
    guard shouldClose else { return }

    // The fake modem owns every read and write on this queue. Wait for its loop
    // to observe isClosed before releasing descriptors that the OS may reuse.
    queue.sync {}
    Darwin.close(master)
    Darwin.close(bootstrapSlave)
  }

  private func run() {
    var current: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 1_024)
    while !lock.withLock({ isClosed }) {
      let count = buffer.withUnsafeMutableBytes { bytes in
        Darwin.read(master, bytes.baseAddress, bytes.count)
      }
      if count < 0, errno == EAGAIN {
        usleep(10_000)
        continue
      }
      guard count > 0 else { return }
      for byte in buffer.prefix(count) {
        if byte == 0x1B {
          lock.withLock { receivedEscapeStorage = true }
          current.removeAll(keepingCapacity: true)
        } else if byte == 0x1A {
          let pdu = String(decoding: current, as: UTF8.self)
          lock.withLock { submittedPDUStorage = pdu }
          current.removeAll(keepingCapacity: true)
          switch submissionBehavior {
          case .succeed: write("\r\n+CMGS: 42\r\n\r\nOK\r\n")
          case .succeedWithoutReference: write("\r\nOK\r\n")
          case .ignore: break
          case .reject: write("\r\n+CMS ERROR: 500\r\n")
          case .referenceThenReject: write("\r\n+CMGS: 42\r\n\r\n+CMS ERROR: 500\r\n")
          }
        } else if byte == 0x0D {
          let command = String(decoding: current, as: UTF8.self)
          current.removeAll(keepingCapacity: true)
          respond(to: command)
        } else if byte != 0x0A {
          current.append(byte)
        }
      }
    }
  }

  private func respond(to command: String) {
    switch command {
    case "AT":
      write("\r\nOK\r\n")
    case "AT+CMGF=?":
      write("\r\n+CMGF: (0,1)\r\n\r\nOK\r\n")
    case "AT+CSQ":
      let unsolicited = csqUnsolicitedLines.map { "\($0)\r\n" }.joined()
      write("\r\n\(unsolicited)+CSQ: 20,99\r\n\r\nOK\r\n")
    case "AT+CLCC":
      write("\r\n+CLCC: 1,1,4,0,0,\"8613800138000\",145\r\n\r\nOK\r\n")
    case let value where value.hasPrefix("AT+CMGS="):
      if promptBehavior == .send {
        write("\r\n> ")
      } else if promptBehavior == .reject {
        write("\r\n+CMS ERROR: 302\r\n")
      }
    default:
      write("\r\nOK\r\n")
    }
  }

  private func write(_ string: String) {
    let data = Data(string.utf8)
    data.withUnsafeBytes { bytes in
      guard let baseAddress = bytes.baseAddress else { return }
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(master, baseAddress.advanced(by: offset), bytes.count - offset)
        guard count > 0 else { return }
        offset += count
      }
    }
  }
}
