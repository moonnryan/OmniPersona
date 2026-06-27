@preconcurrency import AVFoundation
import AVKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct ChatView: View {
    @EnvironmentObject private var store: AppStore
    @State private var draft = ""
    @State private var pickedItems: [PhotosPickerItem] = []
    @State private var attachments: [ChatAttachment] = []
    @State private var showCamera = false
    @State private var showPhotoPicker = false
    @State private var showConversationSettings = false
    @State private var editingMessage: ChatMessage?
    @State private var showJumpToBottom = false
    @State private var scrollViewportHeight: CGFloat = 0
    @State private var scrollContentHeight: CGFloat = 0
    @State private var scrollBottomAnchorY: CGFloat = 0
    @State private var messageScrollView: UIScrollView?
    @State private var jumpToBottomTouchActive = false
    @State private var isProgrammaticJumpingToBottom = false
    @FocusState private var composerFocused: Bool

    private let bottomID = "bottom"

    var body: some View {
        ZStack {
            PersonaBackground(profile: conversationProfile)
            messages
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button {
                    showConversationSettings = true
                } label: {
                    HeaderIdentity(
                        profile: conversationProfile,
                        status: headerStatus,
                        usesMediaBackground: hasMediaBackground
                    )
                }
                .buttonStyle(.plain)
            }

            ToolbarItemGroup(placement: .topBarTrailing) {
                modelMenu
                ttsToggle
            }
        }
        .safeAreaInset(edge: .bottom) {
            liquidComposer
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraCaptureView { image in
                importCameraImage(image)
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showConversationSettings) {
            ConversationSettingsView()
                .environmentObject(store)
        }
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $pickedItems,
            maxSelectionCount: 4,
            matching: .any(of: [.images, .videos])
        )
        .onChange(of: composerFocused) {
            if !composerFocused {
                cancelEditingIfUnchanged()
            }
        }
    }

    private var conversationProfile: CharacterProfile {
        store.selectedConversationProfile
    }

    private var latestUserMessageID: UUID? {
        store.selectedConversation?.messages.last(where: { $0.role == .user })?.id
    }

    private var headerStatus: String {
        if !store.statusText.isEmpty { return store.statusText }
        switch store.settings.endpoints.backend {
        case .localLlama:
            return store.localModelDisplayStatus
        case .openAICompatible, .remoteOpenAI, .lanOpenAI:
            return store.selectedOpenAIModel?.displayTitle ?? "未配置 OpenAI 模型"
        }
    }

    private var hasMediaBackground: Bool {
        mediaExists(at: conversationProfile.backgroundImagePath) || mediaExists(at: conversationProfile.backgroundVideoPath)
    }

    private func mediaExists(at path: String?) -> Bool {
        guard let path, !path.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    private var modelMenu: some View {
        Menu {
            switch store.settings.endpoints.backend {
            case .localLlama:
                if store.settings.localModels.isEmpty {
                    Text("暂无已下载模型")
                } else {
                    ForEach(store.settings.localModels) { model in
                        Button {
                            withAnimation(.snappy(duration: 0.16)) {
                                store.toggleLocalModelLoaded(model)
                            }
                        } label: {
                            Label(model.repoID, systemImage: localModelIcon(model))
                        }
                        .disabled(!model.hasTextModel)
                    }
                }
            case .openAICompatible, .remoteOpenAI, .lanOpenAI:
                if store.settings.endpoints.openAIModels.isEmpty {
                    Text("暂无接口模型")
                } else {
                    ForEach(store.settings.endpoints.openAIModels) { model in
                        Button {
                            withAnimation(.snappy(duration: 0.16)) {
                                store.selectOpenAIModel(model.id)
                            }
                        } label: {
                            Label(model.displayTitle, systemImage: openAIModelIcon(model))
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "cpu")
                .frame(width: 30, height: 30)
        }
    }

    private func localModelIcon(_ model: LocalModel) -> String {
        if store.loadingLocalModelID == model.id {
            return "clock"
        }
        if store.loadedLocalModelID == model.id {
            return "checkmark.circle.fill"
        }
        return "circle"
    }

    private func openAIModelIcon(_ model: OpenAIModelConfig) -> String {
        store.settings.endpoints.selectedOpenAIModelID == model.id ? "checkmark.circle.fill" : "circle"
    }

    @ViewBuilder
    private var ttsToggle: some View {
        let isActive = store.isTTSEnabled && store.settings.tts.engine != .off
        Button {
            if store.isTTSEnabled {
                store.isTTSEnabled = false
                store.stopTTS()
            } else {
                store.isTTSEnabled = true
            }
        } label: {
            Image(systemName: isActive ? "speaker.wave.2.fill" : "speaker.slash")
                .frame(width: 30, height: 30)
                .foregroundStyle(isActive ? Color.accentColor : Color.primary)
        }
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    VStack(spacing: 12) {
                        let messages = store.selectedConversation?.messages ?? []
                        if messages.isEmpty {
                            EmptyChatState()
                        } else {
                            ForEach(messages) { message in
                                if !isHiddenDuringEditing(message, in: messages) {
                                    MessageBubble(
                                        message: message,
                                        canEdit: message.role == .user && message.id == latestUserMessageID,
                                        isEditing: message.id == editingMessage?.id,
                                        isStreaming: isStreamingAssistant(message, in: messages),
                                        edit: { beginEditing(message) },
                                        delete: { store.deleteMessage(message) }
                                    )
                                    .id(message.id)
                                    .transition(.opacity)
                                }
                            }
                        }
                        Color.clear
                            .frame(height: 104)
                            .id(bottomID)
                            .background(
                                GeometryReader { geometry in
                                    Color.clear.preference(
                                        key: ScrollBottomAnchorPreferenceKey.self,
                                        value: geometry.frame(in: .named("messages")).maxY
                                    )
                                }
                            )
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .background(
                        GeometryReader { geometry in
                            Color.clear
                                .preference(key: ScrollContentHeightPreferenceKey.self, value: geometry.size.height)
                        }
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .coordinateSpace(name: "messages")
                .background(
                    GeometryReader { geometry in
                        Color.clear.preference(key: ScrollViewportHeightPreferenceKey.self, value: geometry.size.height)
                    }
                )
                .background(
                    ScrollViewResolver { scrollView in
                        messageScrollView = scrollView
                        updateJumpToBottomVisibility(from: scrollView)
                    }
                )
                .scrollDismissesKeyboard(.interactively)
                .onTapGesture {
                    composerFocused = false
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
                .onPreferenceChange(ScrollViewportHeightPreferenceKey.self) { value in
                    scrollViewportHeight = value
                    updateJumpToBottomVisibility()
                }
                .onPreferenceChange(ScrollContentHeightPreferenceKey.self) { value in
                    scrollContentHeight = value
                    updateJumpToBottomVisibility()
                }
                .onPreferenceChange(ScrollBottomAnchorPreferenceKey.self) { value in
                    scrollBottomAnchorY = value
                    updateJumpToBottomVisibility()
                }
                .onChange(of: store.selectedConversation?.messages.last?.text) {
                    if !showJumpToBottom {
                        scrollToBottom(proxy)
                    }
                }
                .onChange(of: editingMessage?.id) {
                    guard let id = editingMessage?.id else { return }
                    withAnimation(.snappy(duration: 0.18)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }

                if showJumpToBottom {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 16, weight: .bold))
                        .frame(width: 38, height: 38)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().stroke(.white.opacity(0.22), lineWidth: 1))
                        .contentShape(Circle())
                        .highPriorityGesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { _ in
                                    guard !jumpToBottomTouchActive else { return }
                                    jumpToBottomTouchActive = true
                                    scrollToBottom(proxy)
                                }
                                .onEnded { _ in
                                    jumpToBottomTouchActive = false
                                }
                        )
                    .padding(.trailing, 18)
                    .padding(.bottom, 116)
                    .zIndex(20)
                    .transition(.scale.combined(with: .opacity))
                }
            }
        }
    }

    private var liquidComposer: some View {
        VStack(spacing: 8) {
            if editingMessage != nil {
                HStack {
                    Text("正在编辑上一条用户消息")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("取消") { cancelEditing() }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .padding(.horizontal, 18)
            }

            if !attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(attachments) { item in
                            AttachmentPreview(attachment: item) {
                                removeAttachment(item)
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                }
                .scrollIndicators(.hidden)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            HStack(alignment: .center, spacing: 8) {
                attachmentMenu

                TextField("输入消息", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($composerFocused)
                    .frame(minHeight: 40, alignment: .center)
                    .padding(.vertical, 6)

                Button {
                    sendDraft()
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .background(canSend && !store.isGenerating ? Color.accentColor : Color(uiColor: .tertiarySystemFill), in: Circle())
                        .foregroundStyle(canSend && !store.isGenerating ? .white : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(store.isGenerating || !canSend)
            }
            .padding(.leading, 8)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .stroke(.white.opacity(0.18), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.08), radius: 18, y: 8)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .animation(.snappy(duration: 0.16), value: attachments)
        .animation(.snappy(duration: 0.16), value: editingMessage?.id)
    }

    private var attachmentMenu: some View {
        Menu {
            Button {
                showPhotoPicker = true
            } label: {
                Label("从相册选择", systemImage: "photo.on.rectangle")
            }
            Button {
                showCamera = true
            } label: {
                Label("拍照", systemImage: "camera")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 19, weight: .semibold))
                .frame(width: 40, height: 40)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onChange(of: pickedItems) {
            Task { await importPickedItems() }
        }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        isProgrammaticJumpingToBottom = true
        scrollBottomAnchorY = scrollViewportHeight
        withAnimation(.snappy(duration: 0.12)) {
            showJumpToBottom = false
        }

        let didStartUIKitScroll = scrollToBottomWithUIKit()
        if !didStartUIKitScroll {
            withAnimation(.snappy(duration: 0.18)) {
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            scrollBottomAnchorY = scrollViewportHeight
            isProgrammaticJumpingToBottom = false
            showJumpToBottom = false
        }
    }

    @discardableResult
    private func scrollToBottomWithUIKit() -> Bool {
        guard let scrollView = messageScrollView else { return false }
        guard scrollView.contentSize.height > scrollView.bounds.height + 1 else { return false }
        scrollView.isScrollEnabled = false
        scrollView.panGestureRecognizer.isEnabled = false
        scrollView.panGestureRecognizer.isEnabled = true
        scrollView.layer.removeAllAnimations()
        scrollView.setContentOffset(scrollView.contentOffset, animated: false)

        let bottomY = max(
            -scrollView.adjustedContentInset.top,
            scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
        )
        let target = CGPoint(x: scrollView.contentOffset.x, y: bottomY)
        scrollView.setContentOffset(target, animated: false)
        scrollView.isScrollEnabled = true
        scrollBottomAnchorY = scrollViewportHeight
        showJumpToBottom = false
        return true
    }

    private func updateJumpToBottomVisibility(from scrollView: UIScrollView) {
        guard !isProgrammaticJumpingToBottom else {
            showJumpToBottom = false
            return
        }
        let messageCount = store.selectedConversation?.messages.count ?? 0
        let maxOffsetY = max(
            -scrollView.adjustedContentInset.top,
            scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
        )
        let distanceFromBottom = max(0, maxOffsetY - scrollView.contentOffset.y)
        let hasScrollableContent = scrollView.contentSize.height > scrollView.bounds.height + 8 || messageCount > 4
        let shouldShow = messageCount > 0 && hasScrollableContent && distanceFromBottom > 12
        guard showJumpToBottom != shouldShow else { return }
        withAnimation(.snappy(duration: 0.14)) {
            showJumpToBottom = shouldShow
        }
    }

    private func updateJumpToBottomVisibility() {
        if let messageScrollView {
            updateJumpToBottomVisibility(from: messageScrollView)
            return
        }
        guard !isProgrammaticJumpingToBottom else {
            showJumpToBottom = false
            return
        }
        let messageCount = store.selectedConversation?.messages.count ?? 0
        let viewport = max(scrollViewportHeight, 0)
        let content = max(scrollContentHeight, 0)
        let hasScrollableContent = content > viewport + 8 || messageCount > 4
        let distanceFromBottom = max(0, scrollBottomAnchorY - viewport)
        let shouldShow = messageCount > 0 && hasScrollableContent && distanceFromBottom > 8
        guard showJumpToBottom != shouldShow else { return }
        withAnimation(.snappy(duration: 0.14)) {
            showJumpToBottom = shouldShow
        }
    }

    private func sendDraft() {
        let text = draft
        let sendingAttachments = attachments
        let messageToEdit = editingMessage
        draft = ""
        attachments = []
        pickedItems = []
        editingMessage = nil
        composerFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)

        Task {
            if let messageToEdit {
                await store.resendEditedUserMessage(messageID: messageToEdit.id, text: text, attachments: sendingAttachments)
            } else {
                await store.send(text: text, attachments: sendingAttachments)
            }
        }
    }

    private func beginEditing(_ message: ChatMessage) {
        guard message.role == .user, message.id == latestUserMessageID else { return }
        editingMessage = message
        draft = message.text
        attachments = message.attachments
        composerFocused = true
    }

    private func isHiddenDuringEditing(_ message: ChatMessage, in messages: [ChatMessage]) -> Bool {
        guard let editingMessage,
              let editingIndex = messages.firstIndex(where: { $0.id == editingMessage.id }),
              message.role == .assistant
        else {
            return false
        }
        let nextIndex = messages.index(after: editingIndex)
        return nextIndex < messages.endIndex && messages[nextIndex].id == message.id
    }

    private func isStreamingAssistant(_ message: ChatMessage, in messages: [ChatMessage]) -> Bool {
        store.isGenerating && message.role == .assistant && messages.last?.id == message.id
    }

    private func cancelEditingIfUnchanged() {
        guard let editingMessage else { return }
        if draft == editingMessage.text && attachments == editingMessage.attachments {
            cancelEditing()
        }
    }

    private func cancelEditing() {
        editingMessage = nil
        draft = ""
        attachments = []
        pickedItems = []
        composerFocused = false
    }

    private func importPickedItems() async {
        var imported: [ChatAttachment] = []
        for item in pickedItems {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let kind: AttachmentKind = item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) ? .video : .image
            let ext = kind == .video ? "mov" : "jpg"
            let mime = kind == .video ? "video/quicktime" : "image/jpeg"
            let name = "\(UUID().uuidString).\(ext)"
            let url = Persistence.directory().appendingPathComponent(name)
            do {
                try data.write(to: url, options: [.atomic])
                imported.append(ChatAttachment(kind: kind, fileName: name, localPath: url.path, mimeType: mime))
            } catch {
                continue
            }
        }
        attachments.append(contentsOf: imported)
    }

    private func importCameraImage(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.88) else { return }
        let name = "\(UUID().uuidString).jpg"
        let url = Persistence.directory().appendingPathComponent(name)
        do {
            try data.write(to: url, options: [.atomic])
            attachments.append(ChatAttachment(kind: .image, fileName: name, localPath: url.path, mimeType: "image/jpeg"))
        } catch {
            return
        }
    }

    private func removeAttachment(_ attachment: ChatAttachment) {
        attachments.removeAll { $0.id == attachment.id }
        try? FileManager.default.removeItem(atPath: attachment.localPath)
    }
}

private struct AttachmentPreview: View {
    let attachment: ChatAttachment
    let remove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            thumbnail
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(.white.opacity(0.28), lineWidth: 1)
                )

            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(.black.opacity(0.58), in: Circle())
            }
            .buttonStyle(.plain)
            .offset(x: 7, y: -7)
        }
        .padding(.top, 7)
        .padding(.trailing, 7)
        .accessibilityLabel("附件 \(attachment.fileName)")
    }

    @ViewBuilder
    private var thumbnail: some View {
        if attachment.kind == .image,
           let image = UIImage(contentsOfFile: attachment.localPath) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                Rectangle()
                    .fill(.regularMaterial)
                Image(systemName: attachment.kind == .video ? "video.fill" : "doc.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ScrollViewResolver: UIViewRepresentable {
    let onResolve: (UIScrollView) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        DispatchQueue.main.async {
            if let scrollView = view.enclosingVerticalScrollView {
                onResolve(scrollView)
            }
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            if let scrollView = uiView.enclosingVerticalScrollView {
                onResolve(scrollView)
            }
        }
    }
}

private extension UIView {
    var enclosingVerticalScrollView: UIScrollView? {
        let scrollViews = sequence(first: superview, next: { $0?.superview })
            .compactMap { $0 as? UIScrollView }
        return scrollViews.first {
            $0.alwaysBounceVertical || $0.contentSize.height >= $0.bounds.height
        } ?? scrollViews.first
    }
}

private extension View {
    @ViewBuilder
    func liquidGlassCapsule(cornerRadius: CGFloat) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(0.10))
                    .blendMode(.plusLighter)
            }
        }
    }

    @ViewBuilder
    func liquidGlassCircle() -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: .circle)
        } else {
            background(.ultraThinMaterial, in: Circle())
        }
    }
}

