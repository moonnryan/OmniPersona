import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @State private var selection: SidebarItem?
    @State private var columnVisibility = NavigationSplitViewVisibility.detailOnly
    @State private var lastChatID: UUID?

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $selection) {
                Section {
                    Button {
                        store.newConversation()
                        if let id = store.selectedConversationID {
                            selection = .chat(id)
                            lastChatID = id
                        }
                    } label: {
                        Label("新建对话", systemImage: "plus.message")
                    }
                }

                Section("对话") {
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
                                                    lastChatID = id
                                                } else {
                                                    selection = nil
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
                }

                Section("配置") {
                    Label("模型管理", systemImage: "externaldrive")
                        .tag(SidebarItem.models)
                    Label("设置", systemImage: "slider.horizontal.3")
                        .tag(SidebarItem.settings)
                }
            }
            .navigationTitle("OmniPersona")
            .animation(.snappy(duration: 0.18), value: store.conversations)
            .simultaneousGesture(
                DragGesture(minimumDistance: 24)
                    .onEnded { value in
                        guard value.translation.width < -70,
                              abs(value.translation.width) > abs(value.translation.height),
                              !isConversationRowDrag(value.startLocation),
                              let id = lastChatID ?? store.selectedConversationID ?? store.conversations.first?.id
                        else {
                            return
                        }
                        selection = .chat(id)
                        columnVisibility = .detailOnly
                    }
            )
        } detail: {
            NavigationStack {
                Group {
                    switch selection {
                    case .chat(let id):
                        ChatView()
                            .onAppear {
                                store.selectedConversationID = id
                            }
                    case .models:
                        ModelManagerView()
                    case .settings:
                        SettingsView()
                    case nil:
                        ChatView()
                    }
                }
                .id(selection)
                .animation(.snappy(duration: 0.18), value: selection)
            }
        }
        .onAppear {
            if selection == nil {
                let id = store.selectedConversationID ?? store.conversations.first?.id
                if let id {
                    store.selectedConversationID = id
                    lastChatID = id
                    selection = .chat(id)
                }
            }
        }
        .onChange(of: selection) {
            if case .chat(let id) = selection {
                store.selectedConversationID = id
                lastChatID = id
            }
            columnVisibility = .detailOnly
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
    }

    private func isConversationRowDrag(_ location: CGPoint) -> Bool {
        let conversationTop: CGFloat = 116
        let rowHeight: CGFloat = 56
        let conversationBottom = conversationTop + CGFloat(store.conversations.count) * rowHeight
        return location.y >= conversationTop && location.y <= conversationBottom
    }
}

private enum SidebarItem: Hashable {
    case chat(UUID)
    case models
    case settings
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
