import CryptoKit
import Foundation

actor ModemService {
  private struct StoredMessageLocation: Hashable {
    let storage: String
    let index: Int
  }

  private struct CachedIncomingPart {
    let part: StoredDecodedSMSPart
    let receivedAt: Date
    let usesMacTimestamp: Bool
  }

  private struct ImportResult {
    var messages: [SMSMessage] = []
    var deletionIndexes: [String: Set<Int>] = [:]
    var warnings: [String] = []
  }

  private struct ActiveIncomingCall {
    var record: IncomingCallRecord
    var hasPublished: Bool
  }

  static let supportedUSBDevices = [
    USBDeviceIdentifier(vendorID: 0x2C7C, productID: 0x0125),
    USBDeviceIdentifier(vendorID: 0x2CA3, productID: 0x4006),
  ]

  private let transport: any ATTransporting
  private let database: SMSDatabase
  private let callHistory: CallHistoryStore
  private let outbox: SMSOutboxStore
  private let inboxReconciliationInterval: TimeInterval
  private let decoder = SMSPDUDecoder()
  private let parser = ATResponseParser()
  private let assembler = SMSAssembler()
  private var initializedDescriptor: ATTransportDescriptor?
  private var preferredSerialPath: String?
  private var deletesImportedMessages: Bool
  private var hasCompletedMessageScan = false
  private var lastInboxReconciliationAt: Date?
  private var cachedIncomingParts: [StoredMessageLocation: CachedIncomingPart] = [:]
  private var announcedIncomingAt: [StoredMessageLocation: Date] = [:]
  private var unsolicitedTask: Task<Void, Never>?
  private var isStartingUnsolicitedConsumer = false
  private var messageEventContinuations: [UUID: AsyncStream<ModemMessageEvent>.Continuation] = [:]
  private var activeIncomingCall: ActiveIncomingCall?
  private var firmwareDescriptor: ATTransportDescriptor?
  private var cachedFirmwareRevision: String?
  private var transportOperationActive = false
  private var transportWaiters: [CheckedContinuation<Void, Never>] = []
  private var outboxDrainActive = false

  init(
    databaseURL: URL = SMSDatabase.defaultURL(),
    outboxURL: URL? = nil,
    callHistoryURL: URL? = nil,
    transport: any ATTransporting = ATTransportWorker(),
    deletesImportedMessages: Bool = false,
    inboxReconciliationInterval: TimeInterval = 60
  ) throws {
    database = try SMSDatabase(url: databaseURL)
    callHistory = try CallHistoryStore(
      url: callHistoryURL
        ?? databaseURL.deletingLastPathComponent().appendingPathComponent("calls.sqlite3")
    )
    outbox = try SMSOutboxStore(
      url: outboxURL
        ?? databaseURL.deletingLastPathComponent().appendingPathComponent("outbox.sqlite3")
    )
    self.transport = transport
    self.deletesImportedMessages = deletesImportedMessages
    self.inboxReconciliationInterval = max(0, inboxReconciliationInterval)
  }

  func poll() async throws -> ModemPollResult {
    await acquireTransportOperation()
    defer { releaseTransportOperation() }
    try Task.checkCancellation()
    do {
      return try await pollExclusively()
    } catch {
      resetInitializationAfterTransportFailure(error)
      throw error
    }
  }

  func incomingMessages() async -> AsyncStream<ModemMessageEvent> {
    let id = UUID()
    let (stream, continuation) = AsyncStream.makeStream(
      of: ModemMessageEvent.self,
      bufferingPolicy: .unbounded
    )
    messageEventContinuations[id] = continuation
    continuation.onTermination = { [weak self] _ in
      Task { await self?.removeMessageEventContinuation(id) }
    }
    await startUnsolicitedConsumerIfNeeded()
    return stream
  }

  func messages() async throws -> [SMSMessage] {
    try await database.allMessages()
  }

  func calls() async throws -> [IncomingCallRecord] {
    try await callHistory.allCalls()
  }

  func outboxMessages() async throws -> [OutgoingSMS] {
    try await outbox.messages()
  }

  func enqueueMessage(recipient: String, body: String) async throws -> OutgoingSMS {
    try await outbox.enqueue(recipient: recipient, body: body)
  }

  @discardableResult
  func sendQueuedMessages(
    onUpdate: (@Sendable (OutgoingSMS) async -> Void)? = nil
  ) async throws -> [OutgoingSMS] {
    guard !outboxDrainActive else {
      throw ModemTransportError.io("发件箱已有发送任务正在运行")
    }
    outboxDrainActive = true
    defer { outboxDrainActive = false }

    var sentMessages: [OutgoingSMS] = []
    var activeMessageID: String?
    while true {
      await acquireTransportOperation()
      do {
        try Task.checkCancellation()
        let message: OutgoingSMS
        if let activeMessageID {
          guard let active = try await outbox.message(id: activeMessageID) else {
            throw SMSOutboxError.messageNotFound(activeMessageID)
          }
          message = active
        } else {
          guard let queued = try await outbox.nextQueued() else {
            releaseTransportOperation()
            return sentMessages
          }
          activeMessageID = queued.id
          message = queued
        }
        let updated = try await sendNextOutgoingPartExclusively(message, onUpdate: onUpdate)
        releaseTransportOperation()
        if updated.state == .sent {
          sentMessages.append(updated)
          activeMessageID = nil
        }
        await Task.yield()
      } catch {
        if let activeMessageID,
          let failed = await persistSendFailure(id: activeMessageID, error: error)
        {
          await onUpdate?(failed)
        }
        releaseTransportOperation()
        resetInitializationAfterTransportFailure(error)
        throw error
      }
    }
  }

  func retryOutgoingMessage(id: String) async throws -> OutgoingSMS {
    try await outbox.retry(id: id)
  }

  func deleteOutgoingMessage(id: String) async throws {
    await acquireTransportOperation()
    defer { releaseTransportOperation() }
    try await outbox.delete(id: id)
  }

  func markRead(id: String) async throws {
    try await database.markRead(id: id)
  }

  func deleteLocalMessage(id: String) async throws {
    try await database.delete(id: id)
  }

  func switchToECM(apn: String?) async throws {
    await acquireTransportOperation()
    defer { releaseTransportOperation() }
    try Task.checkCancellation()
    do {
      try await switchToECMExclusively(apn: apn)
    } catch {
      resetInitializationAfterTransportFailure(error)
      throw error
    }
  }

  func disconnect() async {
    await acquireTransportOperation()
    defer { releaseTransportOperation() }
    await transport.disconnect()
    initializedDescriptor = nil
    hasCompletedMessageScan = false
    lastInboxReconciliationAt = nil
    cachedIncomingParts.removeAll()
    announcedIncomingAt.removeAll()
    activeIncomingCall = nil
    resetCachedFirmware()
  }

  func setPreferredSerialPath(_ path: String?) {
    preferredSerialPath = path
  }

  func setDeletesImportedMessages(_ enabled: Bool) {
    deletesImportedMessages = enabled
  }

  private func pollExclusively() async throws -> ModemPollResult {
    let descriptor = try await ensureConnected()
    try await initializeIfNeeded(descriptor: descriptor)
    let now = Date()
    let shouldReconcileInbox =
      lastInboxReconciliationAt.map {
        let elapsed = now.timeIntervalSince($0)
        return inboxReconciliationInterval == 0 || elapsed < 0
          || elapsed >= inboxReconciliationInterval
      } ?? true
    let usesMacTimestamp = hasCompletedMessageScan

    var warnings: [String] = []
    var reconciledStorages: Set<String> = []
    let signalRaw: String
    if let response = try await optionalStatusResponse(ATCommand("AT+CSQ", timeout: 2)) {
      signalRaw = response
    } else {
      signalRaw = ""
      warnings.append("模块不支持信号强度查询")
    }
    try Task.checkCancellation()

    let registrationRaw: String
    if let response = try await optionalStatusResponse(ATCommand("AT+CEREG?", timeout: 2)) {
      registrationRaw = response
    } else {
      registrationRaw = ""
      warnings.append("模块不支持网络注册状态查询")
    }
    try Task.checkCancellation()

    let operatorRaw: String
    if let response = try await optionalStatusResponse(ATCommand("AT+COPS?", timeout: 3)) {
      operatorRaw = response
    } else {
      operatorRaw = ""
      warnings.append("模块不支持运营商查询")
    }
    try Task.checkCancellation()

    var records: [ModemStoredPDU] = []
    var storageUsage: [String: SMSStorageUsage] = [:]
    for storage in ["SM", "ME"] {
      do {
        var commands = [
          ATCommand("AT+CMGF=0", timeout: 3),
          ATCommand("AT+CPMS=\"\(storage)\",\"\(storage)\",\"\(storage)\"", timeout: 5),
        ]
        if shouldReconcileInbox {
          commands.append(ATCommand("AT+CMGL=4", timeout: 15))
        }
        let responses = try await transport.perform(commands)
        if responses.count > 1,
          let usage = parser.smsStorageUsage(from: responses[1].raw, storage: storage)
        {
          storageUsage[storage] = usage
        }
        if shouldReconcileInbox, let response = responses.last {
          records.append(contentsOf: parser.storedPDUs(from: response.raw, storage: storage))
          reconciledStorages.insert(storage)
        }
      } catch let error as ModemTransportError {
        guard case .modemRejected = error else { throw error }
        warnings.append("模块拒绝读取 \(storage) 短信：\(error.localizedDescription)")
      }
      try Task.checkCancellation()
    }

    var importResult = ImportResult()
    if shouldReconcileInbox {
      importResult = try await importStoredRecords(
        records,
        receivedAt: now,
        usesMacTimestamp: usesMacTimestamp,
        reconciledStorages: reconciledStorages
      )
      warnings.append(contentsOf: importResult.warnings)
      if deletesImportedMessages {
        try await deleteImportedRecords(importResult.deletionIndexes, warnings: &warnings)
      }
      hasCompletedMessageScan = true
      lastInboxReconciliationAt = now
    }

    let cellularDetails = try await queryCellularDetails(
      descriptor: descriptor,
      operatorResponse: operatorRaw,
      storageUsage: storageUsage
    )

    return ModemPollResult(
      transport: descriptor,
      signalRSSI: parser.signalRSSI(from: signalRaw),
      registration: parser.registration(from: registrationRaw),
      operatorName: parser.operatorName(from: operatorRaw),
      cellularDetails: cellularDetails,
      newMessages: importResult.messages,
      warnings: warnings
    )
  }

  private func startUnsolicitedConsumerIfNeeded() async {
    guard unsolicitedTask == nil, !isStartingUnsolicitedConsumer else { return }
    isStartingUnsolicitedConsumer = true
    let events = await transport.unsolicitedEvents()
    isStartingUnsolicitedConsumer = false
    guard unsolicitedTask == nil else { return }

    unsolicitedTask = Task { [weak self] in
      for await event in events {
        guard !Task.isCancelled else { break }
        await self?.handleUnsolicitedEvent(event)
      }
      await self?.unsolicitedConsumerDidFinish()
    }
  }

  private func unsolicitedConsumerDidFinish() {
    unsolicitedTask = nil
    activeIncomingCall = nil
  }

  private func removeMessageEventContinuation(_ id: UUID) {
    messageEventContinuations.removeValue(forKey: id)
  }

  private func emitMessageEvent(_ event: ModemMessageEvent) {
    for continuation in messageEventContinuations.values {
      continuation.yield(event)
    }
  }

  private func handleUnsolicitedEvent(_ event: ATURC) async {
    switch event.kind {
    case .ring:
      await handleIncomingCallSignal(callerNumber: nil, shouldQueryCallList: true)
    case .callerID(let callerNumber):
      await handleIncomingCallSignal(
        callerNumber: callerNumber,
        shouldQueryCallList: callerNumber == nil
      )
    case .noCarrier:
      await finishActiveIncomingCall()
    case .messageStorage:
      await handleIncomingMessageEvent(event)
    case .other:
      break
    }
  }

  private func handleIncomingMessageEvent(_ event: ATURC) async {
    guard let rawStorage = event.storage, let index = event.index, index >= 0 else { return }
    let storage = rawStorage.uppercased()
    guard Self.isSafeSMSStorage(storage) else {
      emitMessageEvent(.warning("收到无法识别的短信存储通知：\(event.raw)"))
      return
    }
    announcedIncomingAt[StoredMessageLocation(storage: storage, index: index)] = Date()

    await acquireTransportOperation()
    defer { releaseTransportOperation() }
    do {
      let descriptor = try await ensureConnected()
      try await initializeIfNeeded(descriptor: descriptor)
      let responses = try await transport.perform([
        ATCommand("AT+CMGF=0", timeout: 3),
        ATCommand("AT+CPMS=\"\(storage)\"", timeout: 5),
        ATCommand("AT+CMGR=\(index)", timeout: 8),
      ])
      guard let response = responses.last,
        let record = parser.storedPDU(from: response.raw, storage: storage, index: index)
      else {
        emitMessageEvent(.warning("无法读取 \(storage) 第 \(index) 条新短信"))
        return
      }

      let result = try await importStoredRecords(
        [record],
        receivedAt: Date(),
        usesMacTimestamp: true,
        reconciledStorages: []
      )
      for message in result.messages {
        emitMessageEvent(.received(message))
      }
      for warning in result.warnings {
        emitMessageEvent(.warning(warning))
      }

      if deletesImportedMessages, !result.deletionIndexes.isEmpty {
        var cleanupWarnings: [String] = []
        try await deleteImportedRecords(result.deletionIndexes, warnings: &cleanupWarnings)
        for warning in cleanupWarnings {
          emitMessageEvent(.warning(warning))
        }
      }
    } catch {
      resetInitializationAfterTransportFailure(error)
      emitMessageEvent(
        .warning("即时读取 \(storage) 第 \(index) 条短信失败：\(error.localizedDescription)"))
    }
  }

  private func handleIncomingCallSignal(
    callerNumber: String?,
    shouldQueryCallList: Bool
  ) async {
    let activeCallID: String
    if let activeIncomingCall {
      activeCallID = activeIncomingCall.record.id
      if let callerNumber {
        await updateActiveCallerNumber(callerNumber, for: activeCallID)
      }
    } else {
      activeCallID = UUID().uuidString
      activeIncomingCall = ActiveIncomingCall(
        record: IncomingCallRecord(
          id: activeCallID,
          callerNumber: callerNumber,
          receivedAt: Date()
        ),
        hasPublished: false
      )
    }

    guard activeIncomingCall?.record.id == activeCallID else { return }
    if shouldQueryCallList, activeIncomingCall?.record.callerNumber == nil {
      let activeCallBeforeQuery = activeIncomingCall
      do {
        if let incomingCall = try await queryIncomingVoiceCall(),
          let callerNumber = incomingCall.callerNumber
        {
          await updateActiveCallerNumber(callerNumber, for: activeCallID)
        }
      } catch let error as ModemTransportError {
        if case .modemRejected = error {
          // Caller ID remains optional when this modem does not implement +CLCC.
        } else {
          resetInitializationAfterTransportFailure(error)
          activeIncomingCall = activeCallBeforeQuery
          emitMessageEvent(.warning("查询来电号码失败：\(error.localizedDescription)"))
        }
      } catch {
        emitMessageEvent(.warning("查询来电号码失败：\(error.localizedDescription)"))
      }
    }
    await publishActiveIncomingCallIfNeeded(id: activeCallID)
  }

  private func queryIncomingVoiceCall() async throws -> ATIncomingVoiceCall? {
    await acquireTransportOperation()
    defer { releaseTransportOperation() }
    let descriptor = try await ensureConnected()
    try await initializeIfNeeded(descriptor: descriptor)
    let response = try await transport.perform([
      ATCommand("AT+CLCC", timeout: 3)
    ]).first
    return response.flatMap { parser.incomingVoiceCalls(from: $0.raw).first }
  }

  private func updateActiveCallerNumber(_ callerNumber: String, for id: String?) async {
    guard var activeCall = activeIncomingCall,
      activeCall.record.id == id,
      activeCall.record.callerNumber != callerNumber
    else {
      return
    }
    activeCall.record = IncomingCallRecord(
      id: activeCall.record.id,
      callerNumber: callerNumber,
      receivedAt: activeCall.record.receivedAt
    )
    activeIncomingCall = activeCall
    guard activeCall.hasPublished else { return }
    do {
      try await callHistory.updateCallerNumber(
        id: activeCall.record.id,
        callerNumber: callerNumber
      )
      emitMessageEvent(.incomingCallUpdated(activeCall.record))
    } catch {
      emitMessageEvent(.warning("更新来电号码失败：\(error.localizedDescription)"))
    }
  }

  private func publishActiveIncomingCallIfNeeded(id: String? = nil) async {
    guard var activeCall = activeIncomingCall,
      id == nil || activeCall.record.id == id,
      !activeCall.hasPublished
    else {
      return
    }
    activeCall.hasPublished = true
    activeIncomingCall = activeCall
    do {
      if try await callHistory.insert(activeCall.record) {
        emitMessageEvent(.incomingCall(activeCall.record))
      }
    } catch {
      if var current = activeIncomingCall, current.record.id == activeCall.record.id {
        current.hasPublished = false
        activeIncomingCall = current
      }
      emitMessageEvent(.warning("保存来电记录失败：\(error.localizedDescription)"))
    }
  }

  private func finishActiveIncomingCall() async {
    await publishActiveIncomingCallIfNeeded()
    activeIncomingCall = nil
  }

  private func importStoredRecords(
    _ records: [ModemStoredPDU],
    receivedAt: Date,
    usesMacTimestamp: Bool,
    reconciledStorages: Set<String>
  ) async throws -> ImportResult {
    let observedLocations = Set(records.map(Self.location))
    if !reconciledStorages.isEmpty {
      let staleCachedLocations = cachedIncomingParts.keys.filter {
        reconciledStorages.contains($0.storage) && !observedLocations.contains($0)
      }
      for location in staleCachedLocations {
        cachedIncomingParts.removeValue(forKey: location)
      }
      let staleAnnouncements = announcedIncomingAt.keys.filter {
        reconciledStorages.contains($0.storage) && !observedLocations.contains($0)
      }
      for location in staleAnnouncements {
        announcedIncomingAt.removeValue(forKey: location)
      }
    }

    let knownPDUs = try await database.knownImportedPDUs(records.map(\.pdu))
    var result = ImportResult()
    for record in records {
      let location = Self.location(record)
      if knownPDUs.contains(record.pdu) {
        cachedIncomingParts.removeValue(forKey: location)
        announcedIncomingAt.removeValue(forKey: location)
        if deletesImportedMessages {
          result.deletionIndexes[record.storage, default: []].insert(record.index)
        }
        continue
      }

      do {
        let decoded = try decoder.decode(record.pdu)
        let existing = cachedIncomingParts[location]
        let preservesArrival = existing?.part.record.pdu == record.pdu
        let announcedAt = announcedIncomingAt[location]
        cachedIncomingParts[location] = CachedIncomingPart(
          part: StoredDecodedSMSPart(record: record, decoded: decoded),
          receivedAt: preservesArrival ? existing!.receivedAt : (announcedAt ?? receivedAt),
          usesMacTimestamp: preservesArrival
            ? existing!.usesMacTimestamp : (announcedAt != nil || usesMacTimestamp)
        )
      } catch {
        cachedIncomingParts.removeValue(forKey: location)
        result.warnings.append(
          "\(record.storage) 第 \(record.index) 条短信解析失败：\(error.localizedDescription)")
      }
    }

    for complete in assembler.assemble(cachedIncomingParts.values.map(\.part)) {
      guard let primaryRecord = complete.records.min(by: Self.recordOrder) else { continue }
      let cachedMetadata = complete.records.compactMap {
        cachedIncomingParts[Self.location($0)]
      }
      let message = SMSMessage(
        id: fingerprint(for: complete.decoded),
        sender: complete.decoded.sender,
        body: complete.decoded.body,
        receivedAt: cachedMetadata.map(\.receivedAt).min() ?? receivedAt,
        serviceCenterAt: complete.decoded.receivedAt,
        usesMacTimestamp: cachedMetadata.contains(where: \.usesMacTimestamp),
        storage: primaryRecord.storage,
        modemIndex: primaryRecord.index,
        rawPDU: complete.decoded.rawPDU,
        isRead: complete.records.allSatisfy(\.isRead)
      )
      do {
        let isNew = try await database.insert(
          message,
          constituentPDUs: complete.records.map(\.pdu)
        )
        if isNew {
          result.messages.append(message)
        }
        for record in complete.records {
          let location = Self.location(record)
          cachedIncomingParts.removeValue(forKey: location)
          announcedIncomingAt.removeValue(forKey: location)
          if deletesImportedMessages {
            result.deletionIndexes[record.storage, default: []].insert(record.index)
          }
        }
      } catch {
        result.warnings.append("短信写入本机失败：\(error.localizedDescription)")
      }
    }
    return result
  }

  private func sendNextOutgoingPartExclusively(
    _ queuedOrSending: OutgoingSMS,
    onUpdate: (@Sendable (OutgoingSMS) async -> Void)?
  ) async throws -> OutgoingSMS {
    try Task.checkCancellation()
    var message = queuedOrSending
    if message.state == .queued {
      message = try await outbox.beginSending(id: message.id)
      await onUpdate?(message)
    }
    guard message.state == .sending else {
      throw SMSOutboxError.invalidTransition(from: message.state, to: .sending)
    }
    guard let index = message.pendingPartIndexes.min(),
      let part = message.parts.first(where: { $0.index == index })
    else {
      throw SMSOutboxError.operation("发送中的短信没有待发送分段")
    }
    guard !part.pdu.isEmpty, part.tpduLength > 0 else {
      throw SMSOutboxError.operation("发件箱分段缺少已保存的 PDU")
    }

    let descriptor = try await ensureConnected()
    try await initializeIfNeeded(descriptor: descriptor)
    try Task.checkCancellation()
    message = try await outbox.beginPart(id: message.id, index: index)
    await onUpdate?(message)
    let response = try await transport.sendMessagePDU(
      part.pdu,
      tpduLength: part.tpduLength,
      timeout: 60
    )
    do {
      message = try await outbox.markPartSent(
        id: message.id,
        index: index,
        modemReference: parser.sentMessageReference(from: response.raw)
      )
      await onUpdate?(message)
      return message
    } catch {
      throw ModemTransportError.submissionOutcomeUnknown(
        "模块已确认发送，但无法保存第 \(index + 1) 段状态：\(error.localizedDescription)"
      )
    }
  }

  private func persistSendFailure(id: String, error: any Error) async -> OutgoingSMS? {
    guard let current = try? await outbox.message(id: id), current.state == .sending else {
      return nil
    }
    if error is CancellationError {
      return try? await outbox.deferSending(id: id, error: "发送已暂停，等待连接恢复")
    }
    if let transportError = error as? ModemTransportError,
      case .submissionOutcomeUnknown = transportError
    {
      return try? await outbox.markOutcomeUnknown(id: id, error: error.localizedDescription)
    }
    if let transportError = error as? ModemTransportError {
      switch transportError {
      case .notConnected, .timeout, .disconnected, .io:
        return try? await outbox.deferSending(id: id, error: error.localizedDescription)
      case .modemRejected, .invalidCommand, .submissionOutcomeUnknown:
        break
      }
    }
    return try? await outbox.markFailed(id: id, error: error.localizedDescription)
  }

  private func switchToECMExclusively(apn: String?) async throws {
    let descriptor = try await ensureConnected()
    try await initializeIfNeeded(descriptor: descriptor)
    if let apn, !apn.isEmpty {
      guard Self.isSafeAPN(apn) else {
        throw ModemTransportError.invalidCommand("APN 只能包含字母、数字、点、连字符和下划线")
      }
      _ = try await transport.perform([
        ATCommand("AT+CGDCONT=1,\"IP\",\"\(apn)\"", timeout: 5)
      ])
    }
    do {
      _ = try await transport.perform([
        ATCommand("AT+QCFG=\"usbnet\",1", timeout: 8)
      ])
    } catch ModemTransportError.disconnected {
      // This firmware hot-restarts USB as soon as the new mode is accepted.
    } catch ModemTransportError.timeout {
      // The final OK can be lost while the device is re-enumerating.
    }
    await transport.disconnect()
    initializedDescriptor = nil
    hasCompletedMessageScan = false
    lastInboxReconciliationAt = nil
    cachedIncomingParts.removeAll()
    announcedIncomingAt.removeAll()
    activeIncomingCall = nil
    resetCachedFirmware()
  }

  private func optionalStatusResponse(_ command: ATCommand) async throws -> String? {
    do {
      return try await transport.perform([command]).first?.raw
    } catch let error as ModemTransportError {
      guard case .modemRejected = error else { throw error }
      return nil
    }
  }

  private func queryCellularDetails(
    descriptor: ATTransportDescriptor,
    operatorResponse: String,
    storageUsage: [String: SMSStorageUsage]
  ) async throws -> CellularDetails {
    let networkResponse = try await optionalExtendedStatusResponse(
      ATCommand("AT+QNWINFO", timeout: 2))
    try Task.checkCancellation()
    let servingCellResponse = try await optionalExtendedStatusResponse(
      ATCommand("AT+QENG=\"servingcell\"", timeout: 3))
    try Task.checkCancellation()
    let simResponse = try await optionalExtendedStatusResponse(ATCommand("AT+CPIN?", timeout: 2))
    try Task.checkCancellation()

    if firmwareDescriptor != descriptor {
      cachedFirmwareRevision = nil
      if let response = try await optionalExtendedStatusResponse(ATCommand("AT+CGMR", timeout: 3)) {
        cachedFirmwareRevision = parser.firmwareRevision(from: response)
      }
      try Task.checkCancellation()
      if initializedDescriptor == descriptor {
        firmwareDescriptor = descriptor
      }
    }

    let network = parser.networkInformation(from: networkResponse ?? "")
    let servingCell = parser.servingCellDetails(from: servingCellResponse ?? "")
    let storageOrder = ["SM": 0, "ME": 1]
    return CellularDetails(
      simStatus: parser.simStatus(from: simResponse ?? ""),
      firmwareRevision: cachedFirmwareRevision,
      accessTechnology: network.accessTechnology ?? servingCell.accessTechnology
        ?? parser.operatorAccessTechnology(from: operatorResponse),
      frequencyBand: network.frequencyBand ?? servingCell.frequencyBand,
      channel: network.channel ?? servingCell.channel,
      signalRSRP: servingCell.signalRSRP,
      signalRSRQ: servingCell.signalRSRQ,
      signalSINR: servingCell.signalSINR,
      smsStorageUsage: storageUsage.values.sorted {
        storageOrder[$0.storage, default: .max] < storageOrder[$1.storage, default: .max]
      }
    )
  }

  private func optionalExtendedStatusResponse(_ command: ATCommand) async throws -> String? {
    do {
      return try await transport.perform([command]).first?.raw
    } catch let error as ModemTransportError {
      guard case .modemRejected = error else { throw error }
      return nil
    }
  }

  private func deleteImportedRecords(
    _ indexesByStorage: [String: Set<Int>],
    warnings: inout [String]
  ) async throws {
    let storageOrder = ["SM": 0, "ME": 1, "MT": 2]
    let storages = indexesByStorage.keys.sorted {
      storageOrder[$0, default: .max] < storageOrder[$1, default: .max]
    }
    for storage in storages {
      guard let indexes = indexesByStorage[storage] else { continue }
      for index in indexes.sorted(by: >) {
        do {
          let selectStorage =
            storage == "SM" || storage == "ME"
            ? "AT+CPMS=\"\(storage)\",\"\(storage)\",\"\(storage)\""
            : "AT+CPMS=\"\(storage)\""
          _ = try await transport.perform([
            ATCommand(selectStorage, timeout: 5),
            ATCommand("AT+CMGD=\(index),0", timeout: 5),
          ])
        } catch let error as ModemTransportError {
          guard case .modemRejected(let command, _) = error else { throw error }
          warnings.append(
            "模块拒绝清理 \(storage) 第 \(index) 条短信：\(error.localizedDescription)")
          if command.hasPrefix("AT+CPMS=") { break }
        }
        try Task.checkCancellation()
      }
    }
  }

  private func ensureConnected() async throws -> ATTransportDescriptor {
    try await transport.connect(
      supportedUSBDevices: Self.supportedUSBDevices,
      preferredSerialPath: preferredSerialPath
    )
  }

  private func initializeIfNeeded(descriptor: ATTransportDescriptor) async throws {
    guard initializedDescriptor != descriptor else { return }
    _ = try await transport.perform([
      ATCommand("ATE0", timeout: 2),
      ATCommand("AT+CMEE=2", timeout: 2),
      ATCommand("AT+CMGF=0", timeout: 3),
      ATCommand("AT+CNMI=2,1,0,0,0", timeout: 3),
    ])
    do {
      _ = try await transport.perform([
        ATCommand("AT+CLIP=1", timeout: 3)
      ])
    } catch let error as ModemTransportError {
      guard case .modemRejected = error else { throw error }
    }
    initializedDescriptor = descriptor
  }

  private func acquireTransportOperation() async {
    if !transportOperationActive {
      transportOperationActive = true
      return
    }
    await withCheckedContinuation { continuation in
      transportWaiters.append(continuation)
    }
  }

  private func releaseTransportOperation() {
    if transportWaiters.isEmpty {
      transportOperationActive = false
    } else {
      transportWaiters.removeFirst().resume()
    }
  }

  private func resetInitializationAfterTransportFailure(_ error: any Error) {
    guard let transportError = error as? ModemTransportError else { return }
    switch transportError {
    case .notConnected, .timeout, .disconnected, .io, .submissionOutcomeUnknown:
      initializedDescriptor = nil
      hasCompletedMessageScan = false
      lastInboxReconciliationAt = nil
      cachedIncomingParts.removeAll()
      announcedIncomingAt.removeAll()
      activeIncomingCall = nil
      resetCachedFirmware()
    case .modemRejected, .invalidCommand:
      break
    }
  }

  private func resetCachedFirmware() {
    firmwareDescriptor = nil
    cachedFirmwareRevision = nil
  }

  private func fingerprint(for message: DecodedSMSPart) -> String {
    let input =
      "\(message.sender)\u{0}\(message.receivedAt.timeIntervalSince1970)\u{0}\(message.rawPDU)"
    let digest = SHA256.hash(data: Data(input.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  private static func recordOrder(_ left: ModemStoredPDU, _ right: ModemStoredPDU) -> Bool {
    if left.storage != right.storage { return left.storage < right.storage }
    return left.index < right.index
  }

  private static func location(_ record: ModemStoredPDU) -> StoredMessageLocation {
    StoredMessageLocation(storage: record.storage, index: record.index)
  }

  private static func isSafeSMSStorage(_ value: String) -> Bool {
    value == "SM" || value == "ME" || value == "MT"
  }

  private static func isSafeAPN(_ value: String) -> Bool {
    !value.isEmpty && value.count <= 100
      && value.allSatisfy {
        $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0))
      }
  }
}