private struct HeaderIdentity: View {
    let profile: CharacterProfile
    let status: String
    let usesMediaBackground: Bool

    var body: some View {
        HStack(spacing: 8) {
            AvatarView(path: profile.botAvatarPath, fallback: profile.name)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 0) {
                Text(profile.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(usesMediaBackground ? .white : .primary)
                    .lineLimit(1)
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(usesMediaBackground ? .white.opacity(0.9) : .secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: 220, alignment: .leading)
        .shadow(color: usesMediaBackground ? .black.opacity(0.45) : .clear, radius: 5, y: 1)
    }
}

private struct MessageBubble: View {
    let message: ChatMessage
    let canEdit: Bool
    let isEditing: Bool
    let isStreaming: Bool
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 54) }

            if canEdit {
                bubble
                    .contextMenu {
                        Button {
                            edit()
                        } label: {
                            Label("编辑并重发", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            delete()
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
            } else {
                bubble
            }

            if message.role != .user { Spacer(minLength: 54) }
        }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !message.attachments.isEmpty {
                attachmentStrip
            }

            if !message.text.isEmpty || message.attachments.isEmpty {
                MarkdownMessageText(text: message.text.isEmpty ? "..." : message.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .markdownEnabled(!isStreaming)
                    .multilineTextAlignment(.leading)
                    .frame(width: bubbleContentWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(width: bubbleContentWidth + 24, alignment: .leading)
        .foregroundStyle(.primary)
        .background(
            bubbleFill,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(0.05), radius: 10, y: 4)
        .opacity(isEditing ? 0.42 : 1)
    }

    private var attachmentStripWidth: CGFloat {
        let thumbnailWidth: CGFloat = 118
        let spacing: CGFloat = 8
        let count = CGFloat(message.attachments.count)
        return count * thumbnailWidth + max(0, count - 1) * spacing
    }

    private var bubbleContentWidth: CGFloat {
        let maxWidth: CGFloat = 292
        let thumbnailBound = min(attachmentStripWidth, maxWidth)
        let text = message.text.isEmpty && message.attachments.isEmpty ? "..." : message.text
        let minTextWidth: CGFloat = message.role == .assistant ? 128 : 48
        let textWidth = estimatedTextWidth(text, minWidth: minTextWidth, maxWidth: maxWidth, role: message.role)

        guard !message.attachments.isEmpty else {
            return textWidth
        }
        guard !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return max(72, thumbnailBound)
        }
        return max(textWidth, thumbnailBound)
    }

    private var attachmentStrip: some View {
        return ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(message.attachments) { attachment in
                    MessageAttachmentThumbnail(attachment: attachment)
                }
            }
        }
        .frame(width: bubbleContentWidth, alignment: .leading)
        .scrollIndicators(.hidden)
    }

    private func estimatedTextWidth(_ text: String, minWidth: CGFloat, maxWidth: CGFloat, role: MessageRole) -> CGFloat {
        let cleaned = text
            .replacingOccurrences(of: #"\*\*\s*\*\*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return minWidth }

        if role == .user {
            return estimatedUserTextWidth(cleaned, minWidth: minWidth, maxWidth: maxWidth)
        }

        let longestLineWidth = cleaned
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { lineWidth(String($0), maxWidth: maxWidth) }
            .max() ?? minWidth
        return min(maxWidth, max(minWidth, ceil(longestLineWidth)))
    }

    private func estimatedUserTextWidth(_ text: String, minWidth: CGFloat, maxWidth: CGFloat) -> CGFloat {
        let maxUnitsBeforeWrap: CGFloat = 15
        let widestLineUnits = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { displayUnits(String($0)) }
            .max() ?? 0
        guard widestLineUnits > 0 else { return minWidth }
        if widestLineUnits >= maxUnitsBeforeWrap {
            return maxWidth
        }
        let width = widestLineUnits * 18.5 + 18
        return min(maxWidth, max(minWidth, ceil(width)))
    }

    private func displayUnits(_ line: String) -> CGFloat {
        line.reduce(CGFloat(0)) { result, character in
            result + displayUnit(for: character)
        }
    }

    private func displayUnit(for character: Character) -> CGFloat {
        guard let scalar = character.unicodeScalars.first else { return 0.5 }
        if CharacterSet.whitespacesAndNewlines.contains(scalar) {
            return 0.25
        }
        if isWideScalar(scalar.value) || scalar.properties.isEmojiPresentation {
            return 1
        }
        return 0.52
    }

    private func lineWidth(_ line: String, maxWidth: CGFloat) -> CGFloat {
        var width: CGFloat = 0
        for character in line {
            width += estimatedCharacterWidth(character)
            if width >= maxWidth {
                return maxWidth
            }
        }
        return width
    }

    private func estimatedCharacterWidth(_ character: Character) -> CGFloat {
        guard let scalar = character.unicodeScalars.first else { return 8.5 }
        if CharacterSet.whitespacesAndNewlines.contains(scalar) {
            return 5
        }
        if isWideScalar(scalar.value) || scalar.properties.isEmojiPresentation {
            return 17
        }
        return 8.5
    }

    private func isWideScalar(_ value: UInt32) -> Bool {
        switch value {
        case 0x1100...0x11FF, 0x2E80...0xA4CF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFE10...0xFE6F, 0xFF00...0xFFEF:
            return true
        default:
            return false
        }
    }

    private var bubbleFill: Color {
        switch message.role {
        case .user:
            return Color.accentColor.opacity(0.18)
        case .assistant:
            return Color.gray.opacity(0.22)
        case .system:
            return Color.gray.opacity(0.16)
        }
    }
}

private struct MarkdownMessageText: View {
    let text: String
    @Environment(\.markdownEnabled) private var markdownEnabled

    var body: some View {
        Group {
            if markdownEnabled,
               let attributed = try? AttributedString(
                markdown: normalizedText,
                options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            ) {
                Text(attributed)
            } else {
                Text(normalizedText)
            }
        }
    }

    private var normalizedText: String {
        text
            .replacingOccurrences(
                of: #"\*\*\s*\*\*"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct MarkdownEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

private extension EnvironmentValues {
    var markdownEnabled: Bool {
        get { self[MarkdownEnabledKey.self] }
        set { self[MarkdownEnabledKey.self] = newValue }
    }
}

private extension View {
    func markdownEnabled(_ enabled: Bool) -> some View {
        environment(\.markdownEnabled, enabled)
    }
}

private struct MessageAttachmentThumbnail: View {
    let attachment: ChatAttachment

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            thumbnail
                .frame(width: 118, height: 86)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.white.opacity(0.22), lineWidth: 1)
                )

            if attachment.kind == .video {
                Image(systemName: "play.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(.black.opacity(0.52), in: Circle())
                    .padding(7)
            }
        }
        .accessibilityLabel("附件 \(attachment.fileName)")
    }

    @ViewBuilder
    private var thumbnail: some View {
        if attachment.kind == .image,
           let image = UIImage(contentsOfFile: attachment.localPath) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                Rectangle()
                    .fill(.regularMaterial)
                VStack(spacing: 6) {
                    Image(systemName: attachment.kind == .video ? "video.fill" : "doc.fill")
                        .font(.system(size: 22, weight: .semibold))
                    Text((attachment.fileName as NSString).pathExtension.uppercased())
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(.secondary)
            }
        }
    }
}

private struct EmptyChatState: View {
    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(.secondary)
            Text("开始一段对话")
                .font(.headline)
            Text("底部输入文字，或用左侧加号添加图片。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
    }
}

private struct AvatarView: View {
    let path: String?
    let fallback: String

