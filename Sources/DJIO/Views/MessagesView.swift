import AppKit
import SwiftUI

struct MessagesView: View {
  @EnvironmentObject private var model: AppModel
  @State private var selectedConversationID: String?
  @State private var query = ""
  @State private var drafts: [String: String] = [:]
  @State private var showingComposer = false
  @State private var columnVisibility: NavigationSplitViewVisibility = .all
  @State private var preferredCompactColumn: NavigationSplitViewColumn = .content
  @State private var incomingDeleteCandidate: SMSMessage?
  @State private var outgoingDeleteCandidate: OutgoingSMS?
  @State private var outcomeUnknownRetryCandidate: OutgoingSMS?

  private var conversations: [SMSConversation] {
    SMSConversationBuilder.conversations(incoming: model.messages, outgoing: model.outbox)
  }

  private var filteredConversations: [SMSConversation] {
    guard !query.isEmpty else { return conversations }
    return conversations.filter { conversation in
      conversation.displayAddress.localizedCaseInsensitiveContains(query)
        || SMSAddressDisplayFormatter.string(for: conversation.displayAddress)
          .localizedCaseInsensitiveContains(query)
        || conversation.entries.contains {
          $0.body.localizedCaseInsensitiveContains(query)
        }
    }
  }

  private var selectedConversation: SMSConversation? {
    conversations.first { $0.id == selectedConversationID }
  }

