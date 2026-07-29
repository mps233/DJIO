import Foundation
import Testing

@testable import CellularBridge

struct ModemServiceTests {
  private let singlePDU = "000404912143000842101021436500044F60597D"
  private let gsm7PDU = "00040481214300004210102143650005C82293F904"
  private let firstMultipartPDU = "00440491214300084210102143650008050003AA02014F60"
  private let secondMultipartPDU = "00440491214300084210102143650008050003AA0202597D"

  @Test func importsOnceAndUsesOnlyExactIndexCleanup() async throws {
    let (root, databaseURL) = temporaryDatabase()
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = FakeATTransport(smResponse: cmgl([(7, 0, singlePDU)]))
    let service = try ModemService(
      databaseURL: databaseURL, transport: transport, deletesImportedMessages: true)

    let first = try await service.poll()
    #expect(first.newMessages.count == 1)
    #expect(first.newMessages.first?.isRead == false)
    let firstBatches = await transport.recordedBatches()
    #expect(
      firstBatches.contains([
        "AT+CPMS=\"SM\",\"SM\",\"SM\"",
        "AT+CMGD=7,0",
      ]))
    #expect(
      !firstBatches.flatMap { $0 }.contains(where: {
        $0.hasPrefix("AT+CMGD=") && $0.hasSuffix(",4")
      }))

    let second = try await service.poll()
    #expect(second.newMessages.isEmpty)
    #expect(try await service.messages().count == 1)

    try await service.deleteLocalMessage(id: first.newMessages[0].id)
    let afterLocalDelete = try await service.poll()
    #expect(afterLocalDelete.newMessages.isEmpty)
    #expect(try await service.messages().isEmpty)

    let restartedTransport = FakeATTransport(smResponse: cmgl([(7, 0, singlePDU)]))
    let restartedService = try ModemService(
      databaseURL: databaseURL,
      transport: restartedTransport,
      deletesImportedMessages: false
    )
    #expect(try await restartedService.poll().newMessages.isEmpty)
    #expect(try await restartedService.messages().isEmpty)
  }

  @Test func keepsModuleMessagesByDefault() async throws {
    let (root, databaseURL) = temporaryDatabase()
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = FakeATTransport(smResponse: cmgl([(7, 0, singlePDU)]))
    let service = try ModemService(databaseURL: databaseURL, transport: transport)

    let result = try await service.poll()

    #expect(result.newMessages.count == 1)
    let commands = await transport.recordedBatches().flatMap { $0 }
    #expect(!commands.contains(where: { $0.hasPrefix("AT+CMGD=") }))
  }

  @Test func rejectedDeleteContinuesWithOtherExactIndexes() async throws {
    let (root, databaseURL) = temporaryDatabase()
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = FakeATTransport(
      smResponse: cmgl([
        (1, 0, singlePDU),
        (2, 0, gsm7PDU),
      ]))
    await transport.failNext(
      command: "AT+CMGD=2,0",
      with: .modemRejected(command: "AT+CMGD=2,0", response: "ERROR")
    )
    let service = try ModemService(
      databaseURL: databaseURL, transport: transport, deletesImportedMessages: true)

    let result = try await service.poll()
    #expect(result.newMessages.count == 2)
    #expect(result.warnings.contains(where: { $0.contains("模块拒绝清理 SM 第 2 条短信") }))
    let commands = await transport.recordedBatches().flatMap { $0 }
    #expect(commands.contains("AT+CMGD=2,0"))
    #expect(commands.contains("AT+CMGD=1,0"))
  }

  @Test func partLedgerRetriesAResidualMultipartIndex() async throws {
    let (root, databaseURL) = temporaryDatabase()
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = FakeATTransport(
      smResponse: cmgl([
        (1, 0, firstMultipartPDU),
        (2, 0, secondMultipartPDU),
      ]))
    await transport.failNext(
      command: "AT+CMGD=1,0",
      with: .disconnected("测试断线")
    )
    let service = try ModemService(
      databaseURL: databaseURL, transport: transport, deletesImportedMessages: true)

    var firstPollFailed = false
    do {
      _ = try await service.poll()
    } catch {
      firstPollFailed = true
    }
    #expect(firstPollFailed)
    #expect(try await service.messages().count == 1)

    await transport.setSMResponse(cmgl([(1, 0, firstMultipartPDU)]))
    let retry = try await service.poll()
    #expect(retry.newMessages.isEmpty)
    let commands = await transport.recordedBatches().flatMap { $0 }
    #expect(commands.filter { $0 == "AT+CMGD=1,0" }.count == 2)
  }

  @Test func transportFailureAbortsPollInsteadOfReportingReady() async throws {
    let (root, databaseURL) = temporaryDatabase()
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = FakeATTransport()
    await transport.failNext(command: "AT+CSQ", with: .disconnected("测试断线"))
    let service = try ModemService(databaseURL: databaseURL, transport: transport)

    var didThrow = false
    do {
      _ = try await service.poll()
    } catch {
      didThrow = true
    }
    #expect(didThrow)
    let commands = await transport.recordedBatches().flatMap { $0 }
    #expect(!commands.contains("AT+CMGL=4"))
  }

  @Test func optionalStatusRejectionBecomesAWarning() async throws {
    let (root, databaseURL) = temporaryDatabase()
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = FakeATTransport()
    await transport.failNext(
      command: "AT+COPS?",
      with: .modemRejected(command: "AT+COPS?", response: "ERROR")
    )
    let service = try ModemService(databaseURL: databaseURL, transport: transport)

    let result = try await service.poll()
    #expect(result.operatorName == nil)
    #expect(result.warnings.contains("模块不支持运营商查询"))
  }

  @Test func storageTimeoutStopsBeforeTheNextStorage() async throws {
    let (root, databaseURL) = temporaryDatabase()
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = FakeATTransport()
    await transport.failNext(
      command: "AT+CMGL=4",
      with: .timeout(command: "AT+CMGL=4", detail: "测试超时")
    )
    let service = try ModemService(databaseURL: databaseURL, transport: transport)

    var didThrow = false
    do {
      _ = try await service.poll()
    } catch {
      didThrow = true
    }
    #expect(didThrow)
    let batches = await transport.recordedBatches()
    #expect(batches.filter { $0.contains("AT+CMGL=4") }.count == 1)
    #expect(!batches.flatMap { $0 }.contains("AT+CPMS=\"ME\",\"ME\",\"ME\""))
  }

  @Test func modeSwitchWaitsForAnActivePoll() async throws {
    let (root, databaseURL) = temporaryDatabase()
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = FakeATTransport()
    await transport.pauseNext(command: "AT+CSQ")
    let service = try ModemService(databaseURL: databaseURL, transport: transport)

    let pollTask = Task { try? await service.poll() }
    await transport.waitUntilPaused()
    let switchTask = Task { try? await service.switchToECM(apn: nil) }
    try? await Task.sleep(nanoseconds: 50_000_000)

    let commandsBeforeRelease = await transport.recordedBatches().flatMap { $0 }
    #expect(!commandsBeforeRelease.contains("AT+QCFG=\"usbnet\",1"))

    await transport.releasePausedCommand()
    _ = await pollTask.value
    _ = await switchTask.value
    let commandsAfterRelease = await transport.recordedBatches().flatMap { $0 }
    #expect(commandsAfterRelease.contains("AT+QCFG=\"usbnet\",1"))
    #expect(!commandsAfterRelease.contains("AT+CFUN=1,1"))
  }

  @Test func modeSwitchAcceptsExpectedUSBReenumerationDisconnect() async throws {
    let (root, databaseURL) = temporaryDatabase()
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = FakeATTransport()
    await transport.failNext(
      command: "AT+QCFG=\"usbnet\",1",
      with: .disconnected("测试 USB 重新枚举")
    )
    let service = try ModemService(databaseURL: databaseURL, transport: transport)

    try await service.switchToECM(apn: nil)

    let commands = await transport.recordedBatches().flatMap { $0 }
    #expect(commands.contains("AT+QCFG=\"usbnet\",1"))
    #expect(!commands.contains("AT+CFUN=1,1"))
  }

  @Test func passesAllSupportedUSBDevicesInPriorityOrder() async throws {
    let (root, databaseURL) = temporaryDatabase()
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = FakeATTransport()
    let service = try ModemService(databaseURL: databaseURL, transport: transport)

    _ = try await service.poll()

    let requestedDevices = await transport.recordedSupportedUSBDevices()
    #expect(
      requestedDevices.first == [
        USBDeviceIdentifier(vendorID: 0x2C7C, productID: 0x0125),
        USBDeviceIdentifier(vendorID: 0x2CA3, productID: 0x4006),
      ])
  }

  @Test func liveMessagesInOnePollShareMacTimeAndUseModemOrder() async throws {
    let (root, databaseURL) = temporaryDatabase()
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = FakeATTransport()
    let service = try ModemService(
      databaseURL: databaseURL,
      transport: transport,
      deletesImportedMessages: false,
      inboxReconciliationInterval: 0
    )

    _ = try await service.poll()
    let laterServiceCenterPDU = singlePDU.replacingOccurrences(
      of: "42101021436500", with: "52101021436500")
    await transport.setSMResponse(
      cmgl([
        (1, 0, laterServiceCenterPDU),
        (2, 0, gsm7PDU),
      ]))

    let result = try await service.poll()
    #expect(result.newMessages.count == 2)
    #expect(result.newMessages.allSatisfy { $0.usesMacTimestamp })
    #expect(Set(result.newMessages.map(\.receivedAt)).count == 1)
    #expect(try await service.messages().map(\.modemIndex) == [2, 1])
  }

  @Test func exposesDetailsRefreshesSIMAndCachesFirmware() async throws {
    let (root, databaseURL) = temporaryDatabase()
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = FakeATTransport()
    let service = try ModemService(
      databaseURL: databaseURL, transport: transport, deletesImportedMessages: false)

    let first = try await service.poll()
    #expect(first.cellularDetails.simStatus == "就绪")
    #expect(first.cellularDetails.firmwareRevision == "EG25GGBR07A08M2G")
    #expect(first.cellularDetails.accessTechnology == "FDD LTE")
    #expect(first.cellularDetails.frequencyBand == "LTE BAND 3")
    #expect(first.cellularDetails.channel == 1300)
    #expect(first.cellularDetails.signalRSRP == -94)
    #expect(first.cellularDetails.signalRSRQ == -10)
    #expect(first.cellularDetails.signalSINR == 11)
    #expect(
      first.cellularDetails.smsStorageUsage == [
        SMSStorageUsage(storage: "SM", used: 3, total: 50),
        SMSStorageUsage(storage: "ME", used: 7, total: 255),
      ])

    await transport.setSIMResponse("\r\n+CPIN: SIM PIN\r\nOK\r\n")
    let second = try await service.poll()
    #expect(second.cellularDetails.simStatus == "需要 SIM PIN")
    let commands = await transport.recordedBatches().flatMap { $0 }
    #expect(commands.filter { $0 == "AT+CPIN?" }.count == 2)
    #expect(commands.filter { $0 == "AT+CGMR" }.count == 1)
    #expect(commands.filter { $0 == "AT+QNWINFO" }.count == 2)
    #expect(commands.filter { $0 == "AT+QENG=\"servingcell\"" }.count == 2)
  }

  @Test func unsupportedExtendedQueriesDegradeWithoutFailingPoll() async throws {
    let (root, databaseURL) = temporaryDatabase()
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = FakeATTransport()
    for command in ["AT+QNWINFO", "AT+QENG=\"servingcell\"", "AT+CPIN?", "AT+CGMR"] {
      await transport.failNext(
        command: command, with: .modemRejected(command: command, response: "ERROR"))
    }
    let service = try ModemService(
      databaseURL: databaseURL, transport: transport, deletesImportedMessages: false)

    let result = try await service.poll()
    #expect(result.registration == "已注册")
    #expect(result.cellularDetails.accessTechnology == "LTE")
    #expect(result.cellularDetails.simStatus == nil)
    #expect(result.cellularDetails.firmwareRevision == nil)
    #expect(result.cellularDetails.signalRSRP == nil)
    #expect(result.cellularDetails.smsStorageUsage.count == 2)
  }

  @Test func extendedQueryTransportFailuresAbortThePoll() async throws {
    let failures: [ModemTransportError] = [
      .timeout(command: "AT+QNWINFO", detail: "测试超时"),
      .disconnected("测试断线"),
      .io("测试 I/O 错误"),
    ]

    for failure in failures {
      let (root, databaseURL) = temporaryDatabase()
      defer { try? FileManager.default.removeItem(at: root) }
      let transport = FakeATTransport()
      await transport.failNext(command: "AT+QNWINFO", with: failure)
      let service = try ModemService(
        databaseURL: databaseURL, transport: transport, deletesImportedMessages: false)

      var didThrow = false
      do {
        _ = try await service.poll()
      } catch {
        didThrow = true
      }
      #expect(didThrow)
      let commands = await transport.recordedBatches().flatMap { $0 }
      #expect(!commands.contains("AT+QENG=\"servingcell\""))
      #expect(!commands.contains("AT+CPIN?"))
    }
  }

  @Test func importsCMTIByExactIndexWithoutWaitingForAnotherFullScan() async throws {
    let (root, databaseURL) = temporaryDatabase()
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = FakeATTransport()
    let service = try ModemService(databaseURL: databaseURL, transport: transport)
    let events = await service.incomingMessages()
    let receivedTask = Task { () -> SMSMessage? in
      for await event in events {
        if case .received(let message) = event { return message }
      }
      return nil
    }

    _ = try await service.poll()
    await transport.setStoredPDU(storage: "SM", index: 17, pdu: singlePDU)
    await transport.emitCMTI(storage: "SM", index: 17)

    let message = try #require(await receivedTask.value)
    #expect(message.body == "你好")
    #expect(message.modemIndex == 17)
    #expect(message.usesMacTimestamp)
    #expect(try await service.messages().count == 1)
    let batches = await transport.recordedBatches()
    #expect(
      batches.contains([
        "AT+CMGF=0",
        "AT+CPMS=\"SM\"",
        "AT+CMGR=17",
      ]))

    _ = try await service.poll()
    let commands = await transport.recordedBatches().flatMap { $0 }
    #expect(commands.filter { $0 == "AT+CMGL=4" }.count == 2)
  }

  @Test func assemblesMultipartCMTIEventsBeforePublishing() async throws {
    let (root, databaseURL) = temporaryDatabase()
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = FakeATTransport()
    let service = try ModemService(databaseURL: databaseURL, transport: transport)
    let events = await service.incomingMessages()
    let receivedTask = Task { () -> SMSMessage? in
      for await event in events {
        if case .received(let message) = event { return message }
      }
      return nil
    }

    _ = try await service.poll()
    await transport.setStoredPDU(storage: "ME", index: 5, pdu: firstMultipartPDU)
    await transport.setStoredPDU(storage: "ME", index: 9, pdu: secondMultipartPDU)
    await transport.emitCMTI(storage: "ME", index: 5)
    await transport.emitCMTI(storage: "ME", index: 9)

    let message = try #require(await receivedTask.value)
    #expect(message.body == "你好")
    #expect(message.modemIndex == 5)
    #expect(try await service.messages().count == 1)
  }

  @Test func sendsLongSMSAndPersistsEachModemReference() async throws {
    let (root, databaseURL) = temporaryDatabase()
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = FakeATTransport()
    let service = try ModemService(databaseURL: databaseURL, transport: transport)
    let updates = OutgoingUpdateRecorder()

    let queued = try await service.enqueueMessage(
      recipient: "13800138000",
      body: String(repeating: "你", count: 71)
    )
    #expect(queued.state == .queued)
    #expect(queued.totalPartCount == 2)

    let sent = try #require(
      await service.sendQueuedMessages { message in
        await updates.append(message)
      }.first
    )
    #expect(sent.state == .sent)
    #expect(sent.parts.map(\.modemReference) == [40, 41])
    #expect(await transport.sentPDUs().count == 2)
    #expect(await updates.sentPartCounts() == [0, 0, 1, 1, 2])
    #expect(await updates.states().last == .sent)
  }

  @Test func releasesATChannelBetweenOutgoingPartsForImmediateCMTIRead() async throws {
    let (root, databaseURL) = temporaryDatabase()
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = FakeATTransport()
    let service = try ModemService(databaseURL: databaseURL, transport: transport)
    let events = await service.incomingMessages()
    let receivedTask = Task { () -> SMSMessage? in
      for await event in events {
        if case .received(let message) = event { return message }
      }
      return nil
    }
    await transport.setStoredPDU(storage: "SM", index: 17, pdu: singlePDU)
    await transport.emitCMTI(afterSendAttempt: 1, storage: "SM", index: 17)
    _ = try await service.enqueueMessage(
      recipient: "10086", body: String(repeating: "你", count: 71))

    let sent = try #require(await service.sendQueuedMessages().first)
    let received = try #require(await receivedTask.value)

    #expect(sent.state == .sent)
    #expect(received.modemIndex == 17)
    let timeline = await transport.recordedTimeline()
    let immediateRead = try #require(timeline.firstIndex(of: "AT+CMGR=17"))
    let secondSubmission = try #require(timeline.firstIndex(of: "SEND:2"))
    #expect(immediateRead < secondSubmission)
  }

  @Test func retriesOnlyFailedPartsWithTheSameConcatenationReference() async throws {
    let (root, databaseURL) = temporaryDatabase()
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = FakeATTransport()
    await transport.failSendAttempt(
      2,
      with: .modemRejected(command: "AT+CMGS=141", response: "+CMS ERROR: 500")
    )
    let service = try ModemService(databaseURL: databaseURL, transport: transport)
    let queued = try await service.enqueueMessage(
      recipient: "+8613800138000",
      body: String(repeating: "你", count: 71)
    )

    await #expect(throws: ModemTransportError.self) {
      _ = try await service.sendQueuedMessages()
    }
    var stored = try #require(await service.outboxMessages().first)
    #expect(stored.state == .failed)
    #expect(stored.sentPartCount == 1)
    let firstAttempts = await transport.sentPDUs()
    #expect(firstAttempts.count == 2)

    stored = try await service.retryOutgoingMessage(id: queued.id)
    #expect(stored.state == .queued)
    #expect(stored.sentPartCount == 1)
    stored = try #require(await service.sendQueuedMessages().first)
    #expect(stored.state == .sent)
    let allAttempts = await transport.sentPDUs()
    #expect(allAttempts.count == 3)
    #expect(allAttempts[1] == allAttempts[2])
  }

  @Test func unknownSubmissionIsNeverAutomaticallyRetried() async throws {
    let (root, databaseURL) = temporaryDatabase()
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = FakeATTransport()
    await transport.failSendAttempt(
      1,
      with: .submissionOutcomeUnknown("等待 +CMGS 回执超时")
    )
    let service = try ModemService(databaseURL: databaseURL, transport: transport)
    let queued = try await service.enqueueMessage(recipient: "10086", body: "状态未知")

    await #expect(throws: ModemTransportError.self) {
      _ = try await service.sendQueuedMessages()
    }
    var stored = try #require(await service.outboxMessages().first)
    #expect(stored.state == .outcomeUnknown)
    #expect(await transport.sentPDUs().count == 1)

    #expect(try await service.sendQueuedMessages().isEmpty)
    #expect(await transport.sentPDUs().count == 1)

    stored = try await service.retryOutgoingMessage(id: queued.id)
    #expect(stored.state == .queued)
    stored = try #require(await service.sendQueuedMessages().first)
    #expect(stored.state == .sent)
    #expect(await transport.sentPDUs().count == 2)
  }

  @Test func safeTransportFailureReturnsMessageToQueueForConnectionRecovery() async throws {
    let (root, databaseURL) = temporaryDatabase()
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = FakeATTransport()
    await transport.failNext(command: "ATE0", with: .disconnected("测试断线"))
    let service = try ModemService(databaseURL: databaseURL, transport: transport)
    let queued = try await service.enqueueMessage(recipient: "10086", body: "恢复后发送")

    await #expect(throws: ModemTransportError.self) {
      _ = try await service.sendQueuedMessages()
    }
    var stored = try #require(await service.outboxMessages().first)
    #expect(stored.id == queued.id)
    #expect(stored.state == .queued)
    #expect(stored.sentPartCount == 0)
    #expect(stored.lastError?.contains("测试断线") == true)

    stored = try #require(await service.sendQueuedMessages().first)
    #expect(stored.state == .sent)
    #expect(await transport.sentPDUs().count == 1)
  }

  private func temporaryDatabase() -> (URL, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    return (root, root.appendingPathComponent("messages.sqlite3"))
  }

  private func cmgl(_ records: [(Int, Int, String)]) -> String {
    records.map { index, status, pdu in
      "+CMGL: \(index),\(status),,\(pdu.count / 2)\r\n\(pdu)"
    }.joined(separator: "\r\n") + "\r\nOK\r\n"
  }
}