    var body: some View {
        Group {
            if let path,
               let image = UIImage(contentsOfFile: path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle()
                    .fill(Color.accentColor.gradient)
                    .overlay(
                        Text(String(fallback.prefix(1)))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                    )
            }
        }
        .clipShape(Circle())
        .overlay(Circle().stroke(.quaternary, lineWidth: 1))
    }
}

private struct PersonaBackground: View {
    let profile: CharacterProfile

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let path = profile.backgroundVideoPath,
                   FileManager.default.fileExists(atPath: path) {
                    LoopingMutedVideoView(url: URL(fileURLWithPath: path))
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    Color(uiColor: .systemBackground)
                }

                if let path = profile.backgroundImagePath,
                   let image = UIImage(contentsOfFile: path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
private struct LoopingMutedVideoView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.configure(url: url)
        return view
    }

    func updateUIView(_ uiView: PlayerView, context: Context) {
        if uiView.currentURL != url {
            uiView.configure(url: url)
        } else {
            uiView.player?.play()
        }
    }

    final class PlayerView: UIView {
        var currentURL: URL?
        var player: AVQueuePlayer?
        var looper: AVPlayerLooper?

        override static var layerClass: AnyClass {
            AVPlayerLayer.self
        }

        var playerLayer: AVPlayerLayer {
            layer as! AVPlayerLayer
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            playerLayer.videoGravity = .resizeAspectFill
        }