  var body: some View {
    NavigationSplitView(
      columnVisibility: $columnVisibility,
      preferredCompactColumn: $preferredCompactColumn
    ) {
      AppSidebar()
    } content: {
      conversationList
        .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 360)
    } detail: {
      conversationDetailColumn
        .navigationSplitViewColumnWidth(min: 320, ideal: 520)
    }
    .navigationSplitViewStyle(.balanced)
    .onAppear {
      synchronizeSelectionUnlessNavigationIsPending()
    }
    .onChange(of: conversations.map(\.id)) { _, _ in
      synchronizeSelectionUnlessNavigationIsPending()
    }
    .onChange(of: query) { _, _ in
      synchronizeFilteredSelection()
    }
    .onChange(of: model.messageNavigationRequestID) { _, requestID in
      openRequestedMessage(requestID)
    }
    .sheet(isPresented: $showingComposer) {
      ComposeMessageSheet { recipient in
        query = ""
        selectedConversationID = SMSConversationBuilder.canonicalAddress(recipient)
        preferredCompactColumn = .detail
      }
      .environmentObject(model)
    }
    .confirmationDialog(
      "删除这条本机短信？",
      isPresented: Binding(
        get: { incomingDeleteCandidate != nil },
        set: { if !$0 { incomingDeleteCandidate = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("删除", role: .destructive) {
        guard let id = incomingDeleteCandidate?.id else { return }
        incomingDeleteCandidate = nil
        Task { await model.deleteMessage(id: id) }
      }
      Button("取消", role: .cancel) {
        incomingDeleteCandidate = nil
      }
    } message: {
      Text("只删除这台 Mac 上的记录，不会额外操作模块存储。")
    }
    .confirmationDialog(
      "删除这条发送记录？",
      isPresented: Binding(
        get: { outgoingDeleteCandidate != nil },
        set: { if !$0 { outgoingDeleteCandidate = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("删除", role: .destructive) {
        guard let id = outgoingDeleteCandidate?.id else { return }
        outgoingDeleteCandidate = nil
        Task { await model.deleteOutgoingMessage(id: id) }
      }
      .disabled(model.isSendingMessage)
      Button("取消", role: .cancel) {
        outgoingDeleteCandidate = nil
      }
    } message: {
      Text("只删除本机记录，已经发出的短信无法撤回。")
    }
    .confirmationDialog(
      "这条短信可能已经发出",
      isPresented: Binding(
        get: { outcomeUnknownRetryCandidate != nil },
        set: { if !$0 { outcomeUnknownRetryCandidate = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("仍要重试", role: .destructive) {
        guard let id = outcomeUnknownRetryCandidate?.id else { return }
        outcomeUnknownRetryCandidate = nil
        Task { await model.retryOutgoingMessage(id: id) }
      }
      .disabled(model.isSendingMessage)
      Button("取消", role: .cancel) {
        outcomeUnknownRetryCandidate = nil
      }
    } message: {
      Text("模块在提交后没有返回最终结果。重试可能会让收件人收到重复短信。")
    }
  }

  private var conversationDetailColumn: some View {
    let readRequest = conversationReadRequest

    return Group {
      if let selectedConversation {
        ConversationDetail(
          conversation: selectedConversation,
          draft: draftBinding(for: selectedConversation.id),
          isSending: model.isSendingMessage,
          activeOutgoingMessageID: model.sendingOutgoingMessageID,
          send: sendReply,
          retry: requestRetry,
          deleteIncoming: { incomingDeleteCandidate = $0 },
          deleteOutgoing: { outgoingDeleteCandidate = $0 }
        )
      } else {
        ContentUnavailableView("选择一条会话", systemImage: "message")
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .navigationTitle("短信")
    .toolbar {
      RefreshToolbarActions(
        isRefreshing: model.isRefreshing,
        refreshHelp: "检查新短信",
        refresh: {
          Task {
            await model.refresh()
            await model.refreshOutbox()
          }
        },
        secondarySystemImage: "square.and.pencil",
        secondaryHelp: "写新短信",
        isSecondaryDisabled: false,
        secondaryAction: {
          model.clearOutgoingMessageIssue()
          showingComposer = true
        }
      )
    }
    .safeAreaInset(edge: .top, spacing: 0) {
      if let issue = model.outgoingMessageIssue {
        OutboxIssueBanner(issue: issue) {
          model.clearOutgoingMessageIssue()
        }
      }
    }
    .task(id: readRequest) {
      await handleConversationReadRequest(readRequest)
    }
  }

  private var conversationList: some View {
    VStack(spacing: 0) {
      NativeSearchField(text: $query, prompt: "搜索")
        .controlSize(.extraLarge)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)

      if conversations.isEmpty {
        ContentUnavailableView {
          Label("暂无会话", systemImage: "message")
        } description: {
          Text("收到或发出的短信会按号码显示在这里。")
        } actions: {
          Button("新短信") {
            model.clearOutgoingMessageIssue()
            showingComposer = true
          }
        }
      } else if filteredConversations.isEmpty {
        ContentUnavailableView(
          "没有匹配的会话",
          systemImage: "magnifyingglass",
          description: Text("尝试其他号码或短信内容。")
        )
      } else {
        List(selection: conversationSelection) {
          ForEach(Array(filteredConversations.enumerated()), id: \.element.id) {
            index, conversation in
            ConversationRow(
              conversation: conversation,
              isSelected: conversation.id == selectedConversationID,
              showsSeparator: showsConversationSeparator(after: index)
            )
            .tag(conversation.id)
            .listRowInsets(conversationRowInsets)
            .listRowSeparator(.hidden)
          }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var conversationRowInsets: EdgeInsets {
    EdgeInsets(top: 0, leading: 13, bottom: 0, trailing: 5)
  }

  private func showsConversationSeparator(after index: Int) -> Bool {
    guard filteredConversations.indices.contains(index + 1) else { return false }
    guard let selectedConversationID else { return true }
    return filteredConversations[index].id != selectedConversationID
      && filteredConversations[index + 1].id != selectedConversationID
  }

  private func synchronizeSelection() {
    if let selectedConversationID,
      conversations.contains(where: { $0.id == selectedConversationID })
    {
      return
    }
    if let selectedMessageID = model.selectedMessageID,
      let conversation = conversations.first(where: {
        $0.incomingMessageIDs.contains(selectedMessageID)
      })
    {
      selectedConversationID = conversation.id
    } else {
      selectedConversationID = conversations.first?.id
    }
  }

  private func synchronizeFilteredSelection() {
    guard !query.isEmpty else {
      synchronizeSelection()
      return
    }
    if let selectedConversationID,
      filteredConversations.contains(where: { $0.id == selectedConversationID })
    {
      return
    }
    selectedConversationID = nil
  }

  private var conversationReadRequest: ConversationReadRequest {
    ConversationReadRequest(
      conversationID: selectedConversation?.id,
      messageIDs: selectedConversation?.incomingMessageIDs ?? [],
      isEnabled: model.messageNavigationRequestID == nil
    )
  }

  private func handleConversationReadRequest(_ request: ConversationReadRequest) async {
    guard request.isEnabled, request.conversationID != nil else { return }

    await Task.yield()
    guard !Task.isCancelled,
      request == conversationReadRequest
    else { return }

    model.selectConversation(messageIDs: request.messageIDs)
  }

  private func openRequestedMessage(_ requestID: String?) {
    guard let requestID,
      let conversation = conversations.first(where: {
        $0.incomingMessageIDs.contains(requestID)
      })
    else { return }
    query = ""
    selectedConversationID = conversation.id
    preferredCompactColumn = .detail
    model.consumeMessageNavigationRequest(requestID)
  }

  private func synchronizeSelectionUnlessNavigationIsPending() {
    let requestID = model.messageNavigationRequestID
    openRequestedMessage(requestID)
    if requestID == nil {
      synchronizeSelection()
    }
  }

  private var conversationSelection: Binding<String?> {
    Binding(
      get: { selectedConversationID },
      set: { conversationID in
        selectedConversationID = conversationID
        if conversationID != nil {
          preferredCompactColumn = .detail
        }
      }
    )
  }

  private func draftBinding(for conversationID: String) -> Binding<String> {
    Binding(
      get: { drafts[conversationID, default: ""] },
      set: { drafts[conversationID] = $0 }
    )
  }

  private func sendReply(to recipient: String, body: String) {
    let conversationID = SMSConversationBuilder.canonicalAddress(recipient)
    Task {
      if await model.sendMessage(recipient: recipient, body: body) {
        if drafts[conversationID, default: ""] == body {
          drafts[conversationID] = ""
        }
        selectedConversationID = conversationID
      }
    }
  }

  private func requestRetry(_ message: OutgoingSMS) {
    if message.state == .outcomeUnknown {
      outcomeUnknownRetryCandidate = message
    } else {
      Task { await model.retryOutgoingMessage(id: message.id) }
    }
  }
}

private struct ConversationReadRequest: Equatable {
  let conversationID: String?
  let messageIDs: [String]
  let isEnabled: Bool
}

private struct ConversationRow: View {
  @Environment(\.controlActiveState) private var controlActiveState

  let conversation: SMSConversation
  let isSelected: Bool
  let showsSeparator: Bool

  private var latestEntry: SMSConversationEntry? { conversation.latestEntry }
  private var displayAddress: String {
    SMSAddressDisplayFormatter.string(for: conversation.displayAddress)
  }

  var body: some View {
    ZStack(alignment: .bottom) {
      // Extend past List's content inset to match Messages' selection margins.
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .fill(isSelected ? selectedBackgroundColor : .clear)
        .padding(.leading, -19)
        .padding(.trailing, -12)
        .transaction { transaction in
          transaction.animation = nil
        }

      HStack(alignment: .center, spacing: 6) {
        ConversationAvatar(address: conversation.displayAddress, size: 40)

        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 8) {
            Text(displayAddress)
              .font(.body.weight(.semibold))
              .lineLimit(1)
            Spacer(minLength: 6)
            if let latestEntry {
              Text(MessageTimestampFormatter.string(for: latestEntry.timestamp))
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            }
          }

          if let latestEntry {
            Text(latestEntry.isIncoming ? latestEntry.body : "你：\(latestEntry.body)")
              .font(.callout)
              .foregroundStyle(.secondary)
              .lineLimit(2)
          }
        }
      }
      .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)

      Divider()
        .padding(.leading, 46)
        .opacity(showsSeparator ? 1 : 0)
        .transaction { transaction in
          transaction.animation = nil
        }
    }
    .overlay(alignment: .leading) {
      if conversation.unreadCount > 0 {
        Circle()
          .fill(.blue)
          .frame(width: 7, height: 7)
          .offset(x: -18)
      } else if conversation.hasOutgoingIssue {
        Image(systemName: "exclamationmark.circle.fill")
          .foregroundStyle(.orange)
          .font(.caption)
          .offset(x: -20)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private var selectedBackgroundColor: Color {
    controlActiveState == .key
      ? Color(nsColor: .systemBlue)
      : Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
  }
}

private struct ConversationAvatar: View {
  let address: String
  let size: CGFloat

  private var backgroundColor: Color {
    // The default Messages avatar is intentionally quieter than system indigo.
    Color(
      nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
          ? NSColor(srgbRed: 0.32, green: 0.29, blue: 0.42, alpha: 1)
          : NSColor(srgbRed: 0.44, green: 0.42, blue: 0.58, alpha: 1)
      })
  }

  var body: some View {
    Image(systemName: "person.crop.circle.fill")
      .resizable()
      .scaledToFit()
      .symbolRenderingMode(.palette)
      .foregroundStyle(.white, backgroundColor)
      .frame(width: size, height: size)
      .accessibilityHidden(true)
  }
}

private struct ConversationDetail: View {
  let conversation: SMSConversation
  @Binding var draft: String
  let isSending: Bool
  let activeOutgoingMessageID: String?
  let send: (String, String) -> Void
  let retry: (OutgoingSMS) -> Void
  let deleteIncoming: (SMSMessage) -> Void
  let deleteOutgoing: (OutgoingSMS) -> Void

  var body: some View {
    VStack(spacing: 0) {
      ConversationHeader(conversation: conversation)
      ConversationTimeline(
        conversation: conversation,
        isSending: isSending,
        activeOutgoingMessageID: activeOutgoingMessageID,
        retry: retry,
        deleteIncoming: deleteIncoming,
        deleteOutgoing: deleteOutgoing
      )
      .id(conversation.id)
      ConversationReplyBar(
        draft: $draft,
        recipient: conversation.displayAddress,
        isSending: isSending,
        send: send
      )
    }
  }
}

private struct ConversationHeader: View {
  let conversation: SMSConversation

  var body: some View {
    VStack(spacing: 4) {
      ConversationAvatar(address: conversation.displayAddress, size: 40)
      Text(SMSAddressDisplayFormatter.string(for: conversation.displayAddress))
        .font(.callout.weight(.semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .textSelection(.enabled)
    }
    .frame(maxWidth: .infinity)
    .frame(height: 64)
  }
}

private struct ConversationTimeline: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let conversation: SMSConversation
  let isSending: Bool
  let activeOutgoingMessageID: String?
  let retry: (OutgoingSMS) -> Void
  let deleteIncoming: (SMSMessage) -> Void
  let deleteOutgoing: (OutgoingSMS) -> Void

  var body: some View {
    GeometryReader { geometry in
      let rowWidth = max(1, geometry.size.width - 32)
      let bubbleWidth = min(rowWidth, min(520, max(140, rowWidth * 0.72)))
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(spacing: 7) {
            ForEach(Array(conversation.entries.enumerated()), id: \.element.id) { index, entry in
              if index == 0 {
                VStack(spacing: 0) {
                  Text("信息 • 短信")
                  Text(ConversationDateFormatter.string(for: entry.timestamp))
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
                .padding(.bottom, 3)
              } else if showsTimestamp(before: index) {
                Text(ConversationDateFormatter.string(for: entry.timestamp))
                  .font(.caption.weight(.medium))
                  .foregroundStyle(.tertiary)
                  .padding(.top, index == 0 ? 4 : 14)
                  .padding(.bottom, 3)
              }
              switch entry.content {
              case .incoming(let message):
                IncomingConversationBubble(
                  message: message,
                  rowWidth: rowWidth,
                  maximumWidth: bubbleWidth,
                  delete: { deleteIncoming(message) }
                )
                .id(entry.id)
              case .outgoing(let message):
                OutgoingConversationBubble(
                  message: message,
                  rowWidth: rowWidth,
                  maximumWidth: bubbleWidth,
                  isBusy: isSending,
                  isActivelySending: activeOutgoingMessageID == message.id,
                  retry: { retry(message) },
                  delete: { deleteOutgoing(message) }
                )
                .id(entry.id)
              }
            }
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 12)
        }
        .onAppear { scrollToBottom(proxy, animated: false) }
        .onChange(of: conversation.entries.map(\.id)) { _, _ in
          scrollToBottom(proxy, animated: !reduceMotion)
        }
      }
    }
  }

  private func showsTimestamp(before index: Int) -> Bool {
    guard index > 0 else { return true }
    let current = conversation.entries[index].timestamp
    let previous = conversation.entries[index - 1].timestamp
    return !Calendar.current.isDate(current, inSameDayAs: previous)
      || current.timeIntervalSince(previous) >= 15 * 60
  }

  private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
    guard let id = conversation.entries.last?.id else { return }
    if animated {
      withAnimation(.easeOut(duration: 0.2)) {
        proxy.scrollTo(id, anchor: .bottom)
      }
    } else {
      proxy.scrollTo(id, anchor: .bottom)
    }
  }
}

private struct IncomingConversationBubble: View {
  let message: SMSMessage
  let rowWidth: CGFloat
  let maximumWidth: CGFloat
  let delete: () -> Void

  var body: some View {
    HStack(alignment: .bottom, spacing: 6) {
      if let code = SMSContentParser.verificationCode(in: message.body) {
        Button {
          copyToPasteboard(code)
        } label: {
          Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("复制验证码 \(code)")
        .accessibilityLabel("复制验证码")
      }

      Text(message.body)
        .font(.body)
        .lineSpacing(2)
        .textSelection(.enabled)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
          Color.primary.opacity(0.13),
          in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .help(
          "Mac 接收：\(message.receivedAt.formatted(date: .long, time: .standard))\n短信中心：\(message.serviceCenterAt.formatted(date: .long, time: .standard))"
        )
    }
    .frame(width: maximumWidth, alignment: .leading)
    .frame(width: rowWidth, alignment: .leading)
    .contextMenu {
      Button("复制") { copyToPasteboard(message.body) }
      if let code = SMSContentParser.verificationCode(in: message.body) {
        Button("复制验证码 \(code)") { copyToPasteboard(code) }
      }
      Divider()
      Button("删除", role: .destructive, action: delete)
    }
  }
}

private struct OutgoingConversationBubble: View {
  let message: OutgoingSMS
  let rowWidth: CGFloat
  let maximumWidth: CGFloat
  let isBusy: Bool
  let isActivelySending: Bool
  let retry: () -> Void
  let delete: () -> Void

  var body: some View {
    VStack(alignment: .trailing, spacing: 4) {
      Text(message.body)
        .font(.body)
        .lineSpacing(2)
        .foregroundStyle(textColor)
        .textSelection(.enabled)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(bubbleColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .help(message.sentAt?.formatted(date: .long, time: .standard) ?? message.state.title)

      OutgoingBubbleStatus(
        message: message,
        isBusy: isBusy,
        isActivelySending: isActivelySending,
        retry: retry
      )
    }
    .frame(width: maximumWidth, alignment: .trailing)
    .frame(width: rowWidth, alignment: .trailing)
    .contextMenu {
      Button("复制") { copyToPasteboard(message.body) }
      if message.state == .failed || message.state == .outcomeUnknown {
        Button(message.state == .outcomeUnknown ? "确认并重试" : "重试", action: retry)
          .disabled(isBusy)
      }
      Divider()
      Button("删除", role: .destructive, action: delete)
        .disabled(isBusy)
    }
  }

  private var bubbleColor: Color {
    switch message.state {
    case .sent: return .green
    case .queued, .sending: return .green.opacity(0.72)
    case .failed, .outcomeUnknown: return Color.primary.opacity(0.13)
    }
  }

  private var textColor: Color {
    switch message.state {
    case .queued, .sending, .sent: return .white
    case .failed, .outcomeUnknown: return .primary
    }
  }
}

private func copyToPasteboard(_ text: String) {
  NSPasteboard.general.clearContents()
  NSPasteboard.general.setString(text, forType: .string)
}

private struct OutgoingBubbleStatus: View {
  let message: OutgoingSMS
  let isBusy: Bool
  let isActivelySending: Bool
  let retry: () -> Void

  private var shownState: OutgoingSMSState {
    isActivelySending && message.state == .queued ? .sending : message.state
  }

  var body: some View {
    if shownState != .sent || message.totalPartCount > 1 {
      HStack(spacing: 6) {
        if isActivelySending {
          ProgressView()
            .controlSize(.mini)
        } else {
          Image(systemName: shownState.systemImage)
        }
        Text(shownState.title)
        if message.totalPartCount > 1 {
          Text("\(message.sentPartCount)/\(message.totalPartCount) 段")
            .monospacedDigit()
        }
        if shownState == .failed || shownState == .outcomeUnknown {
          Button(action: retry) {
            Image(systemName: "arrow.clockwise")
          }
          .buttonStyle(.plain)
          .disabled(isBusy)
          .help(shownState == .outcomeUnknown ? "确认并重试" : "重试")
          .accessibilityLabel(shownState == .outcomeUnknown ? "确认并重试" : "重试")
        }
      }
      .font(.caption)
      .foregroundStyle(shownState.color)
      .help(message.lastError ?? shownState.title)
    }
  }
}

private struct ConversationReplyBar: View {
  @Binding var draft: String
  @FocusState private var isFocused: Bool

  let recipient: String
  let isSending: Bool
  let send: (String, String) -> Void

  private var analysis: SMSCompositionAnalysis {
    SMSCompositionAnalysis(recipient: recipient, body: draft, isSending: isSending)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      if let displayedIssue = analysis.fieldIssue {
        Label(displayedIssue, systemImage: "exclamationmark.circle")
          .font(.caption)
          .foregroundStyle(.red)
          .lineLimit(2)
      }

      HStack(alignment: .bottom, spacing: 4) {
        TextField("信息 • 短信", text: $draft, axis: .vertical)
          .textFieldStyle(.plain)
          .lineLimit(1...4)
          .focused($isFocused)
          .onSubmit(submit)

        if isSending {
          ProgressView()
            .controlSize(.small)
            .frame(width: 26, height: 26)
        }
      }
      .padding(.horizontal, 11)
      .padding(.vertical, 5)
      .frame(minHeight: 31)
      .modifier(ComposerGlassBackground())
      .help(analysis.encodingDescription)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  private func submit() {
    guard analysis.canSend else { return }
    send(recipient, draft)
  }
}

private struct ComposerGlassBackground: ViewModifier {
  @ViewBuilder
  func body(content: Content) -> some View {
    if #available(macOS 26, *) {
      content
        .background(
          Color.primary.opacity(0.038),
          in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .glassEffect(
          .regular,
          in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    } else {
      content
        .background(
          .regularMaterial,
          in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(Color(nsColor: .separatorColor).opacity(0.35))
        }
    }
  }
}

private struct OutboxIssueBanner: View {
  let issue: String
  let dismiss: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
      Text(issue)
        .font(.callout)
        .lineLimit(2)
        .textSelection(.enabled)
      Spacer(minLength: 12)
      Button(action: dismiss) {
        Image(systemName: "xmark")
      }
      .buttonStyle(.plain)
      .help("关闭")
      .accessibilityLabel("关闭错误提示")
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 9)
    .background(.bar)
    .overlay(alignment: .bottom) { Divider() }
  }
}

private struct ComposeMessageSheet: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @FocusState private var focusedField: Field?
  @State private var recipient = ""
  @State private var messageBody = ""

  let messageQueued: (String) -> Void

  private enum Field {
    case recipient
    case body
  }

  private var analysis: SMSCompositionAnalysis {
    SMSCompositionAnalysis(
      recipient: recipient,
      body: messageBody,
      isSending: model.isSendingMessage
    )
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("新短信")
          .font(.headline)
        Spacer()
      }
      .padding(.horizontal, 20)
      .frame(height: 50)

      Divider()

      VStack(alignment: .leading, spacing: 16) {
        LabeledContent("收件人") {
          TextField("手机号码", text: $recipient)
            .textFieldStyle(.roundedBorder)
            .focused($focusedField, equals: .recipient)
        }

        VStack(alignment: .leading, spacing: 7) {
          Text("正文")
            .font(.callout)
          TextEditor(text: $messageBody)
            .font(.body)
            .focused($focusedField, equals: .body)
            .frame(minHeight: 150, maxHeight: 220)
            .padding(4)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay {
              RoundedRectangle(cornerRadius: 5)
                .stroke(Color(nsColor: .separatorColor))
            }
        }

        Text(analysis.encodingDescription)
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      .padding(20)

      Divider()

      HStack(spacing: 12) {
        if let displayedIssue = model.outgoingMessageIssue ?? analysis.fieldIssue {
          Label(displayedIssue, systemImage: "exclamationmark.circle")
            .font(.caption)
            .foregroundStyle(.red)
            .lineLimit(2)
        }
        Spacer(minLength: 16)
        Button("取消") {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
        Button {
          Task {
            if await model.sendMessage(recipient: recipient, body: messageBody) {
              messageQueued(recipient)
              dismiss()
            }
          }
        } label: {
          if model.isSendingMessage {
            HStack(spacing: 7) {
              ProgressView()
                .controlSize(.small)
              Text("正在加入会话")
            }
          } else {
            Text("发送")
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!analysis.canSend)
      }
      .padding(.horizontal, 20)
      .frame(minHeight: 58)
    }
    .frame(width: 500)
    .frame(minHeight: 390)
    .onAppear { focusedField = .recipient }
  }
}

private struct SMSCompositionAnalysis {
  let encodingDescription: String
  let canSend: Bool
  let fieldIssue: String?

  init(recipient: String, body: String, isSending: Bool) {
    guard !body.isEmpty else {
      encodingDescription = "0 个字符"
      canSend = false
      fieldIssue = nil
      return
    }

    let encoder = SMSPDUEncoder(concatenationReferenceProvider: { 0 })
    var issue: String?
    let encodedParts: [EncodedSMSPart]?
    if recipient.isEmpty {
      encodedParts = try? encoder.encode(recipient: "10086", body: body)
    } else {
      do {
        encodedParts = try encoder.encode(recipient: recipient, body: body)
      } catch {
        issue = error.localizedDescription
        encodedParts = try? encoder.encode(recipient: "10086", body: body)
      }
    }

    if let encodedParts, let alphabet = encodedParts.first?.alphabet {
      let encoding = alphabet == .gsm7 ? "GSM 7-bit" : "UCS-2"
      let units = encodedParts.count == 1 ? "1 条短信" : "\(encodedParts.count) 个分段"
      encodingDescription = "\(encoding) · \(units) · \(body.count) 个字符"
    } else {
      encodingDescription = "无法编码 · \(body.count) 个字符"
    }
    canSend =
      !isSending
      && !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !recipient.isEmpty && issue == nil && encodedParts != nil
    fieldIssue = issue
  }
}

extension OutgoingSMSState {
  fileprivate var title: String {
    switch self {
    case .queued: return "等待发送"
    case .sending: return "正在发送"
    case .sent: return "已发送"
    case .failed: return "发送失败"
    case .outcomeUnknown: return "结果待确认"
    }
  }

  fileprivate var systemImage: String {
    switch self {
    case .queued: return "clock"
    case .sending: return "paperplane"
    case .sent: return "checkmark.circle.fill"
    case .failed: return "xmark.circle.fill"
    case .outcomeUnknown: return "questionmark.circle.fill"
    }
  }

  fileprivate var color: Color {
    switch self {
    case .queued: return .secondary
    case .sending: return .blue
    case .sent: return .green
    case .failed: return .red
    case .outcomeUnknown: return .orange
    }
  }
}

private enum SMSContentParser {
  static func verificationCode(in body: String) -> String? {
    let pattern = "(?<![0-9])([0-9]{4,8})(?![0-9])"
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(body.startIndex..., in: body)
    guard let match = expression.firstMatch(in: body, range: range),
      let codeRange = Range(match.range(at: 1), in: body)
    else { return nil }
    return String(body[codeRange])
  }
}

private enum ConversationDateFormatter {
  static func string(
    for date: Date,
    relativeTo now: Date = Date(),
    calendar: Calendar = .current
  ) -> String {
    let time = date.formatted(
      .dateTime.locale(Locale(identifier: "zh_CN")).hour().minute())
    if calendar.isDateInToday(date) {
      return "今天 \(time)"
    }
    if calendar.isDateInYesterday(date) {
      return "昨天 \(time)"
    }
    let dateComponents = calendar.dateComponents([.year], from: date)
    let nowComponents = calendar.dateComponents([.year], from: now)
    if dateComponents.year == nowComponents.year {
      return date.formatted(
        .dateTime.locale(Locale(identifier: "zh_CN")).month().day().weekday().hour().minute())
    }
    return date.formatted(
      .dateTime.locale(Locale(identifier: "zh_CN")).year().month().day().hour().minute())
  }
}
