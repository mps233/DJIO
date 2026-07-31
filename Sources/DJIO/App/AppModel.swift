import AppKit
import Foundation
import ServiceManagement
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
  let menuBarStatus: MenuBarStatusModel

  @Published var selection: NavigationDestination? = .connection
  @Published var connection = ConnectionSnapshot.disconnected {
    didSet { menuBarStatus.update(connection: connection) }
  }
  @Published var network = NetworkSnapshot()
  @Published var traffic = NetworkTrafficSnapshot.unavailable {
    didSet { menuBarStatus.updateTraffic(traffic) }
  }
  @Published var trafficUsage: TrafficUsageSnapshot
  @Published private(set) var trafficPersistenceIssue: String?
  @Published var messages: [SMSMessage] = [] {
    didSet { updateUnreadIndicators() }
  }
  @Published private(set) var incomingCalls: [IncomingCallRecord] = []
  @Published private(set) var presentedIncomingCall: IncomingCallRecord?
  @Published private(set) var outbox: [OutgoingSMS] = []
  @Published private(set) var isSendingMessage = false
  @Published private(set) var sendingOutgoingMessageID: String?
  @Published private(set) var outgoingMessageIssue: String?
  @Published var selectedMessageID: String?
  @Published private(set) var messageNavigationRequestID: String?
  @Published private(set) var messageCompositionRequest: MessageCompositionRequest?
  @Published var isRefreshing = false {
    didSet { menuBarStatus.updateRefreshing(isRefreshing) }
  }
  @Published var isSwitchingMode = false
  @Published private(set) var modeSwitchDestination: ModuleUsageMode?
  @Published var showingModeConfirmation = false
  @Published private(set) var modeConfirmationAllowsFactoryIdentityRewrite = false
  @Published var preferredInterface: String?
  @Published var preferredSerialPath: String
  @Published var apn: String
  @Published var notificationsEnabled: Bool
  @Published var deletesImportedMessages: Bool
  @Published var pollInterval: TimeInterval
  @Published var isDemoMode: Bool
  @Published var launchAtLogin = false
  @Published var launchAtLoginStatusMessage: String?

  private let service: ModemService?
  private let dockBadgeController: DockBadgeController
  private let networkInspector = NetworkInspector()
  private var trafficUsageTracker: TrafficUsageTracker
  private var pollingTask: Task<Void, Never>?
  private var incomingMessagesTask: Task<Void, Never>?
  private var outboxSendingTask: Task<Void, Never>?
  private var trafficTask: Task<Void, Never>?
  private var trafficSampler = NetworkTrafficSampler()
  private var refreshInProgress = false
  private var pendingForegroundRefresh = false
  private var operationRevision: UInt64 = 0
  private enum PendingModemConfigurationPurpose {
    case ecm
    case factoryIdentity
    case factoryNetworkMode
  }

  private enum ModemConfigurationWaitResult {
    case matched
    case differentDevice
    case timedOut
    case cancelled
  }

  private struct PendingModemConfigurationVerification {
    let expectedUSBIdentity: USBDeviceIdentifier?
    let previousUSBEnumerationIdentifier: USBEnumerationIdentifier?
    let expectedUSBNetworkMode: Int?
    let expectedEquipmentIdentity: String?
    let purpose: PendingModemConfigurationPurpose
    let pendingIssue: String?
  }

  private var pendingModemConfigurationVerification: PendingModemConfigurationVerification?
  private var pendingFactoryRestoreTarget: USBRestoreTarget?
  private var factoryRestoreContinuationTask: Task<Void, Never>?

  private static let currentBundleIdentifier = "com.local.DJIO"
  private static let legacyBundleIdentifier = "com.local.CellularBridge"
  private static let migratedDefaultsKey = "didMigrateCellularBridgeDefaults"
  private static let migratedDefaultsKeys = [
    "preferredInterface",
    "preferredSerialPath",
    "apn",
    "notificationsEnabled",
    "deletesImportedMessages",
    "pollInterval",
  ]

  var unreadCount: Int { messages.filter { !$0.isRead }.count }

  init(
    menuBarStatus: MenuBarStatusModel? = nil,
    dockBadgeController: DockBadgeController? = nil
  ) {
    self.menuBarStatus = menuBarStatus ?? MenuBarStatusModel()
    self.dockBadgeController = dockBadgeController ?? DockBadgeController()
    let trafficUsageTracker = TrafficUsageTracker()
    self.trafficUsageTracker = trafficUsageTracker
    trafficUsage = trafficUsageTracker.snapshot
    trafficPersistenceIssue = trafficUsageTracker.persistenceIssue
    let defaults = UserDefaults.standard
    if Bundle.main.bundleIdentifier == Self.currentBundleIdentifier {
      Self.migrateLegacyDefaultsIfNeeded(to: defaults)
    }
    preferredInterface = defaults.string(forKey: "preferredInterface")
    preferredSerialPath = defaults.string(forKey: "preferredSerialPath") ?? ""
    apn = defaults.string(forKey: "apn") ?? ""
    notificationsEnabled = defaults.bool(forKey: "notificationsEnabled")
    deletesImportedMessages =
      defaults.object(forKey: "deletesImportedMessages") == nil
      ? false : defaults.bool(forKey: "deletesImportedMessages")
    let configuredInterval = defaults.double(forKey: "pollInterval")
    pollInterval = configuredInterval >= 3 ? configuredInterval : 8
    isDemoMode = ProcessInfo.processInfo.arguments.contains("--demo")

    do {
      service = try ModemService()
    } catch {
      service = nil
      connection.issue = error.localizedDescription
    }
    if isDemoMode {
      installDemoState()
      if ProcessInfo.processInfo.arguments.contains("--preview-connection") {
        selection = .connection
      }
      if ProcessInfo.processInfo.arguments.contains("--preview-incoming-call") {
        presentedIncomingCall = IncomingCallRecord(
          id: "preview-incoming-call",
          callerNumber: "15342284706",
          receivedAt: Date()
        )
      }
    }
    refreshLaunchAtLoginStatus()
    self.menuBarStatus.update(connection: connection)
    updateUnreadIndicators()
    self.menuBarStatus.updateRefreshing(isRefreshing)
    self.menuBarStatus.updateTraffic(traffic)
  }

  deinit {
    pollingTask?.cancel()
    incomingMessagesTask?.cancel()
    outboxSendingTask?.cancel()
    trafficTask?.cancel()
  }

  func start() {
    guard pollingTask == nil else { return }
    if notificationsEnabled {
      Task { [weak self] in
        await self?.updateNotifications(true)
      }
    }
    startTrafficMonitoring()
    startIncomingMessageMonitoring()
    pollingTask = Task { [weak self] in
      if let model = self, !model.isDemoMode {
        await model.service?.setPreferredSerialPath(model.preferredSerialPath.nilIfEmpty)
        await model.service?.setDeletesImportedMessages(model.deletesImportedMessages)
        await model.loadMessages()
        await model.loadIncomingCalls()
        await model.loadOutbox()
        await model.refresh()
        model.resumeQueuedMessagesIfNeeded()
      }
      while !Task.isCancelled {
        guard
          let interval = self.map({
            $0.connection.control == .ready ? max(3, $0.pollInterval) : 1
          })
        else { return }
        let nanoseconds = UInt64(interval * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanoseconds)
        guard !Task.isCancelled, let model = self else { break }
        await model.refresh(showActivity: false)
      }
    }
  }

  private static func migrateLegacyDefaultsIfNeeded(to defaults: UserDefaults) {
    guard !defaults.bool(forKey: migratedDefaultsKey) else { return }
    if let legacyDefaults = UserDefaults(suiteName: legacyBundleIdentifier) {
      for key in migratedDefaultsKeys where defaults.object(forKey: key) == nil {
        guard let value = legacyDefaults.object(forKey: key) else { continue }
        defaults.set(value, forKey: key)
      }
    }
    defaults.set(true, forKey: migratedDefaultsKey)
  }

  func stop() {
    operationRevision &+= 1
    pollingTask?.cancel()
    pollingTask = nil
    incomingMessagesTask?.cancel()
    incomingMessagesTask = nil
    outboxSendingTask?.cancel()
    outboxSendingTask = nil
    isSendingMessage = false
    sendingOutgoingMessageID = nil
    trafficTask?.cancel()
    trafficTask = nil
    factoryRestoreContinuationTask?.cancel()
    factoryRestoreContinuationTask = nil
    trafficSampler.reset()
    traffic = .unavailable
    trafficUsage = trafficUsageTracker.sample(interfaceName: nil, counters: nil)
    try? trafficUsageTracker.flush()
    trafficPersistenceIssue = trafficUsageTracker.persistenceIssue
    if let service {
      Task { await service.disconnect() }
    }
  }

  func refresh(showActivity: Bool = true, allowDuringModeSwitch: Bool = false) async {
    if showActivity {
      isRefreshing = true
    }
    guard allowDuringModeSwitch || !isSwitchingMode else {
      pendingForegroundRefresh = pendingForegroundRefresh || showActivity
      return
    }
    guard !refreshInProgress else {
      pendingForegroundRefresh = pendingForegroundRefresh || showActivity
      return
    }
    let revision = operationRevision
    refreshInProgress = true
    defer {
      refreshInProgress = false
      if showActivity, !pendingForegroundRefresh {
        isRefreshing = false
      }
      schedulePendingForegroundRefreshIfPossible()
    }

    if isDemoMode {
      if showActivity {
        connection.lastUpdated = Date()
      }
      return
    }

    network = networkInspector.snapshot(preferredInterface: preferredInterface)
    synchronizeTrafficInterface()
    let networkIssue = networkStatusIssue()
    if network.selectedInterface?.isActive == true {
      connection.ecm = .ready
    } else if network.selectedInterface?.isLinkUp == true {
      connection.ecm = .warning
    } else {
      connection.ecm = .unavailable
    }
    connection.networkInterface = network.selectedInterface?.name
    connection.networkAddress = network.selectedInterface?.address
    connection.primaryInterface = network.primaryInterface
    if showActivity {
      connection.device = .checking
      connection.control = .checking
    }

    guard let service else {
      connection.device = .warning
      connection.control = .warning
      connection.issue = "短信数据库初始化失败"
      return
    }

    let messageIDsBeforePoll = Set(messages.map(\.id))
    do {
      let result = try await service.poll()
      guard revision == operationRevision else { return }
      connection.device = .ready
      connection.control = .ready
      connection.usbDeviceIdentifier = result.transport.usbDeviceIdentifier
      connection.usbEnumerationIdentifier = result.transport.usbEnumerationIdentifier
      connection.usbNetworkMode = result.usbNetworkMode
      connection.transportDescription = result.transport.summary
      connection.signalRSSI = result.signalRSSI
      connection.registration = result.registration
      connection.operatorName = result.operatorName
      connection.cellularDetails = result.cellularDetails
      connection.cellular = ["已注册", "漫游"].contains(result.registration) ? .ready : .warning
      connection.lastUpdated = Date()
      let modeSwitchIssue = await pendingModemConfigurationIssue(
        observedUSBIdentity: result.transport.usbDeviceIdentifier,
        revision: revision
      )
      guard revision == operationRevision else { return }
      connection.issue =
        modeSwitchIssue
        ?? result.warnings.first
        ?? (result.usbNetworkMode == 0 ? nil : networkIssue)
      if !result.newMessages.isEmpty {
        await loadMessages()
        for message in result.newMessages where !message.isRead {
          await postNotification(for: message)
        }
      }
      resumeQueuedMessagesIfNeeded()
    } catch {
      guard revision == operationRevision else { return }
      let transportIssue = error.localizedDescription
      await loadMessages()
      guard revision == operationRevision else { return }
      for message in messages where !message.isRead && !messageIDsBeforePoll.contains(message.id) {
        await postNotification(for: message)
      }
      guard revision == operationRevision else { return }
      connection.device = connection.ecm == .ready ? .ready : .unavailable
      connection.control = .unavailable
      connection.cellular = .unavailable
      connection.usbDeviceIdentifier = nil
      connection.usbEnumerationIdentifier = nil
      connection.usbNetworkMode = nil
      connection.cellularDetails = CellularDetails()
      connection.transportDescription = "等待 AT 通道"
      connection.issue = transportIssue
    }
  }

  func presentModeSwitchConfirmation() {
    modeConfirmationAllowsFactoryIdentityRewrite =
      connection.usbDeviceIdentifier == .djiFirstGenerationFactory
    showingModeConfirmation = true
  }

  func restoreDJIFactoryUSBConfigurationFromCurrentState() async {
    let plan: DJIFactoryUSBRestorePlan?
    if connection.usbDeviceIdentifier == .quectelEC25 {
      plan = .identityAndNetworkMode
    } else if connection.usbDeviceIdentifier == .djiFirstGenerationFactory,
      connection.usbNetworkMode != 0
    {
      plan = .networkModeOnly
    } else {
      plan = nil
    }
    guard let plan else { return }
    await restoreDJIFactoryUSBConfiguration(plan: plan)
  }

  func switchToECM(allowFactoryIdentityRewrite: Bool) async {
    guard !isSwitchingMode, !isSendingMessage else { return }
    factoryRestoreContinuationTask?.cancel()
    factoryRestoreContinuationTask = nil
    pendingFactoryRestoreTarget = nil
    pendingModemConfigurationVerification = nil
    operationRevision &+= 1
    let revision = operationRevision
    isSwitchingMode = true
    modeSwitchDestination = .ecm
    defer {
      isSwitchingMode = false
      modeSwitchDestination = nil
      schedulePendingForegroundRefreshIfPossible()
      resumeQueuedMessagesIfNeeded()
    }

    if isDemoMode {
      try? await Task.sleep(nanoseconds: 900_000_000)
      guard revision == operationRevision else { return }
      connection.usbDeviceIdentifier = .quectelEC25
      connection.usbNetworkMode = 1
      connection.transportDescription =
        "USB AT · 2C7C:0125 · 接口 2 · 0x03/0x84"
      connection.ecm = .ready
      connection.issue = nil
      return
    }
    guard let service else { return }
    do {
      let result = try await service.switchToECM(
        apn: apn.trimmingCharacters(in: .whitespacesAndNewlines),
        allowFactoryIdentityRewrite: allowFactoryIdentityRewrite
      )
      guard revision == operationRevision else { return }
      pendingFactoryRestoreTarget = nil
      pendingModemConfigurationVerification = PendingModemConfigurationVerification(
        expectedUSBIdentity: result.expectedUSBIdentity,
        previousUSBEnumerationIdentifier: nil,
        expectedUSBNetworkMode: result.expectedUSBIdentity == nil ? nil : 1,
        expectedEquipmentIdentity: nil,
        purpose: .ecm,
        pendingIssue: nil
      )
      connection.device = .checking
      connection.control = .checking
      connection.ecm = .checking
      connection.issue =
        result.didRewriteUSBIdentity
        ? "模块正在应用新的 USB 身份并重新枚举，连接会在数秒后恢复"
        : "模块正在重新枚举，连接会在数秒后恢复"
      let reenumerationDelay: UInt64 =
        result.didRewriteUSBIdentity ? 5_000_000_000 : 2_000_000_000
      try? await Task.sleep(nanoseconds: reenumerationDelay)
      guard revision == operationRevision else { return }
      await refresh(allowDuringModeSwitch: true)
    } catch {
      guard revision == operationRevision else { return }
      if let modeSwitchError = error as? ECMModeSwitchError,
        modeSwitchError.shouldVerifyModeSwitch
      {
        pendingFactoryRestoreTarget = nil
        pendingModemConfigurationVerification = PendingModemConfigurationVerification(
          expectedUSBIdentity: modeSwitchError.expectedUSBIdentity,
          previousUSBEnumerationIdentifier: nil,
          expectedUSBNetworkMode: modeSwitchError.expectedUSBIdentity == nil ? nil : 1,
          expectedEquipmentIdentity: nil,
          purpose: .ecm,
          pendingIssue: modeSwitchError.localizedDescription
        )
      }
      connection.issue = error.localizedDescription
      guard
        let modeSwitchError = error as? ECMModeSwitchError,
        modeSwitchError.shouldWaitForReenumeration
      else { return }
      connection.device = .checking
      connection.control = .checking
      connection.ecm = .checking
      try? await Task.sleep(nanoseconds: 5_000_000_000)
      guard revision == operationRevision else { return }
      await refresh(allowDuringModeSwitch: true)
    }
  }

  func restoreDJIFactoryUSBConfiguration(plan: DJIFactoryUSBRestorePlan) async {
    guard !isSwitchingMode, !isSendingMessage else { return }
    pendingModemConfigurationVerification = nil
    operationRevision &+= 1
    let revision = operationRevision
    isSwitchingMode = true
    modeSwitchDestination = .dji
    defer {
      isSwitchingMode = false
      modeSwitchDestination = nil
      schedulePendingForegroundRefreshIfPossible()
      resumeQueuedMessagesIfNeeded()
    }

    if isDemoMode {
      try? await Task.sleep(nanoseconds: 900_000_000)
      guard revision == operationRevision else { return }
      connection.usbDeviceIdentifier = .djiFirstGenerationFactory
      connection.usbNetworkMode = 0
      connection.transportDescription =
        "USB AT · 2CA3:4006 · 接口 2 · 0x03/0x84"
      connection.ecm = .unavailable
      connection.networkInterface = nil
      connection.networkAddress = nil
      connection.issue = nil
      return
    }
    guard let service else { return }

    switch plan {
    case .identityAndNetworkMode:
      guard connection.usbDeviceIdentifier == .quectelEC25 else {
        connection.issue =
          "模块状态已在确认后发生变化，未执行 USB 身份改写。请刷新后重新确认。"
        return
      }
    case .networkModeOnly:
      guard connection.usbDeviceIdentifier == .djiFirstGenerationFactory else {
        connection.issue =
          "模块状态已在确认后发生变化，本次仅恢复 usbnet 的授权未执行 USB 身份改写。"
        return
      }
    }

    var restoreTarget =
      plan.includesIdentityRewrite ? nil : pendingFactoryRestoreTarget
    var factoryIdentityObserved =
      connection.usbDeviceIdentifier == .djiFirstGenerationFactory
    if plan.includesIdentityRewrite {
      pendingFactoryRestoreTarget = nil
      do {
        let result = try await service.restoreFactoryUSBIdentity(
          authorized: true
        )
        guard revision == operationRevision else { return }
        restoreTarget = result.target
        pendingFactoryRestoreTarget = result.target
        pendingModemConfigurationVerification = PendingModemConfigurationVerification(
          expectedUSBIdentity: result.expectedUSBIdentity,
          previousUSBEnumerationIdentifier: result.target.enumerationIdentifier,
          expectedUSBNetworkMode: nil,
          expectedEquipmentIdentity: result.target.equipmentIdentity,
          purpose: .factoryIdentity,
          pendingIssue: nil
        )
        markModemConfigurationInProgress(
          "正在恢复大疆 USB 标识；模块完成第一次重新枚举后会继续恢复私有模式"
        )
      } catch {
        guard revision == operationRevision else { return }
        guard let restoreError = error as? USBIdentityRestoreError else {
          connection.issue = error.localizedDescription
          return
        }
        restoreTarget = restoreError.target
        if let restoreTarget {
          pendingFactoryRestoreTarget = restoreTarget
        }
        if restoreError.shouldVerifyIdentityRestore {
          pendingModemConfigurationVerification = PendingModemConfigurationVerification(
            expectedUSBIdentity: restoreError.expectedUSBIdentity,
            previousUSBEnumerationIdentifier:
              restoreError.target?.enumerationIdentifier,
            expectedUSBNetworkMode: nil,
            expectedEquipmentIdentity: restoreError.target?.equipmentIdentity,
            purpose: .factoryIdentity,
            pendingIssue: restoreError.localizedDescription
          )
        }
        connection.issue = error.localizedDescription
        guard
          restoreError.shouldWaitForReenumeration
        else { return }
        markModemConfigurationInProgress(
          "正在确认大疆 USB 标识是否已生效；重连后会继续恢复私有模式"
        )
      }

      guard let restoreTarget else { return }
      let identityWaitResult = await waitForModemConfiguration(
        expectedUSBIdentity: .djiFirstGenerationFactory,
        previousUSBEnumerationIdentifier: restoreTarget.enumerationIdentifier,
        expectedUSBNetworkMode: nil,
        expectedEquipmentIdentity: restoreTarget.equipmentIdentity,
        revision: revision,
        progressIssue: "正在等待模块以 2CA3:4006 重新枚举"
      )
      guard revision == operationRevision else { return }
      switch identityWaitResult {
      case .matched:
        factoryIdentityObserved = true
      case .differentDevice, .cancelled:
        return
      case .timedOut:
        let issue =
          "大疆 USB 标识恢复指令已发送，但等待多轮后仍未确认模块完成重新枚举；"
          + "请保持连接，模块出现后 DJIO 会自动继续第二阶段，无需再次点击。"
        pendingModemConfigurationVerification = PendingModemConfigurationVerification(
          expectedUSBIdentity: .djiFirstGenerationFactory,
          previousUSBEnumerationIdentifier: restoreTarget.enumerationIdentifier,
          expectedUSBNetworkMode: nil,
          expectedEquipmentIdentity: restoreTarget.equipmentIdentity,
          purpose: .factoryIdentity,
          pendingIssue: issue
        )
        connection.issue = issue
        return
      }
    }

    guard factoryIdentityObserved else { return }

    do {
      let result = try await service.restoreFactoryUSBNetworkMode(
        authorized: true,
        expectedEquipmentIdentity: restoreTarget?.equipmentIdentity
      )
      guard revision == operationRevision else { return }
      pendingFactoryRestoreTarget = result.target
      pendingModemConfigurationVerification = PendingModemConfigurationVerification(
        expectedUSBIdentity: result.expectedUSBIdentity,
        previousUSBEnumerationIdentifier:
          result.didChangeMode ? result.target.enumerationIdentifier : nil,
        expectedUSBNetworkMode: result.expectedUSBNetworkMode,
        expectedEquipmentIdentity: result.target.equipmentIdentity,
        purpose: .factoryNetworkMode,
        pendingIssue: nil
      )
      if result.didChangeMode {
        markModemConfigurationInProgress(
          "正在恢复 usbnet=0 大疆私有模式；模块会再次重新枚举"
        )
        let modeWaitResult = await waitForModemConfiguration(
          expectedUSBIdentity: result.expectedUSBIdentity,
          previousUSBEnumerationIdentifier: result.target.enumerationIdentifier,
          expectedUSBNetworkMode: result.expectedUSBNetworkMode,
          expectedEquipmentIdentity: result.target.equipmentIdentity,
          revision: revision,
          progressIssue: "正在等待模块以大疆私有模式重新枚举"
        )
        guard revision == operationRevision else { return }
        switch modeWaitResult {
        case .matched:
          break
        case .differentDevice, .cancelled:
          return
        case .timedOut:
          let issue =
            "usbnet=0 恢复指令已发送，但等待多轮后仍未确认第二次重新枚举完成；"
            + "请保持连接并刷新，最终状态应为 2CA3:4006、usbnet=0。"
          pendingModemConfigurationVerification = PendingModemConfigurationVerification(
            expectedUSBIdentity: result.expectedUSBIdentity,
            previousUSBEnumerationIdentifier: result.target.enumerationIdentifier,
            expectedUSBNetworkMode: result.expectedUSBNetworkMode,
            expectedEquipmentIdentity: result.target.equipmentIdentity,
            purpose: .factoryNetworkMode,
            pendingIssue: issue
          )
          connection.issue = issue
          return
        }
      } else {
        await refresh(allowDuringModeSwitch: true)
      }
      pendingFactoryRestoreTarget = nil
    } catch {
      guard revision == operationRevision else { return }
      guard let modeRestoreError = error as? USBNetworkModeRestoreError else {
        connection.issue = error.localizedDescription
        return
      }
      if modeRestoreError.shouldVerifyNetworkModeRestore {
        if let target = modeRestoreError.target {
          pendingFactoryRestoreTarget = target
        }
        pendingModemConfigurationVerification = PendingModemConfigurationVerification(
          expectedUSBIdentity: modeRestoreError.expectedUSBIdentity,
          previousUSBEnumerationIdentifier:
            modeRestoreError.target?.enumerationIdentifier,
          expectedUSBNetworkMode: modeRestoreError.expectedUSBNetworkMode,
          expectedEquipmentIdentity: modeRestoreError.target?.equipmentIdentity,
          purpose: .factoryNetworkMode,
          pendingIssue: modeRestoreError.localizedDescription
        )
      }
      connection.issue = error.localizedDescription
      guard
        modeRestoreError.shouldWaitForReenumeration,
        let modeRestoreTarget = modeRestoreError.target,
        let expectedUSBNetworkMode = modeRestoreError.expectedUSBNetworkMode
      else { return }
      markModemConfigurationInProgress(
        "正在确认 usbnet=0 是否已生效；模块重新枚举后会自动验证"
      )
      let modeWaitResult = await waitForModemConfiguration(
        expectedUSBIdentity: .djiFirstGenerationFactory,
        previousUSBEnumerationIdentifier: modeRestoreTarget.enumerationIdentifier,
        expectedUSBNetworkMode: expectedUSBNetworkMode,
        expectedEquipmentIdentity: modeRestoreTarget.equipmentIdentity,
        revision: revision,
        progressIssue: "正在等待模块以大疆私有模式重新枚举"
      )
      guard revision == operationRevision else { return }
      switch modeWaitResult {
      case .matched:
        pendingFactoryRestoreTarget = nil
        return
      case .differentDevice, .cancelled:
        return
      case .timedOut:
        break
      }
      let issue =
        "恢复 usbnet=0 的结果仍无法确认；请保持连接并刷新，"
        + "最终状态应为 2CA3:4006、usbnet=0。"
      pendingModemConfigurationVerification = PendingModemConfigurationVerification(
        expectedUSBIdentity: .djiFirstGenerationFactory,
        previousUSBEnumerationIdentifier: modeRestoreTarget.enumerationIdentifier,
        expectedUSBNetworkMode: expectedUSBNetworkMode,
        expectedEquipmentIdentity: modeRestoreTarget.equipmentIdentity,
        purpose: .factoryNetworkMode,
        pendingIssue: issue
      )
      connection.issue = issue
    }
  }

  private func waitForModemConfiguration(
    expectedUSBIdentity: USBDeviceIdentifier,
    previousUSBEnumerationIdentifier: USBEnumerationIdentifier,
    expectedUSBNetworkMode: Int?,
    expectedEquipmentIdentity: String,
    revision: UInt64,
    progressIssue: String
  ) async -> ModemConfigurationWaitResult {
    guard let service else { return .cancelled }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(30))
    while clock.now < deadline {
      let nextCheck = min(
        clock.now.advanced(by: .milliseconds(2_500)),
        deadline
      )
      try? await clock.sleep(until: nextCheck)
      guard revision == operationRevision, !Task.isCancelled else { return .cancelled }
      await refresh(allowDuringModeSwitch: true)
      guard revision == operationRevision else { return .cancelled }
      let identityMatches =
        connection.usbDeviceIdentifier == expectedUSBIdentity
      let enumerationChanged =
        connection.usbEnumerationIdentifier != nil
        && connection.usbEnumerationIdentifier != previousUSBEnumerationIdentifier
      let modeMatches =
        expectedUSBNetworkMode.map { connection.usbNetworkMode == $0 } ?? true
      if identityMatches, modeMatches {
        do {
          let observedEquipmentIdentity =
            try await service.currentUSBEquipmentIdentity(
              expectedUSBIdentity: expectedUSBIdentity
            )
          guard revision == operationRevision, !Task.isCancelled else {
            return .cancelled
          }
          if let observedEquipmentIdentity {
            guard observedEquipmentIdentity == expectedEquipmentIdentity else {
              connection.issue =
                "重新连接后的模块与本次确认恢复的模块不是同一设备；"
                + "已停止后续操作，且不会写入其他模块。"
              return .differentDevice
            }
            return .matched
          }
        } catch {
          guard revision == operationRevision, !Task.isCancelled else {
            return .cancelled
          }
        }
        markModemConfigurationInProgress(
          "目标 USB 配置已出现，正在核对是否为同一只模块"
        )
        continue
      }
      markModemConfigurationInProgress(
        enumerationChanged
          ? "\(progressIssue)；已检测到新的 USB 枚举，正在确认目标配置"
          : progressIssue
      )
    }
    return .timedOut
  }

  private func markModemConfigurationInProgress(_ issue: String) {
    connection.device = .checking
    connection.control = .checking
    connection.ecm = .checking
    connection.issue = issue
  }

  private func pendingModemConfigurationIssue(
    observedUSBIdentity: USBDeviceIdentifier?,
    revision: UInt64
  ) async -> String? {
    guard let verification = pendingModemConfigurationVerification else { return nil }
    let enumerationChanged =
      verification.previousUSBEnumerationIdentifier.map {
        connection.usbEnumerationIdentifier != nil
          && connection.usbEnumerationIdentifier != $0
      } ?? true
    let requiresEnumerationChange =
      verification.previousUSBEnumerationIdentifier != nil
      && verification.expectedEquipmentIdentity == nil

    if requiresEnumerationChange,
      !enumerationChanged
    {
      return verification.pendingIssue ?? "模块尚未完成 USB 重新枚举"
    }

    if let expectedUSBIdentity = verification.expectedUSBIdentity,
      observedUSBIdentity != expectedUSBIdentity
    {
      if requiresEnumerationChange, !enumerationChanged {
        return verification.pendingIssue ?? "模块尚未完成 USB 重新枚举"
      }
      if let pendingIssue = verification.pendingIssue {
        return pendingIssue
      }
      if let observedUSBIdentity {
        return
          "USB 标识修改未生效：预期 \(expectedUSBIdentity)，"
          + "当前仍为 \(observedUSBIdentity)"
      }
      return "模块已重新连接，但无法确认修改后的 USB 标识"
    }

    if let expectedUSBNetworkMode = verification.expectedUSBNetworkMode,
      connection.usbNetworkMode != expectedUSBNetworkMode
    {
      if requiresEnumerationChange, !enumerationChanged {
        return verification.pendingIssue ?? "模块尚未完成 USB 重新枚举"
      }
      if let pendingIssue = verification.pendingIssue {
        return pendingIssue
      }
      if let observedMode = connection.usbNetworkMode {
        return
          "USB 网络模式修改未生效：预期 usbnet=\(expectedUSBNetworkMode)，"
          + "当前为 usbnet=\(observedMode)"
      }
      return "模块已重新连接，但无法确认修改后的 USB 网络模式"
    }

    guard
      verification.purpose != .ecm
        || connection.ecm == .ready
        || connection.ecm == .warning
    else {
      return verification.pendingIssue ?? "模块已重新连接，但未检测到 ECM 网络接口"
    }

    if let expectedEquipmentIdentity = verification.expectedEquipmentIdentity,
      let expectedUSBIdentity = verification.expectedUSBIdentity
    {
      guard let service else {
        return "目标 USB 配置已出现，但无法核对是否为同一只模块"
      }
      do {
        let observedEquipmentIdentity =
          try await service.currentUSBEquipmentIdentity(
            expectedUSBIdentity: expectedUSBIdentity
          )
        guard revision == operationRevision else { return nil }
        guard let observedEquipmentIdentity else {
          return verification.pendingIssue
            ?? "目标 USB 配置已出现，但尚未读取到模块 IMEI"
        }
        guard observedEquipmentIdentity == expectedEquipmentIdentity else {
          return
            "重新连接后的模块与本次确认恢复的模块不是同一设备；"
            + "已保留恢复检查点，且不会写入其他模块。"
        }
      } catch {
        guard revision == operationRevision else { return nil }
        return verification.pendingIssue
          ?? "目标 USB 配置已出现，但核对模块 IMEI 失败：\(error.localizedDescription)"
      }
    }

    guard revision == operationRevision else { return nil }
    switch verification.purpose {
    case .ecm:
      pendingModemConfigurationVerification = nil
    case .factoryIdentity:
      if connection.usbNetworkMode == 0 {
        pendingModemConfigurationVerification = nil
        pendingFactoryRestoreTarget = nil
      } else if isSwitchingMode {
        pendingModemConfigurationVerification = nil
      } else {
        schedulePendingFactoryNetworkModeRestore()
        return "大疆 USB 标识已恢复，正在自动继续恢复私有模式；无需再次点击"
      }
    case .factoryNetworkMode:
      pendingModemConfigurationVerification = nil
      pendingFactoryRestoreTarget = nil
    }
    return nil
  }

  private func schedulePendingFactoryNetworkModeRestore() {
    guard
      factoryRestoreContinuationTask == nil,
      pendingFactoryRestoreTarget != nil
    else { return }

    factoryRestoreContinuationTask = Task { @MainActor [weak self] in
      await Task.yield()
      guard let self else { return }
      defer { self.factoryRestoreContinuationTask = nil }
      guard
        !Task.isCancelled,
        !self.isSwitchingMode,
        !self.isSendingMessage,
        self.connection.usbDeviceIdentifier == .djiFirstGenerationFactory,
        self.connection.usbNetworkMode != 0,
        self.pendingFactoryRestoreTarget != nil
      else { return }
      await self.restoreDJIFactoryUSBConfiguration(plan: .networkModeOnly)
    }
  }

  func selectMessage(_ id: String?) {
    selectedMessageID = id
    guard let id, let index = messages.firstIndex(where: { $0.id == id }), !messages[index].isRead
    else { return }
    messages[index].isRead = true
    guard !isDemoMode, let service else { return }
    Task {
      try? await service.markRead(id: id)
    }
  }

  func selectConversation(messageIDs: [String]) {
    if selectedMessageID != messageIDs.last {
      selectedMessageID = messageIDs.last
    }
    let ids = Set(messageIDs)
    var updatedMessages = messages
    var unreadIDs: [String] = []
    for index in updatedMessages.indices
    where ids.contains(updatedMessages[index].id)
      && !updatedMessages[index].isRead
    {
      updatedMessages[index].isRead = true
      unreadIDs.append(updatedMessages[index].id)
    }
    if !unreadIDs.isEmpty {
      messages = updatedMessages
    }
    guard !isDemoMode, !unreadIDs.isEmpty, let service else { return }
    Task {
      for id in unreadIDs {
        try? await service.markRead(id: id)
      }
    }
  }

  func openMessageFromNotification(_ id: String) async {
    messageNavigationRequestID = id
    if !isDemoMode {
      await loadMessages()
    }
    selectedMessageID = id
    selection = .messages
  }

  func openMessageComposer(for recipient: String) {
    let trimmed = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    messageCompositionRequest = MessageCompositionRequest(id: UUID(), recipient: trimmed)
    selection = .messages
  }

  func openIncomingCallsFromNotification() {
    selection = .calls
  }

  func dismissIncomingCallPresentation() {
    presentedIncomingCall = nil
  }

  func hangUpIncomingCall() async -> Bool {
    if isDemoMode {
      presentedIncomingCall = nil
      return true
    }
    guard let service else {
      connection.issue = "无法挂断：未连接到蜂窝模块。"
      return false
    }
    do {
      try await service.hangUpIncomingCall()
      presentedIncomingCall = nil
      return true
    } catch {
      connection.issue = "挂断失败：\(error.localizedDescription)"
      return false
    }
  }

  func openIncomingCallPresentation() {
    presentedIncomingCall = nil
    openIncomingCallsFromNotification()
  }

  func consumeMessageNavigationRequest(_ id: String) {
    guard messageNavigationRequestID == id else { return }
    messageNavigationRequestID = nil
  }

  func consumeMessageCompositionRequest(_ id: UUID) {
    guard messageCompositionRequest?.id == id else { return }
    messageCompositionRequest = nil
  }

  func deleteSelectedMessage() async {
    guard let id = selectedMessageID else { return }
    await deleteMessage(id: id)
  }

  func deleteMessage(id: String) async {
    if isDemoMode {
      messages.removeAll { $0.id == id }
      if selectedMessageID == id {
        selectedMessageID = messages.first?.id
      }
      return
    }
    guard let service else { return }
    do {
      try await service.deleteLocalMessage(id: id)
      await loadMessages()
      if selectedMessageID == id {
        selectedMessageID = messages.first?.id
      }
    } catch {
      connection.issue = error.localizedDescription
    }
  }

  @discardableResult
  func sendMessage(recipient: String, body: String) async -> Bool {
    guard !isSendingMessage else { return false }
    outgoingMessageIssue = nil

    if isDemoMode {
      return await sendDemoMessage(recipient: recipient, body: body)
    }

    guard let service else {
      outgoingMessageIssue = "短信发件箱不可用"
      return false
    }

    isSendingMessage = true
    do {
      let message = try await service.enqueueMessage(recipient: recipient, body: body)
      upsertOutgoingMessage(message)
      if canStartQueuedMessages {
        sendingOutgoingMessageID = message.id
        startSendingQueuedMessages(using: service)
      } else {
        isSendingMessage = false
      }
      return true
    } catch {
      isSendingMessage = false
      sendingOutgoingMessageID = nil
      outgoingMessageIssue = error.localizedDescription
      return false
    }
  }

  func retryOutgoingMessage(id: String) async {
    guard !isSendingMessage else { return }
    outgoingMessageIssue = nil

    if isDemoMode {
      await retryDemoOutgoingMessage(id: id)
      return
    }

    guard let service else {
      outgoingMessageIssue = "短信发件箱不可用"
      return
    }

    isSendingMessage = true
    sendingOutgoingMessageID = id
    do {
      let message = try await service.retryOutgoingMessage(id: id)
      upsertOutgoingMessage(message)
      if canStartQueuedMessages {
        startSendingQueuedMessages(using: service)
      } else {
        isSendingMessage = false
        sendingOutgoingMessageID = nil
      }
    } catch {
      isSendingMessage = false
      sendingOutgoingMessageID = nil
      outgoingMessageIssue = error.localizedDescription
      await loadOutbox()
    }
  }

  func deleteOutgoingMessage(id: String) async {
    guard !isSendingMessage else { return }
    outgoingMessageIssue = nil
    if isDemoMode {
      outbox.removeAll { $0.id == id }
      return
    }
    guard let service else {
      outgoingMessageIssue = "短信发件箱不可用"
      return
    }
    do {
      try await service.deleteOutgoingMessage(id: id)
      outbox.removeAll { $0.id == id }
      resumeQueuedMessagesIfNeeded()
    } catch {
      outgoingMessageIssue = error.localizedDescription
    }
  }

  func refreshOutbox() async {
    outgoingMessageIssue = nil
    await loadOutbox()
  }

  func clearOutgoingMessageIssue() {
    outgoingMessageIssue = nil
  }

  func updatePreferredInterface(_ value: String?) {
    preferredInterface = value
    UserDefaults.standard.set(value, forKey: "preferredInterface")
    network = networkInspector.snapshot(preferredInterface: value)
    synchronizeTrafficInterface()
  }

  func updateAPN(_ value: String) {
    apn = value
    UserDefaults.standard.set(value, forKey: "apn")
  }

  func updatePreferredSerialPath(_ value: String) {
    preferredSerialPath = value
    UserDefaults.standard.set(value, forKey: "preferredSerialPath")
    if let service {
      Task { await service.setPreferredSerialPath(value.nilIfEmpty) }
    }
  }

  func updatePollInterval(_ value: TimeInterval) {
    pollInterval = max(3, min(60, value))
    UserDefaults.standard.set(pollInterval, forKey: "pollInterval")
  }

  func updateNotifications(_ enabled: Bool) async {
    if enabled {
      notificationsEnabled = true
      do {
        let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [
          .alert, .sound,
        ])
        if !granted {
          connection.issue = "请在“系统设置 > 通知 > DJIO”中允许通知。"
        }
      } catch {
        connection.issue = "请在“系统设置 > 通知 > DJIO”中允许通知。"
      }
    } else {
      notificationsEnabled = false
    }
    UserDefaults.standard.set(notificationsEnabled, forKey: "notificationsEnabled")
  }

  func updateLaunchAtLogin(_ enabled: Bool) {
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
      refreshLaunchAtLoginStatus()
    } catch {
      refreshLaunchAtLoginStatus()
      launchAtLoginStatusMessage = error.localizedDescription
    }
  }

  func updateDeletesImportedMessages(_ enabled: Bool) {
    deletesImportedMessages = enabled
    UserDefaults.standard.set(enabled, forKey: "deletesImportedMessages")
    if let service {
      Task { await service.setDeletesImportedMessages(enabled) }
    }
  }

  private func startIncomingMessageMonitoring() {
    guard !isDemoMode, incomingMessagesTask == nil, let service else { return }
    incomingMessagesTask = Task { [weak self] in
      let events = await service.incomingMessages()
      for await event in events {
        guard !Task.isCancelled, let self else { break }
        switch event {
        case .received(let message):
          await self.loadMessages()
          if !message.isRead {
            await self.postNotification(for: message)
          }
        case .incomingCall(let call):
          await self.loadIncomingCalls()
          if self.notificationsEnabled {
            self.presentedIncomingCall = call
          }
        case .incomingCallUpdated(let call):
          await self.loadIncomingCalls()
          if self.presentedIncomingCall?.id == call.id {
            self.presentedIncomingCall = call
          }
        case .incomingCallEnded(let callID):
          if self.presentedIncomingCall?.id == callID {
            self.presentedIncomingCall = nil
          }
        case .warning(let warning):
          self.connection.issue = warning
        }
      }
    }
  }

  private func loadMessages() async {
    guard let service else { return }
    do {
      messages = try await service.messages()
      if selectedMessageID == nil {
        selectedMessageID = messages.first?.id
      }
    } catch {
      connection.issue = error.localizedDescription
    }
  }

  private func loadIncomingCalls() async {
    guard let service else { return }
    do {
      incomingCalls = try await service.calls()
    } catch {
      connection.issue = error.localizedDescription
    }
  }

  private func loadOutbox() async {
    guard !isDemoMode, let service else { return }
    do {
      outbox = try await service.outboxMessages()
    } catch {
      outgoingMessageIssue = error.localizedDescription
    }
  }

  private func resumeQueuedMessagesIfNeeded() {
    guard !isDemoMode, canStartQueuedMessages, !isSendingMessage, let service,
      let next = outbox.filter({ $0.state == .queued }).min(by: { $0.createdAt < $1.createdAt })
    else { return }
    isSendingMessage = true
    sendingOutgoingMessageID = next.id
    startSendingQueuedMessages(using: service)
  }

  private func startSendingQueuedMessages(using service: ModemService) {
    let revision = operationRevision
    outboxSendingTask = Task { [weak self] in
      guard let self else { return }
      defer {
        if revision == self.operationRevision {
          self.isSendingMessage = false
          self.sendingOutgoingMessageID = nil
          self.outboxSendingTask = nil
        }
      }
      do {
        let updates = try await service.sendQueuedMessages { [weak self] message in
          guard !Task.isCancelled else { return }
          await self?.applyOutgoingMessageUpdate(message, revision: revision)
        }
        for message in updates {
          applyOutgoingMessageUpdate(message, revision: revision)
        }
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled, revision == self.operationRevision else { return }
        self.outgoingMessageIssue = error.localizedDescription
      }
      if !Task.isCancelled, revision == self.operationRevision {
        await self.loadOutbox()
      }
    }
  }

  private func applyOutgoingMessageUpdate(_ message: OutgoingSMS, revision: UInt64) {
    guard revision == operationRevision else { return }
    upsertOutgoingMessage(message)
    if message.state == .sending {
      sendingOutgoingMessageID = message.id
    } else if sendingOutgoingMessageID == message.id {
      sendingOutgoingMessageID = nil
    }
  }

  private func upsertOutgoingMessage(_ message: OutgoingSMS) {
    if let index = outbox.firstIndex(where: { $0.id == message.id }) {
      outbox[index] = message
    } else {
      outbox.append(message)
    }
    outbox.sort { left, right in
      if left.createdAt != right.createdAt {
        return left.createdAt > right.createdAt
      }
      return left.id > right.id
    }
  }

  private func sendDemoMessage(recipient: String, body: String) async -> Bool {
    isSendingMessage = true
    defer {
      isSendingMessage = false
      sendingOutgoingMessageID = nil
    }
    do {
      let encoded = try SMSPDUEncoder(concatenationReferenceProvider: { 1 }).encode(
        recipient: recipient,
        body: body
      )
      let now = Date()
      let id = UUID().uuidString
      sendingOutgoingMessageID = id
      let queuedParts = encoded.enumerated().map { offset, part in
        OutgoingSMSPart(
          index: offset,
          pdu: part.pdu,
          tpduLength: part.tpduLength,
          state: .queued,
          attemptCount: 0,
          modemReference: nil,
          lastError: nil,
          updatedAt: now
        )
      }
      upsertOutgoingMessage(
        OutgoingSMS(
          id: id,
          recipient: encoded[0].recipient,
          body: body,
          concatenationReference: encoded[0].concatenationReference,
          state: .sending,
          createdAt: now,
          updatedAt: now,
          sentAt: nil,
          attemptCount: 1,
          lastError: nil,
          parts: queuedParts
        ))
      try await Task.sleep(nanoseconds: 450_000_000)
      let sentAt = Date()
      let sentParts = queuedParts.map {
        OutgoingSMSPart(
          index: $0.index,
          pdu: $0.pdu,
          tpduLength: $0.tpduLength,
          state: .sent,
          attemptCount: 1,
          modemReference: 100 + $0.index,
          lastError: nil,
          updatedAt: sentAt
        )
      }
      upsertOutgoingMessage(
        OutgoingSMS(
          id: id,
          recipient: encoded[0].recipient,
          body: body,
          concatenationReference: encoded[0].concatenationReference,
          state: .sent,
          createdAt: now,
          updatedAt: sentAt,
          sentAt: sentAt,
          attemptCount: 1,
          lastError: nil,
          parts: sentParts
        ))
      return true
    } catch {
      outgoingMessageIssue = error.localizedDescription
      return false
    }
  }

  private func retryDemoOutgoingMessage(id: String) async {
    guard let message = outbox.first(where: { $0.id == id }) else { return }
    isSendingMessage = true
    sendingOutgoingMessageID = id
    defer {
      isSendingMessage = false
      sendingOutgoingMessageID = nil
    }
    try? await Task.sleep(nanoseconds: 450_000_000)
    let sentAt = Date()
    upsertOutgoingMessage(
      OutgoingSMS(
        id: message.id,
        recipient: message.recipient,
        body: message.body,
        concatenationReference: message.concatenationReference,
        state: .sent,
        createdAt: message.createdAt,
        updatedAt: sentAt,
        sentAt: sentAt,
        attemptCount: message.attemptCount + 1,
        lastError: nil,
        parts: message.parts.map {
          OutgoingSMSPart(
            index: $0.index,
            pdu: $0.pdu,
            tpduLength: $0.tpduLength,
            state: .sent,
            attemptCount: $0.attemptCount + ($0.state == .sent ? 0 : 1),
            modemReference: $0.modemReference ?? 100 + $0.index,
            lastError: nil,
            updatedAt: sentAt
          )
        }
      ))
  }

  private func updateUnreadIndicators() {
    menuBarStatus.updateUnreadCount(unreadCount)
    dockBadgeController.updateUnreadCount(unreadCount)
  }

  private func postNotification(for message: SMSMessage) async {
    guard notificationsEnabled else { return }
    let content = UNMutableNotificationContent()
    content.title = message.sender
    content.body = message.body
    content.sound = .default
    content.categoryIdentifier = DJIONotificationCategory.message
    content.threadIdentifier = "sms:\(message.sender)"
    content.userInfo = ["kind": "message", "messageID": message.id]
    try? await UNUserNotificationCenter.current().add(
      UNNotificationRequest(identifier: "sms:\(message.id)", content: content, trigger: nil)
    )
  }

  func refreshLaunchAtLoginStatus() {
    switch SMAppService.mainApp.status {
    case .enabled:
      launchAtLogin = true
      launchAtLoginStatusMessage = nil
    case .requiresApproval:
      launchAtLogin = true
      launchAtLoginStatusMessage = "需要在系统设置的“登录项与扩展”中允许 DJIO。"
    case .notFound:
      launchAtLogin = false
      launchAtLoginStatusMessage = "请先将 DJIO 移到“应用程序”文件夹，再启用登录启动。"
    case .notRegistered:
      launchAtLogin = false
      launchAtLoginStatusMessage = nil
    @unknown default:
      launchAtLogin = false
      launchAtLoginStatusMessage = "无法读取登录项状态。"
    }
  }

  private func schedulePendingForegroundRefreshIfPossible() {
    guard pendingForegroundRefresh, !refreshInProgress, !isSwitchingMode else { return }
    pendingForegroundRefresh = false
    Task { [weak self] in
      await self?.refresh()
    }
  }

  private func startTrafficMonitoring() {
    guard !isDemoMode, trafficTask == nil else { return }
    trafficTask = Task { [weak self] in
      while !Task.isCancelled {
        do {
          guard let model = self else { return }
          model.updateTraffic()
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
      }
    }
  }

  private var canStartQueuedMessages: Bool {
    connection.control == .ready && connection.cellular == .ready && !isSwitchingMode
  }

  private func synchronizeTrafficInterface() {
    let interfaceName =
      network.selectedInterface?.isLinkUp == true ? network.selectedInterface?.name : nil
    guard traffic.interfaceName != interfaceName else { return }
    trafficSampler.reset()
    updateTraffic()
  }

  private func updateTraffic() {
    let interfaceName =
      network.selectedInterface?.isLinkUp == true ? network.selectedInterface?.name : nil
    let counters = interfaceName.flatMap(networkInspector.trafficCounters(for:))
    traffic = trafficSampler.sample(interfaceName: interfaceName, counters: counters)
    trafficUsage = trafficUsageTracker.sample(interfaceName: interfaceName, counters: counters)
    trafficPersistenceIssue = trafficUsageTracker.persistenceIssue
  }

  private func networkStatusIssue() -> String? {
    let activeExternal = network.interfaces.filter {
      ($0.isActive || $0.isLinkUp) && $0.name != "en0"
    }
    guard let selected = network.selectedInterface else {
      return activeExternal.isEmpty ? nil : "无法确认 ECM 网卡，请在设置中选择模块对应的以太网接口"
    }
    guard selected.isLinkUp else {
      return "ECM 网卡 \(selected.name) 当前未连接；若模块刚重启，请拔下 USB 后重新插入"
    }
    guard selected.isActive else {
      let address = selected.address.map { "，当前地址为 \($0)" } ?? ""
      if selected.address?.hasPrefix("169.254.") == true {
        let fallbackAddress = selected.address ?? "169.254 地址"
        return "模块没有回应 DHCP；macOS 为 ECM 网卡 \(selected.name) 临时分配了 \(fallbackAddress)"
      }
      return "ECM 网卡 \(selected.name) 已连接，但尚未获得可用 IP 地址\(address)"
    }
    if let primary = network.primaryInterface, primary != selected.name,
      !NetworkInspector.isVirtualTunnel(primary)
    {
      return "ECM 网卡已连接，但当前默认路由是 \(primary)"
    }
    return nil
  }

  private func installDemoState() {
    selection = .messages
    connection = ConnectionSnapshot(
      device: .ready,
      control: .ready,
      ecm: .ready,
      cellular: .ready,
      usbDeviceIdentifier: .quectelEC25,
      usbNetworkMode: 1,
      transportDescription: "USB AT · 2C7C:0125 · 接口 2 · 0x03/0x84",
      networkInterface: "en6",
      networkAddress: "192.168.225.22",
      primaryInterface: "en6",
      operatorName: "中国移动",
      registration: "已注册",
      signalRSSI: -73,
      cellularDetails: CellularDetails(
        simStatus: "就绪",
        firmwareRevision: "EG25GGBR07A08M2G",
        accessTechnology: "FDD LTE",
        frequencyBand: "LTE BAND 3",
        channel: 1_300,
        signalRSRP: -94,
        signalRSRQ: -10,
        signalSINR: 11,
        smsStorageUsage: [
          SMSStorageUsage(storage: "SM", used: 3, total: 50),
          SMSStorageUsage(storage: "ME", used: 7, total: 255),
        ]
      ),
      lastUpdated: Date(),
      issue: nil
    )
    network = NetworkSnapshot(
      interfaces: [
        NetworkInterfaceSnapshot(
          name: "en6", displayName: "DJI 4G ECM", address: "192.168.225.22", isLinkUp: true,
          isActive: true, isPrimary: true),
        NetworkInterfaceSnapshot(
          name: "en7", displayName: "USB 千兆网卡", address: nil, isLinkUp: false,
          isActive: false, isPrimary: false),
      ],
      selectedInterface: NetworkInterfaceSnapshot(
        name: "en6", displayName: "DJI 4G ECM", address: "192.168.225.22", isLinkUp: true,
        isActive: true, isPrimary: true),
      primaryInterface: "en6"
    )
    traffic = NetworkTrafficSnapshot(
      interfaceName: "en6",
      downloadBytesPerSecond: 1_840_000,
      uploadBytesPerSecond: 226_000,
      receivedBytes: 1_860_000_000,
      sentBytes: 284_000_000
    )
    let now = Date()
    trafficUsage = TrafficUsageSnapshot(
      session: TrafficUsageTotals(receivedBytes: 842_000_000, sentBytes: 96_000_000),
      today: TrafficUsageTotals(receivedBytes: 2_740_000_000, sentBytes: 318_000_000),
      month: TrafficUsageTotals(receivedBytes: 38_600_000_000, sentBytes: 4_820_000_000),
      dayStartedAt: Calendar.current.startOfDay(for: now),
      monthStartedAt: Calendar.current.date(
        from: Calendar.current.dateComponents([.year, .month], from: now)) ?? now
    )
    messages = [
      SMSMessage(
        id: "demo-1", sender: "10086", body: "本月套餐剩余流量 18.6 GB。",
        receivedAt: now.addingTimeInterval(-180), serviceCenterAt: now.addingTimeInterval(-184),
        usesMacTimestamp: true, storage: "ME", modemIndex: 7, rawPDU: "",
        isRead: false),
      SMSMessage(
        id: "demo-2", sender: "+8613800138000", body: "您的登录验证码是 482731，5 分钟内有效。",
        receivedAt: now.addingTimeInterval(-3_900),
        serviceCenterAt: now.addingTimeInterval(-3_906), usesMacTimestamp: true, storage: "SM",
        modemIndex: 2, rawPDU: "",
        isRead: true),
      SMSMessage(
        id: "demo-3", sender: "10690000", body: "设备已成功接入移动网络。",
        receivedAt: now.addingTimeInterval(-86_400),
        serviceCenterAt: now.addingTimeInterval(-86_403), usesMacTimestamp: true, storage: "ME",
        modemIndex: 4, rawPDU: "",
        isRead: true),
    ]
    incomingCalls = [
      IncomingCallRecord(
        id: "demo-call-1",
        callerNumber: "+8613800138000",
        receivedAt: now.addingTimeInterval(-720)
      ),
      IncomingCallRecord(
        id: "demo-call-2",
        callerNumber: nil,
        receivedAt: now.addingTimeInterval(-7_200)
      ),
    ]
    let sentAt = now.addingTimeInterval(-3_540)
    outbox = [
      OutgoingSMS(
        id: "demo-outgoing-1",
        recipient: "+8613800138000",
        body: "收到，谢谢。",
        concatenationReference: nil,
        state: .sent,
        createdAt: sentAt,
        updatedAt: sentAt,
        sentAt: sentAt,
        attemptCount: 1,
        lastError: nil,
        parts: [
          OutgoingSMSPart(
            index: 0,
            pdu: "",
            tpduLength: 1,
            state: .sent,
            attemptCount: 1,
            modemReference: 42,
            lastError: nil,
            updatedAt: sentAt
          )
        ]
      )
    ]
    selectedMessageID = "demo-2"
  }
}

extension String {
  fileprivate var nilIfEmpty: String? {
    let value = trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }
}