        func configure(url: URL) {
            currentURL = url
            let item = AVPlayerItem(url: url)
            let player = AVQueuePlayer()
            player.isMuted = true
            player.actionAtItemEnd = .none
            self.player = player
            looper = AVPlayerLooper(player: player, templateItem: item)
            playerLayer.player = player
            player.play()
        }
    }
}

private struct ConversationSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var profile = CharacterProfile()
    @State private var systemPrompt = ""
    @State private var avatarItem: PhotosPickerItem?
    @State private var backgroundItem: PhotosPickerItem?

    var body: some View {
        NavigationStack {
            Form {
                Section("角色") {
                    TextField("角色名称", text: $profile.name)
                    PhotosPicker(selection: $avatarItem, matching: .images) {
                        Label("选择角色头像", systemImage: "person.crop.circle")
                    }
                    if profile.botAvatarPath != nil {
                        Button(role: .destructive) {
                            profile.botAvatarPath = nil
                            avatarItem = nil
                            save()
                        } label: {
                            Label("移除角色头像", systemImage: "xmark.circle")
                        }
                    }
                    PhotosPicker(selection: $backgroundItem, matching: .any(of: [.images, .videos])) {
                        Label("选择聊天背景", systemImage: "photo.on.rectangle")
                    }
                    if hasExistingBackground {
                        Button(role: .destructive) {
                            profile.backgroundImagePath = nil
                            profile.backgroundVideoPath = nil
                            backgroundItem = nil
                            save()
                        } label: {
                            Label("移除聊天背景", systemImage: "xmark.circle")
                        }
                    }
                }

                Section("系统提示词卡片") {
                    TextField("当前对话的系统提示词", text: $systemPrompt, prompt: Text("留空则不发送系统提示词"), axis: .vertical)
                        .lineLimit(4...10)
                }
            }
            .navigationTitle("当前对话设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("完成") {
                    save()
                    dismiss()
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .onAppear {
                profile = store.selectedConversationProfile
                systemPrompt = store.selectedConversation?.systemPrompt ?? ""
                clearMissingBackgroundReferences()
            }
            .onChange(of: profile) { save() }
            .onChange(of: systemPrompt) { save() }
            .onChange(of: avatarItem) {
                Task {
                    if let path = await savePickedImage(avatarItem, prefix: "conversation-avatar") {
                        profile.botAvatarPath = path
                        save()
                    }
                }
            }
            .onChange(of: backgroundItem) {
                Task {
                    if let path = await savePickedMedia(backgroundItem, prefix: "conversation-background") {
                        let lower = path.lowercased()
                        if lower.hasSuffix(".mov") || lower.hasSuffix(".mp4") || lower.hasSuffix(".m4v") {
                            profile.backgroundVideoPath = path
                            profile.backgroundImagePath = nil
                        } else {
                            profile.backgroundImagePath = path
                            profile.backgroundVideoPath = nil
                        }
                        save()
                    }
                }
            }
        }
    }

    private func save() {
        store.updateSelectedConversationProfile(profile, systemPrompt: systemPrompt)
    }

    private var hasExistingBackground: Bool {
        fileExists(profile.backgroundImagePath) || fileExists(profile.backgroundVideoPath)
    }

    private func fileExists(_ path: String?) -> Bool {
        guard let path, !path.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    private func clearMissingBackgroundReferences() {
        var changed = false
        if profile.backgroundImagePath != nil && !fileExists(profile.backgroundImagePath) {
            profile.backgroundImagePath = nil
            changed = true
        }
        if profile.backgroundVideoPath != nil && !fileExists(profile.backgroundVideoPath) {
            profile.backgroundVideoPath = nil
            changed = true
        }
        if changed {
            save()
        }
    }

    private func savePickedImage(_ item: PhotosPickerItem?, prefix: String) async -> String? {
        guard let item, let data = try? await item.loadTransferable(type: Data.self) else { return nil }
        let url = Persistence.directory().appendingPathComponent("\(prefix)-\(UUID().uuidString).jpg")
        try? data.write(to: url, options: [.atomic])
        return url.path
    }

    private func savePickedMedia(_ item: PhotosPickerItem?, prefix: String) async -> String? {
        guard let item, let data = try? await item.loadTransferable(type: Data.self) else { return nil }
        let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
        let ext = isVideo ? "mov" : "jpg"
        let url = Persistence.directory().appendingPathComponent("\(prefix)-\(UUID().uuidString).\(ext)")
        try? data.write(to: url, options: [.atomic])
        return url.path
    }
}

private struct ScrollContentHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ScrollBottomAnchorPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ScrollViewportHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct CameraCaptureView: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> CameraViewController {
        CameraViewController(
            onImage: { image in
                onImage(image)
                dismiss()
            },
            onCancel: {
                dismiss()
            }
        )
    }

    func updateUIViewController(_ uiViewController: CameraViewController, context: Context) {}
}

private final class CameraViewController: UIViewController, @preconcurrency AVCapturePhotoCaptureDelegate {
    private let onImage: (UIImage) -> Void
    private let onCancel: () -> Void
    private let cameraSession = CameraSession()
    private let sessionQueue = DispatchQueue(label: "omnipersona.camera.session")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var isFlashOn = false
    private var flashButton: UIButton?
    private var shutterButton: UIButton?
    private var reviewImageView: UIImageView?
    private var reviewControls: UIStackView?
    private var capturedImage: UIImage?