private actor OutgoingUpdateRecorder {
  private var messages: [OutgoingSMS] = []

  func append(_ message: OutgoingSMS) {
    messages.append(message)
  }

  func sentPartCounts() -> [Int] {
    messages.map(\.sentPartCount)
  }

  func states() -> [OutgoingSMSState] {
    messages.map(\.state)
  }
}

private actor FakeATTransport: ATTransporting {
  private let descriptor = ATTransportDescriptor.serial(
    path: "/dev/cu.test-modem", sessionID: UUID())
  private var smResponse: String
  private var meResponse: String
  private var simResponse = "\r\n+CPIN: READY\r\nOK\r\n"
  private var batches: [[String]] = []
  private var failures: [String: [ModemTransportError]] = [:]
  private var commandToPause: String?
  private var supportedUSBDeviceRequests: [[USBDeviceIdentifier]] = []
  private var hasPaused = false
  private var pauseObservers: [CheckedContinuation<Void, Never>] = []
  private var pausedCommand: CheckedContinuation<Void, Never>?
  private var storedPDUs: [String: String] = [:]
  private var eventContinuations: [UUID: AsyncStream<ATURC>.Continuation] = [:]
  private var submittedPDUs: [String] = []
  private var sendAttemptCount = 0
  private var sendFailures: [Int: ModemTransportError] = [:]
  private var timeline: [String] = []
  private var incomingEventsAfterSend: [Int: ATURC] = [:]

  init(smResponse: String = "\r\nOK\r\n", meResponse: String = "\r\nOK\r\n") {
    self.smResponse = smResponse
    self.meResponse = meResponse
  }

  func connect(
    supportedUSBDevices: [USBDeviceIdentifier],
    preferredSerialPath: String?
  ) async throws -> ATTransportDescriptor {
    supportedUSBDeviceRequests.append(supportedUSBDevices)
    return descriptor
  }

  func perform(_ commands: [ATCommand]) async throws -> [ATResponse] {
    let commandTexts = commands.map(\.text)
    batches.append(commandTexts)
    timeline.append(contentsOf: commandTexts)

    if let commandToPause,
      !hasPaused,
      commandTexts.contains(commandToPause)
    {
      hasPaused = true
      for observer in pauseObservers {
        observer.resume()
      }
      pauseObservers.removeAll()
      await withCheckedContinuation { continuation in
        pausedCommand = continuation
      }
    }

    for command in commandTexts {
      if var queuedFailures = failures[command], !queuedFailures.isEmpty {
        let failure = queuedFailures.removeFirst()
        failures[command] = queuedFailures
        throw failure
      }
    }

    let selectedStorage: String?
    if commandTexts.contains("AT+CPMS=\"SM\",\"SM\",\"SM\"")
      || commandTexts.contains("AT+CPMS=\"SM\"")
    {
      selectedStorage = "SM"
    } else if commandTexts.contains("AT+CPMS=\"ME\",\"ME\",\"ME\"")
      || commandTexts.contains("AT+CPMS=\"ME\"")
    {
      selectedStorage = "ME"
    } else {
      selectedStorage = nil
    }

    return commands.map { command in
      let raw: String
      switch command.text {
      case "AT+CSQ": raw = "\r\n+CSQ: 20,99\r\nOK\r\n"
      case "AT+CEREG?": raw = "\r\n+CEREG: 0,1\r\nOK\r\n"
      case "AT+COPS?": raw = "\r\n+COPS: 0,0,\"Test Carrier\",7\r\nOK\r\n"
      case "AT+CPIN?": raw = simResponse
      case "AT+CGMR": raw = "\r\nEG25GGBR07A08M2G\r\nOK\r\n"
      case "AT+QNWINFO":
        raw = "\r\n+QNWINFO: \"FDD LTE\",\"46000\",\"LTE BAND 3\",1300\r\nOK\r\n"
      case "AT+QENG=\"servingcell\"":
        raw =
          "\r\n+QENG: \"servingcell\",\"NOCONN\",\"LTE\",\"FDD\",460,00,5F1EA01,383,1650,3,5,5,3A7D,-94,-10,-67,11,13\r\nOK\r\n"
      case let text where text.hasPrefix("AT+CPMS="):
        raw =
          selectedStorage == "SM"
          ? "\r\n+CPMS: 3,50,3,50,3,50\r\nOK\r\n"
          : "\r\n+CPMS: 7,255,7,255,7,255\r\nOK\r\n"
      case "AT+CMGL=4": raw = selectedStorage == "SM" ? smResponse : meResponse
      case let text where text.hasPrefix("AT+CMGR="):
        let index = Int(text.dropFirst("AT+CMGR=".count)) ?? -1
        raw =
          storedPDUs[Self.storedPDUKey(storage: selectedStorage ?? "", index: index)]
          ?? "\r\n+CMS ERROR: 321\r\n"
      default: raw = "\r\nOK\r\n"
      }
      return ATResponse(command: command.text, raw: raw)
    }
  }

  func sendMessagePDU(_ pdu: String, tpduLength: Int, timeout: TimeInterval) async throws
    -> ATResponse
  {
    sendAttemptCount += 1
    submittedPDUs.append(pdu)
    timeline.append("SEND:\(sendAttemptCount)")
    if let failure = sendFailures.removeValue(forKey: sendAttemptCount) {
      throw failure
    }
    if let event = incomingEventsAfterSend.removeValue(forKey: sendAttemptCount) {
      for continuation in eventContinuations.values {
        continuation.yield(event)
      }
      try? await Task.sleep(for: .milliseconds(10))
    }
    let reference = 39 + sendAttemptCount
    return ATResponse(
      command: "AT+CMGS=\(tpduLength)",
      raw: "\r\n+CMGS: \(reference)\r\n\r\nOK\r\n"
    )
  }

  func unsolicitedEvents() async -> AsyncStream<ATURC> {
    let id = UUID()
    let (stream, continuation) = AsyncStream.makeStream(
      of: ATURC.self,
      bufferingPolicy: .bufferingNewest(256)
    )
    eventContinuations[id] = continuation
    continuation.onTermination = { [weak self] _ in
      Task { await self?.removeEventContinuation(id) }
    }
    return stream
  }

  func disconnect() async {}

  func recordedBatches() -> [[String]] {
    batches
  }

  func recordedSupportedUSBDevices() -> [[USBDeviceIdentifier]] {
    supportedUSBDeviceRequests
  }

  func setSMResponse(_ response: String) {
    smResponse = response
  }

  func setSIMResponse(_ response: String) {
    simResponse = response
  }

  func setStoredPDU(storage: String, index: Int, pdu: String, status: Int = 0) {
    storedPDUs[Self.storedPDUKey(storage: storage, index: index)] =
      "\r\n+CMGR: \(status),,\(pdu.count / 2)\r\n\(pdu)\r\n\r\nOK\r\n"
  }

  func emitCMTI(storage: String, index: Int) {
    let event = ATURC(raw: "+CMTI: \"\(storage)\",\(index)")
    for continuation in eventContinuations.values {
      continuation.yield(event)
    }
  }

  func failSendAttempt(_ attempt: Int, with error: ModemTransportError) {
    sendFailures[attempt] = error
  }

  func sentPDUs() -> [String] {
    submittedPDUs
  }

  func recordedTimeline() -> [String] {
    timeline
  }

  func emitCMTI(afterSendAttempt attempt: Int, storage: String, index: Int) {
    incomingEventsAfterSend[attempt] = ATURC(raw: "+CMTI: \"\(storage)\",\(index)")
  }

  func failNext(command: String, with error: ModemTransportError) {
    failures[command, default: []].append(error)
  }

  func pauseNext(command: String) {
    commandToPause = command
    hasPaused = false
  }

  func waitUntilPaused() async {
    if hasPaused { return }
    await withCheckedContinuation { continuation in
      pauseObservers.append(continuation)
    }
  }

  func releasePausedCommand() {
    pausedCommand?.resume()
    pausedCommand = nil
  }

  private func removeEventContinuation(_ id: UUID) {
    eventContinuations.removeValue(forKey: id)
  }

  private static func storedPDUKey(storage: String, index: Int) -> String {
    "\(storage.uppercased()):\(index)"
  }
}
