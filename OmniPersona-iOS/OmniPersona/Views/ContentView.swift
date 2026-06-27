import SwiftUI
import UIKit

extension Notification.Name {
    static let omniPersonaCollapseTransientChatUI = Notification.Name("OmniPersonaCollapseTransientChatUI")
}

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @State private var selection: SidebarItem?
    @State private var detailSelection: SidebarItem?
    @State private var columnVisibility = NavigationSplitViewVisibility.detailOnly
    @State private var lastChatID: UUID?

    var body: some View {
        ZStack {
            mainInterface
                .opacity(store.isFirstLaunchSetupRunning ? 0 : 1)
                .allowsHitTesting(!store.isFirstLaunchSetupRunning)
                .background(
                    FirstInteractiveFrameReporter {
                        store.markFirstLaunchInterfaceReady()
                    }
                )

            if store.isFirstLaunchSetupRunning {
                FirstLaunchSetupView()
                    .transition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.16), value: store.isFirstLaunchSetupRunning)
    }

    private var mainInterface: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            detail
        }
        .onAppear {
            selectCurrentChatIfNeeded()
        }
        .onChange(of: store.selectedConversationID) {
            if case .chat = activeSelection {
                selectCurrentChatIfNeeded(force: true)
            }
        }
        .onChange(of: selection) {
            guard let selection else { return }
            collapseTransientChatUI()
            detailSelection = selection
            if case .chat(let id) = selection {
                store.selectedConversationID = id
                lastChatID = id
            }
            columnVisibility = .detailOnly
        }
        .onChange(of: columnVisibility) {
            if columnVisibility != .detailOnly {
                collapseTransientChatUI()
            }
        }
        .overlay(alignment: .top) {
            if !store.notificationText.isEmpty {
                Text(store.notificationText)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.22), value: store.notificationText)
        .simultaneousGesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    guard abs(value.translation.width) > 8,
                          abs(value.translation.width) > abs(value.translation.height)
                    else {
                        return
                    }
                    collapseTransientChatUI()
                }
        )
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                Button {
                    store.newConversation()
                    if let id = store.selectedConversationID {
                        selection = .chat(id)
                        detailSelection = .chat(id)
                        lastChatID = id
                    }
                } label: {
                    Label("新建对话", systemImage: "plus.message")
                }
            }

            Section {
                if store.conversations.isEmpty {
                    Text("新建对话来开始")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 18)
                } else {
                    ForEach(store.conversations) { conversation in
                        ConversationRow(conversation: conversation)
                            .tag(SidebarItem.chat(conversation.id))
                            .swipeActions {
                                Button(role: .destructive) {
                                    let deletingCurrent = store.selectedConversationID == conversation.id
                                    withAnimation(.snappy(duration: 0.18)) {
                                        store.deleteConversation(conversation)
                                        if deletingCurrent {
                                            if let id = store.selectedConversationID {
                                                selection = .chat(id)
                                                detailSelection = .chat(id)
                                                lastChatID = id
                                            } else {
                                                selection = nil
                                                detailSelection = nil
                                                lastChatID = nil
                                            }
                                        }
                                    }
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                        }
                    }
                }
            } header: {
                SidebarSectionHeader("对话")
            }

            Section {
                Label("模型管理", systemImage: "externaldrive")
                    .tag(SidebarItem.models)
                Label("设置", systemImage: "slider.horizontal.3")
                    .tag(SidebarItem.settings)
            } header: {
                SidebarSectionHeader("配置")
            }
        }
        .navigationTitle("OmniPersona")
        .animation(.snappy(duration: 0.18), value: store.conversations)
        .simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .onChanged { value in
                    guard abs(value.translation.width) > 18,
                          abs(value.translation.width) > abs(value.translation.height)
                    else {
                        return
                    }
                    collapseTransientChatUI()
                }
                .onEnded { value in
                    guard value.translation.width < -70,
                          abs(value.translation.width) > abs(value.translation.height),
                          !isConversationRowDrag(value.startLocation),
                          let id = lastChatID ?? store.selectedConversationID ?? store.conversations.first?.id
                    else {
                        return
                    }
                    collapseTransientChatUI()
                    selection = .chat(id)
                    detailSelection = .chat(id)
                    columnVisibility = .detailOnly
                }
        )
    }

    private var detail: some View {
        NavigationStack {
            Group {
                switch activeSelection {
                case .chat(let id):
                    ChatView(sidebarVisible: columnVisibility != .detailOnly)
                        .onAppear {
                            store.selectedConversationID = id
                        }
                case .models:
                    ModelManagerView()
                case .settings:
                    SettingsView()
                case nil:
                    EmptyConversationDetail()
                }
            }
        }
    }

    private var activeSelection: SidebarItem? {
        if let selection {
            return selection
        }
        if let detailSelection {
            return detailSelection
        }
        if let id = store.selectedConversationID ?? store.conversations.first?.id {
            return .chat(id)
        }
        return nil
    }

    private func isConversationRowDrag(_ location: CGPoint) -> Bool {
        let conversationTop: CGFloat = 116
        let rowHeight: CGFloat = 56
        let conversationBottom = conversationTop + CGFloat(store.conversations.count) * rowHeight
        return location.y >= conversationTop && location.y <= conversationBottom
    }

    private func selectCurrentChatIfNeeded(force: Bool = false) {
        guard force || selection == nil else { return }
        guard let id = store.selectedConversationID ?? store.conversations.first?.id else { return }
        selection = .chat(id)
        detailSelection = .chat(id)
        lastChatID = id
        columnVisibility = .detailOnly
    }

    private func collapseTransientChatUI() {
        NotificationCenter.default.post(name: .omniPersonaCollapseTransientChatUI, object: nil)
        UIApplication.shared.endEditingImmediately()
    }
}

private struct SidebarSectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 19, weight: .semibold))
            .foregroundStyle(.primary.opacity(0.86))
            .textCase(.none)
            .offset(x: -16)
    }
}

extension UIApplication {
    func endEditingImmediately() {
        connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .forEach { $0.endEditing(true) }
        sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

private enum SidebarItem: Hashable {
    case chat(UUID)
    case models
    case settings
}

private struct FirstLaunchSetupView: View {
    var body: some View {
        VStack(spacing: 18) {
            ProgressView()
                .controlSize(.large)

            VStack(spacing: 6) {
                Text("正在配置 OmniPersona")
                    .font(.headline)
                Text("准备本地会话和运行环境")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
    }
}

private struct FirstInteractiveFrameReporter: UIViewRepresentable {
    let onReady: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        reportIfNeeded(context)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        reportIfNeeded(context)
    }

    private func reportIfNeeded(_ context: Context) {
        guard !context.coordinator.didReport else { return }
        context.coordinator.didReport = true
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                onReady()
            }
        }
    }

    final class Coordinator {
        var didReport = false
    }
}

private struct EmptyConversationDetail: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "plus.message")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(.secondary)
            Text("新建对话来开始")
                .font(.headline)
            Text("从侧边栏新建一个聊天。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
    }
}

private struct ConversationRow: View {
    let conversation: Conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(conversation.title)
                .font(.headline)
                .lineLimit(1)
            Text(conversation.updatedAt, style: .date)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}