    init(onImage: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
        self.onImage = onImage
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configurePreview()
        configureControls()
        requestAndConfigureSession()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let cameraSession = cameraSession
        sessionQueue.async {
            cameraSession.stopRunning()
        }
    }

    private func configurePreview() {
        let layer = AVCaptureVideoPreviewLayer(session: cameraSession.session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer
    }

    private func configureControls() {
        let closeButton = makeCircleButton(systemName: "xmark")
        closeButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

        let flashButton = makeCircleButton(systemName: "bolt.slash")
        flashButton.addTarget(self, action: #selector(toggleFlash), for: .touchUpInside)
        self.flashButton = flashButton

        let shutterButton = UIButton(type: .system)
        shutterButton.translatesAutoresizingMaskIntoConstraints = false
        shutterButton.backgroundColor = .white
        shutterButton.layer.cornerRadius = 35
        shutterButton.layer.borderWidth = 4
        shutterButton.layer.borderColor = UIColor.white.withAlphaComponent(0.45).cgColor
        shutterButton.addTarget(self, action: #selector(capturePhoto), for: .touchUpInside)
        self.shutterButton = shutterButton

        let deleteButton = makeReviewButton(title: "删除", imageName: "trash", tint: .systemRed)
        deleteButton.addTarget(self, action: #selector(discardCapturedPhoto), for: .touchUpInside)

        let useButton = makeReviewButton(title: "使用照片", imageName: "checkmark", tint: .systemBlue)
        useButton.addTarget(self, action: #selector(useCapturedPhoto), for: .touchUpInside)

        let reviewControls = UIStackView(arrangedSubviews: [deleteButton, useButton])
        reviewControls.translatesAutoresizingMaskIntoConstraints = false
        reviewControls.axis = .horizontal
        reviewControls.spacing = 12
        reviewControls.distribution = .fillEqually
        reviewControls.isHidden = true
        self.reviewControls = reviewControls

        view.addSubview(closeButton)
        view.addSubview(flashButton)
        view.addSubview(shutterButton)
        view.addSubview(reviewControls)

        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 18),
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 14),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),

            flashButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -18),
            flashButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 14),
            flashButton.widthAnchor.constraint(equalToConstant: 44),
            flashButton.heightAnchor.constraint(equalToConstant: 44),

            shutterButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            shutterButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -28),
            shutterButton.widthAnchor.constraint(equalToConstant: 70),
            shutterButton.heightAnchor.constraint(equalToConstant: 70),

            reviewControls.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 18),
            reviewControls.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -18),
            reviewControls.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            reviewControls.heightAnchor.constraint(equalToConstant: 50)
        ])
    }

    private func makeCircleButton(systemName: String) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(UIImage(systemName: systemName), for: .normal)
        button.tintColor = .white
        button.backgroundColor = UIColor.black.withAlphaComponent(0.42)
        button.layer.cornerRadius = 22
        button.clipsToBounds = true
        return button
    }

    private func makeReviewButton(title: String, imageName: String, tint: UIColor) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.image = UIImage(systemName: imageName)
        configuration.imagePadding = 7
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = UIColor.black.withAlphaComponent(0.58)
        configuration.baseForegroundColor = tint == .systemBlue ? .white : tint

        let button = UIButton(configuration: configuration)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    private func requestAndConfigureSession() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted {
                    DispatchQueue.main.async { self?.configureSession() }
                } else {
                    DispatchQueue.main.async { self?.onCancel() }
                }
            }
        default:
            onCancel()
        }
    }

    private func configureSession() {
        let cameraSession = cameraSession
        sessionQueue.async { [weak self, cameraSession] in
            guard cameraSession.configureAndStart() else {
                DispatchQueue.main.async { self?.onCancel() }
                return
            }
        }
    }

    @objc private func cancelTapped() {
        onCancel()
    }

    @objc private func toggleFlash(_ sender: UIButton) {
        isFlashOn.toggle()
        sender.setImage(UIImage(systemName: isFlashOn ? "bolt.fill" : "bolt.slash"), for: .normal)
        sender.tintColor = isFlashOn ? .systemYellow : .white
    }

    @objc private func capturePhoto() {
        guard capturedImage == nil else { return }
        let settings = AVCapturePhotoSettings()
        if cameraSession.output.supportedFlashModes.contains(isFlashOn ? .on : .off) {
            settings.flashMode = isFlashOn ? .on : .off
        }
        cameraSession.output.capturePhoto(with: settings, delegate: self)
    }

    @objc private func discardCapturedPhoto() {
        capturedImage = nil
        reviewImageView?.removeFromSuperview()
        reviewImageView = nil
        reviewControls?.isHidden = true
        shutterButton?.isHidden = false
        flashButton?.isHidden = false
        let cameraSession = cameraSession
        sessionQueue.async {
            cameraSession.startRunning()
        }
    }

    @objc private func useCapturedPhoto() {
        guard let capturedImage else { return }
        onImage(capturedImage)
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil,
              let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data)
        else {
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.showCapturedPhoto(image)
        }
    }

    private func showCapturedPhoto(_ image: UIImage) {
        capturedImage = image
        let cameraSession = cameraSession
        sessionQueue.async {
            cameraSession.stopRunning()
        }
        reviewImageView?.removeFromSuperview()
        let imageView = UIImageView(image: image)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.backgroundColor = .black
        view.insertSubview(imageView, belowSubview: reviewControls ?? view)
        reviewImageView = imageView

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: view.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        shutterButton?.isHidden = true
        flashButton?.isHidden = true
        reviewControls?.isHidden = false
    }
}

private final class CameraSession: @unchecked Sendable {
    let session = AVCaptureSession()
    let output = AVCapturePhotoOutput()
    private var isConfigured = false

    func configureAndStart() -> Bool {
        if isConfigured {
            startRunning()
            return true
        }

        session.beginConfiguration()
        session.sessionPreset = .photo

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input),
              session.canAddOutput(output)
        else {
            session.commitConfiguration()
            return false
        }

        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        isConfigured = true
        startRunning()
        return true
    }

    func startRunning() {
        if !session.isRunning {
            session.startRunning()
        }
    }

    func stopRunning() {
        if session.isRunning {
            session.stopRunning()
        }
    }
}
