import Foundation
import SwiftUI

@MainActor
final class AppStore: ObservableObject {
    @Published var settings: AppSettings
    @Published var conversations: [Conversation]
    @Published var selectedConversationID: UUID?
    @Published var isGenerating = false
    @Published var statusText = ""
    @Published var loadedLocalModelID: UUID?
    @Published var loadingLocalModelID: UUID?
    @Published var isPreviewingTTS = false
    @Published var notificationText = ""
    @Published var isTTSEnabled = true

    private let chatService = OpenAIChatService()
    private let localService = LocalLlamaService()
    private let ttsService = TTSService()
    let modelDownloadController = ModelDownloadController()
    let modelDetailDownloadController = ModelDownloadController()
    private var ttsSpeechTask: Task<Void, Never>?
    private let streamUIFlushInterval: TimeInterval = 0.06

    init() {
        Self.resetPersistentStateForNewDebugBuildIfNeeded()
        settings = Persistence.load("settings.json") ?? AppSettings()
        conversations = Persistence.load("conversations.json") ?? [
            Conversation(title: "新的对话", messages: [])
        ]
        selectedConversationID = conversations.first?.id
        migrateDefaults()
        migrateInstallState()
        validateLocalModels()
        ttsService.onStatus = { [weak self] message in
            self?.showNotification(message)
        }
        Task { [weak self] in
            await self?.prewarmMossOnLaunch()
        }
    }

    var selectedConversation: Conversation? {
        guard let selectedConversationID else { return nil }
        return conversations.first { $0.id == selectedConversationID }
    }

    var selectedLocalModel: LocalModel? {
        settings.localModels.first { $0.isSelected }
    }

    var selectedOpenAIModel: OpenAIModelConfig? {
        settings.endpoints.openAIModels.first { $0.id == settings.endpoints.selectedOpenAIModelID }
            ?? settings.endpoints.openAIModels.first
    }

    var localModelDisplayStatus: String {
        if isGenerating, settings.endpoints.backend == .localLlama {
            return "推理中"
        }
        if loadingLocalModelID != nil {
            return "加载中"
        }
        if let loadedLocalModelID,
           let model = settings.localModels.first(where: { $0.id == loadedLocalModelID }),
           model.hasTextModel {
            return model.repoID
        }
        return "未加载"
    }

    var selectedConversationProfile: CharacterProfile {
        selectedConversation?.profile ?? settings.profile
    }

    func save() {
        Persistence.save(settings, to: "settings.json")
        Persistence.save(conversations, to: "conversations.json")
    }

    func showNotification(_ text: String) {
        notificationText = text
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            guard self?.notificationText == text else { return }
            self?.notificationText = ""
        }
    }

    func validateLocalModels() {
        var changed = false
        for index in settings.localModels.indices {
            if let path = settings.localModels[index].llmLocalPath,
               !FileManager.default.fileExists(atPath: path) {
                settings.localModels[index].llmLocalPath = nil
                changed = true
            }
            if let path = settings.localModels[index].mmprojLocalPath,
               !FileManager.default.fileExists(atPath: path) {
                settings.localModels[index].mmprojLocalPath = nil
                changed = true
            }
        }
        let oldCount = settings.localModels.count
        settings.localModels.removeAll { !$0.hasTextModel && !$0.hasVisionProjector }
        changed = changed || settings.localModels.count != oldCount
        if let loadedLocalModelID,
           !settings.localModels.contains(where: { $0.id == loadedLocalModelID && $0.hasTextModel }) {
            self.loadedLocalModelID = nil
        }
        if let loadingLocalModelID,
           !settings.localModels.contains(where: { $0.id == loadingLocalModelID && $0.hasTextModel }) {
            self.loadingLocalModelID = nil
        }
        let oldVoiceCount = settings.clonedVoices.count
        settings.clonedVoices.removeAll { voice in
            !FileManager.default.fileExists(atPath: voice.referenceAudioPath)
        }
        changed = changed || settings.clonedVoices.count != oldVoiceCount
        if let selectedID = settings.tts.selectedCloneVoiceID,
           !settings.clonedVoices.contains(where: { $0.id == selectedID }) {
            settings.tts.selectedCloneVoiceID = settings.clonedVoices.first?.id
            if settings.tts.selectedCloneVoiceID == nil {
                settings.tts.voiceMode = .preset
            }
            changed = true
        }
        if !settings.localModels.contains(where: { $0.isSelected }) {
            settings.localModels.indices.first.map { settings.localModels[$0].isSelected = true }
            changed = changed || !settings.localModels.isEmpty
        }
        if changed {
            save()
        }
    }

    private func migrateDefaults() {
        if settings.endpoints.backend == .lanOpenAI,
           settings.endpoints.lanBaseURL == "http://192.168.31.11:1234/v1",
           settings.endpoints.lanModel == "local-model",
           settings.endpoints.lanAPIKey == "no-key" {
            settings.endpoints.backend = .localLlama
        }
        if settings.endpoints.lanBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            settings.endpoints.lanBaseURL = "http://192.168.31.11:1234/v1"
        }
        if settings.endpoints.lanModel == "local-model" {
            settings.endpoints.lanModel = ""
        }
        if settings.endpoints.lanAPIKey == "no-key" {
            settings.endpoints.lanAPIKey = ""
        }
        if settings.endpoints.remoteModel == "gpt-4.1-mini" {
            settings.endpoints.remoteModel = ""
        }
        var importedOpenAIModels = settings.endpoints.openAIModels
        if importedOpenAIModels.isEmpty {
            let lanModel = OpenAIModelConfig(
                name: "Wi-Fi 内网接口",
                baseURL: settings.endpoints.lanBaseURL,
                apiKey: settings.endpoints.lanAPIKey,
                model: settings.endpoints.lanModel,
                sendsThinking: true
            )
            if !lanModel.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                settings.endpoints.backend == .lanOpenAI {
                importedOpenAIModels.append(lanModel)
            }

            let remoteModel = OpenAIModelConfig(
                name: "远程云服务",
                baseURL: settings.endpoints.remoteBaseURL,
                apiKey: settings.endpoints.remoteAPIKey,
                model: settings.endpoints.remoteModel,
                sendsThinking: false
            )
            if !remoteModel.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                settings.endpoints.backend == .remoteOpenAI {
                importedOpenAIModels.append(remoteModel)
            }
            settings.endpoints.openAIModels = importedOpenAIModels
        }
        if settings.endpoints.backend == .lanOpenAI || settings.endpoints.backend == .remoteOpenAI {
            settings.endpoints.backend = .openAICompatible
        }
        if settings.endpoints.selectedOpenAIModelID == nil {
            settings.endpoints.selectedOpenAIModelID = settings.endpoints.openAIModels.first?.id
        }
        if settings.generation.systemPrompt == "你是一个运行在手机端的多模态语音助手。" {
            settings.generation.systemPrompt = ""
        }
        if !TTSPresetVoices.all.contains(where: { $0.id == settings.tts.presetVoice }) {
            settings.tts.presetVoice = "zh_child_bright"
        }
        if TTSSettings.isDefaultPreviewText(settings.tts.previewText) {
            settings.tts.previewText = TTSSettings.defaultPreviewText(forPresetVoice: settings.tts.presetVoice)
        }
    }

    private func migrateInstallState() {
        let current = Self.currentInstallFingerprint()
        let previous: AppInstallState? = Persistence.load("install_state.json")
        if previous?.fingerprint != current {
            clearClonedVoiceCache()
            Persistence.save(AppInstallState(fingerprint: current), to: "install_state.json")
        }
    }

    private static func resetPersistentStateForNewDebugBuildIfNeeded() {
#if DEBUG
        let current = currentInstallFingerprint()
        let key = "OmniPersona.LastDebugBuildFingerprint"
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: key) != current else { return }
        Persistence.removeAll()
        defaults.set(current, forKey: key)
#endif
    }

    private static func currentInstallFingerprint() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        let executable = Bundle.main.executableURL ?? Bundle.main.bundleURL
        let modified = (try? executable.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?
            .timeIntervalSince1970 ?? 0
        return "\(version)-\(build)-\(Int(modified))"
    }

    private func clearClonedVoiceCache() {
        guard !settings.clonedVoices.isEmpty || settings.tts.voiceMode == .clone else {
            removeOrphanClonedVoiceFiles()
            return
        }
        for voice in settings.clonedVoices {
            removeFileIfNeeded(voice.referenceAudioPath)
        }
        settings.clonedVoices.removeAll()
        settings.tts.selectedCloneVoiceID = nil
        settings.tts.voiceMode = .preset
        save()
        removeOrphanClonedVoiceFiles()
    }

    private func removeOrphanClonedVoiceFiles() {
        let directory = Persistence.directory()
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for url in urls where url.lastPathComponent.hasPrefix("voice-") {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func newConversation() {
        let conversation = Conversation(title: "新的对话", messages: [])
        conversations.insert(conversation, at: 0)
        selectedConversationID = conversation.id
        save()
    }

    func deleteConversation(_ conversation: Conversation) {
        let deletingSelected = selectedConversationID == conversation.id
        conversations.removeAll { $0.id == conversation.id }
        if deletingSelected {
            selectedConversationID = conversations.first?.id
        }
        save()
    }

    func deleteMessage(_ message: ChatMessage) {
        guard let conversationIndex = currentConversationIndex(),
              let messageIndex = conversations[conversationIndex].messages.firstIndex(where: { $0.id == message.id })
        else {
            return
        }
        var removalRange = messageIndex..<(messageIndex + 1)
        let nextIndex = conversations[conversationIndex].messages.index(after: messageIndex)
        if message.role == .user,
           nextIndex < conversations[conversationIndex].messages.endIndex,
           conversations[conversationIndex].messages[nextIndex].role == .assistant {
            removalRange = messageIndex..<(nextIndex + 1)
        }
        conversations[conversationIndex].messages.removeSubrange(removalRange)
        conversations[conversationIndex].updatedAt = Date()
        save()
    }

    func updateSelectedConversationProfile(_ profile: CharacterProfile, systemPrompt: String) {
        guard let index = currentConversationIndex() else { return }
        conversations[index].profile = profile
        conversations[index].systemPrompt = systemPrompt
        conversations[index].updatedAt = Date()
        save()
    }

    func selectLocalModel(_ modelID: UUID) {
        validateLocalModels()
        for index in settings.localModels.indices {
            settings.localModels[index].isSelected = settings.localModels[index].id == modelID
        }
        save()
    }

    func toggleLocalModelLoaded(_ model: LocalModel) {
        guard model.hasTextModel else { return }
        if loadedLocalModelID == model.id {
            loadedLocalModelID = nil
            loadingLocalModelID = nil
            return
        }
        loadingLocalModelID = model.id
        selectLocalModel(model.id)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            if loadingLocalModelID == model.id {
                loadedLocalModelID = model.id
                loadingLocalModelID = nil
            }
        }
    }

    func upsertLocalModel(_ model: LocalModel) {
        var incoming = model
        if !settings.localModels.contains(where: { $0.isSelected }) {
            incoming.isSelected = true
        }

        if let index = settings.localModels.firstIndex(where: { $0.repoID == model.repoID }) {
            let wasSelected = settings.localModels[index].isSelected
            settings.localModels[index] = incoming
            settings.localModels[index].isSelected = wasSelected || incoming.isSelected
        } else {
            settings.localModels.append(incoming)
        }
        save()
    }

    func deleteLocalModel(_ model: LocalModel) {
        if loadedLocalModelID == model.id {
            loadedLocalModelID = nil
        }
        if loadingLocalModelID == model.id {
            loadingLocalModelID = nil
        }
        removeFileIfNeeded(model.llmLocalPath)
        removeFileIfNeeded(model.mmprojLocalPath)
        try? FileManager.default.removeItem(at: Persistence.modelDirectory(for: model.repoID))
        settings.localModels.removeAll { $0.id == model.id }
        if !settings.localModels.contains(where: { $0.isSelected }) {
            settings.localModels.indices.first.map { settings.localModels[$0].isSelected = true }
        }
        save()
    }

    func upsertOpenAIModel(_ model: OpenAIModelConfig) {
        if let index = settings.endpoints.openAIModels.firstIndex(where: { $0.id == model.id }) {
            settings.endpoints.openAIModels[index] = model
        } else {
            settings.endpoints.openAIModels.append(model)
        }
        settings.endpoints.backend = .openAICompatible
        if settings.endpoints.selectedOpenAIModelID == nil {
            settings.endpoints.selectedOpenAIModelID = model.id
        }
        save()
    }

    func selectOpenAIModel(_ modelID: UUID) {
        settings.endpoints.backend = .openAICompatible
        settings.endpoints.selectedOpenAIModelID = modelID
        save()
    }

    func deleteOpenAIModel(_ model: OpenAIModelConfig) {
        settings.endpoints.openAIModels.removeAll { $0.id == model.id }
        if settings.endpoints.selectedOpenAIModelID == model.id {
            settings.endpoints.selectedOpenAIModelID = settings.endpoints.openAIModels.first?.id
        }
        save()
    }

    func unloadLocalModelComponent(modelID: UUID, component: LocalModelComponent) {
        guard let index = settings.localModels.firstIndex(where: { $0.id == modelID }) else { return }
        if component == .llm, loadedLocalModelID == modelID {
            loadedLocalModelID = nil
        }
        if component == .llm, loadingLocalModelID == modelID {
            loadingLocalModelID = nil
        }
        switch component {
        case .llm:
            removeFileIfNeeded(settings.localModels[index].llmLocalPath)
            settings.localModels[index].llmLocalPath = nil
        case .mmproj:
            removeFileIfNeeded(settings.localModels[index].mmprojLocalPath)
            settings.localModels[index].mmprojLocalPath = nil
        }
        save()
    }

    func updateLocalModelComponent(modelID: UUID, component: LocalModelComponent, path: String, fileName: String, size: Int64?) {
        guard let index = settings.localModels.firstIndex(where: { $0.id == modelID }) else { return }
        switch component {
        case .llm:
            settings.localModels[index].llmLocalPath = path
            settings.localModels[index].llmFileName = fileName
            settings.localModels[index].llmSize = size
        case .mmproj:
            settings.localModels[index].mmprojLocalPath = path
            settings.localModels[index].mmprojFileName = fileName
            settings.localModels[index].mmprojSize = size
        }
        save()
    }

    func previewTTS() async {
        guard !isPreviewingTTS else { return }
        if settings.tts.engine == .mossLocal, !TTSService.mossCacheExists() {
            statusText = "请先下载完整的 MOSS TTS 权重"
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            statusText = ""
            return
        }
        isPreviewingTTS = true
        statusText = "TTS 试听中..."
        let shouldReleaseMossRuntime = settings.tts.engine == .mossLocal
        defer {
            isPreviewingTTS = false
            statusText = ""
        }
        let previewText = settings.tts.previewText.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackPreviewText = TTSSettings.defaultPreviewText(forPresetVoice: settings.tts.presetVoice)
        await ttsService.speak(previewText.isEmpty ? fallbackPreviewText : previewText, settings: effectiveTTSSettings(), waitUntilFinished: true)
        if shouldReleaseMossRuntime {
            await ttsService.unloadMossRuntimeMemory()
        }
    }

    func effectiveTTSSettings() -> TTSSettings {
        var tts = settings.tts
        guard tts.engine == .mossLocal else {
            return tts
        }
        if tts.voiceMode == .clone,
           let selectedID = tts.selectedCloneVoiceID,
           let voice = settings.clonedVoices.first(where: { $0.id == selectedID }) {
            tts.referenceText = voice.referenceText
            tts.referenceAudioPath = voice.referenceAudioPath
            tts.voice = "clone:\(voice.id.uuidString)"
        } else {
            tts.referenceAudioPath = nil
            tts.referenceText = ""
            tts.voice = tts.presetVoice
        }
        return tts
    }

    func addClonedVoice(name: String, referenceText: String, audioPath: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let voice = ClonedVoiceProfile(
            name: trimmedName.isEmpty ? "克隆音色 \(settings.clonedVoices.count + 1)" : trimmedName,
            referenceText: referenceText.trimmingCharacters(in: .whitespacesAndNewlines),
            referenceAudioPath: audioPath
        )
        settings.clonedVoices.insert(voice, at: 0)
        settings.tts.voiceMode = .clone
        settings.tts.selectedCloneVoiceID = voice.id
        save()
    }

    func updateClonedVoice(_ voice: ClonedVoiceProfile, removeOldAudioPath: String?) {
        if let removeOldAudioPath, removeOldAudioPath != voice.referenceAudioPath {
            removeFileIfNeeded(removeOldAudioPath)
        }
        if let index = settings.clonedVoices.firstIndex(where: { $0.id == voice.id }) {
            settings.clonedVoices[index] = voice
        }
        save()
    }

    func deleteClonedVoice(_ voice: ClonedVoiceProfile) {
        removeFileIfNeeded(voice.referenceAudioPath)
        settings.clonedVoices.removeAll { $0.id == voice.id }
        if settings.tts.selectedCloneVoiceID == voice.id {
            settings.tts.selectedCloneVoiceID = settings.clonedVoices.first?.id
            if settings.tts.selectedCloneVoiceID == nil {
                settings.tts.voiceMode = .preset
            }
        }
        save()
    }

    func unloadMossTTSWeights() {
        ttsService.unloadMossLocalWeights()
        statusText = "MOSS TTS 权重缓存已卸载"
    }

    private func prewarmMossOnLaunch() async {
        guard TTSService.mossCacheExists() else { return }
        await ttsService.prewarmMoss(settings: effectiveTTSSettings())
    }

    func stopTTS() {
        isPreviewingTTS = false
        ttsSpeechTask?.cancel()
        ttsSpeechTask = nil
        ttsService.stopSpeaking()
    }

    func send(text: String, attachments: [ChatAttachment]) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        guard let index = currentConversationIndex() else { return }

        let userMessage = ChatMessage(role: .user, text: trimmed, attachments: attachments)
        conversations[index].messages.append(userMessage)
        conversations[index].updatedAt = Date()
        if conversations[index].title == "新的对话" {
            conversations[index].title = trimmed.isEmpty ? "多模态对话" : String(trimmed.prefix(18))
        }

        let assistant = ChatMessage(role: .assistant, text: "")
        conversations[index].messages.append(assistant)
        let assistantID = assistant.id
        save()

        isGenerating = true
        statusText = "模型请求中..."
        defer {
            isGenerating = false
            statusText = ""
            save()
        }

        await generateAssistantResponse(conversationIndex: index, assistantID: assistantID, latest: userMessage)
    }

    func resendEditedUserMessage(messageID: UUID, text: String, attachments: [ChatAttachment]) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        guard let conversationIndex = currentConversationIndex(),
              let messageIndex = conversations[conversationIndex].messages.firstIndex(where: { $0.id == messageID }),
              conversations[conversationIndex].messages[messageIndex].role == .user
        else {
            return
        }

        conversations[conversationIndex].messages[messageIndex].text = trimmed
        conversations[conversationIndex].messages[messageIndex].attachments = attachments
        conversations[conversationIndex].messages.removeSubrange(conversations[conversationIndex].messages.index(after: messageIndex)..<conversations[conversationIndex].messages.endIndex)
        conversations[conversationIndex].updatedAt = Date()
        let latest = conversations[conversationIndex].messages[messageIndex]

        let assistant = ChatMessage(role: .assistant, text: "")
        conversations[conversationIndex].messages.append(assistant)
        let assistantID = assistant.id
        save()

        isGenerating = true
        statusText = "重新生成中..."
        defer {
            isGenerating = false
            statusText = ""
            save()
        }

        await generateAssistantResponse(conversationIndex: conversationIndex, assistantID: assistantID, latest: latest)
    }

    private func generateAssistantResponse(conversationIndex index: Int, assistantID: UUID, latest: ChatMessage) async {
        do {
            stopTTS()
            validateLocalModels()
            if settings.tts.engine == .mossLocal {
                await ttsService.prewarmMoss(settings: effectiveTTSSettings())
            }
            let history = requestMessages(for: conversations[index], latest: latest)
            switch settings.endpoints.backend {
            case .localLlama:
                guard let selected = selectedLocalModel,
                      loadedLocalModelID == selected.id else {
                    appendAssistantText("本地模型未加载。请点右上角模型按钮加载一个 GGUF。", assistantID: assistantID)
                    return
                }
                var response = ""
                var pendingDisplayText = ""
                var lastDisplayFlush = Date.distantPast
                var speechBuffer = ""
                for try await delta in localService.stream(messages: history, settings: settings) {
                    response += delta
                    pendingDisplayText += delta
                    flushStreamTextIfNeeded(&pendingDisplayText, assistantID: assistantID, lastFlush: &lastDisplayFlush)
                    if shouldSpeakTTS, settings.tts.speakWhileStreaming {
                        speechBuffer += delta
                        if let sentence = TTSService.popSpeakableSentence(from: &speechBuffer) {
                            speakInBackground(sentence)
                        }
                    }
                }
                flushStreamText(&pendingDisplayText, assistantID: assistantID, lastFlush: &lastDisplayFlush)
                let cleaned = cleanModelOutput(response)
                if !cleaned.isEmpty, cleaned != response {
                    replaceAssistantText(cleaned, assistantID: assistantID)
                    speechBuffer = ""
                }
                if shouldSpeakTTS {
                    if settings.tts.speakWhileStreaming {
                        if !speechBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            speakInBackground(speechBuffer)
                        }
                    } else {
                        let finalSpeech = cleaned.isEmpty ? response : cleaned
                        if !finalSpeech.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            await ttsService.speak(finalSpeech, settings: effectiveTTSSettings())
                        }
                    }
                }
            case .openAICompatible, .remoteOpenAI, .lanOpenAI:
                guard selectedOpenAIModel != nil else {
                    appendAssistantText("还没有配置 OpenAI 兼容模型。请到模型页添加 Base URL、API Key 和模型名。", assistantID: assistantID)
                    return
                }
                var response = ""
                var pendingDisplayText = ""
                var lastDisplayFlush = Date.distantPast
                var speechBuffer = ""
                for try await delta in chatService.stream(messages: history, settings: settings) {
                    response += delta
                    pendingDisplayText += delta
                    flushStreamTextIfNeeded(&pendingDisplayText, assistantID: assistantID, lastFlush: &lastDisplayFlush)
                    if shouldSpeakTTS, settings.tts.speakWhileStreaming {
                        speechBuffer += delta
                        if let sentence = TTSService.popSpeakableSentence(from: &speechBuffer) {
                            speakInBackground(sentence)
                        }
                    }
                }
                flushStreamText(&pendingDisplayText, assistantID: assistantID, lastFlush: &lastDisplayFlush)
                if shouldSpeakTTS {
                    if settings.tts.speakWhileStreaming {
                        if !speechBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            speakInBackground(speechBuffer)
                        }
                    } else if !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        await ttsService.speak(response, settings: effectiveTTSSettings())
                    }
                }
            }
        } catch {
            appendAssistantText("\n\n请求失败：\(error.localizedDescription)", assistantID: assistantID)
        }
    }

    private func speakInBackground(_ text: String) {
        guard shouldSpeakTTS else { return }
        let ttsSettings = effectiveTTSSettings()
        let previousTask = ttsSpeechTask
        ttsSpeechTask = Task { [ttsService] in
            await previousTask?.value
            guard !Task.isCancelled else { return }
            await ttsService.speak(text, settings: ttsSettings, waitUntilFinished: true)
        }
    }

    private var shouldSpeakTTS: Bool {
        isTTSEnabled && settings.tts.engine != .off
    }

    private func flushStreamTextIfNeeded(_ buffer: inout String, assistantID: UUID, lastFlush: inout Date) {
        guard !buffer.isEmpty else { return }
        let now = Date()
        guard now.timeIntervalSince(lastFlush) >= streamUIFlushInterval else { return }
        flushStreamText(&buffer, assistantID: assistantID, lastFlush: &lastFlush, now: now)
    }

    private func flushStreamText(_ buffer: inout String, assistantID: UUID, lastFlush: inout Date, now: Date = Date()) {
        guard !buffer.isEmpty else { return }
        appendAssistantText(buffer, assistantID: assistantID)
        buffer = ""
        lastFlush = now
    }

    private func currentConversationIndex() -> Int? {
        guard let selectedConversationID else { return nil }
        return conversations.firstIndex { $0.id == selectedConversationID }
    }

    private func appendAssistantText(_ text: String, assistantID: UUID) {
        guard let conversationIndex = currentConversationIndex(),
              let messageIndex = conversations[conversationIndex].messages.firstIndex(where: { $0.id == assistantID }) else {
            return
        }
        conversations[conversationIndex].messages[messageIndex].text += text
        conversations[conversationIndex].updatedAt = Date()
    }

    private func replaceAssistantText(_ text: String, assistantID: UUID) {
        guard let conversationIndex = currentConversationIndex(),
              let messageIndex = conversations[conversationIndex].messages.firstIndex(where: { $0.id == assistantID }) else {
            return
        }
        conversations[conversationIndex].messages[messageIndex].text = text
        conversations[conversationIndex].updatedAt = Date()
    }

    private func requestMessages(for conversation: Conversation, latest: ChatMessage) -> [ChatMessage] {
        var result: [ChatMessage] = []
        let system = (conversation.systemPrompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !system.isEmpty {
            result.append(ChatMessage(role: .system, text: system))
        }

        let turnLimit = max(settings.generation.contextTurns, 0)
        let retained = turnLimit == 0 ? [] : Array(conversation.messages.suffix(turnLimit * 2 + 1))
        result.append(contentsOf: retained.filter { !$0.text.isEmpty || !$0.attachments.isEmpty })
        if result.last?.id != latest.id, !result.contains(where: { $0.id == latest.id }) {
            result.append(latest)
        }
        return result
    }

    private func removeFileIfNeeded(_ path: String?) {
        guard let path, !path.isEmpty else { return }
        try? FileManager.default.removeItem(atPath: path)
    }
}

enum Persistence {
    static func directory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("OmniPersona", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func modelDirectory(for repoID: String) -> URL {
        let safeName = repoID
            .replacingOccurrences(of: "/", with: "--")
            .replacingOccurrences(of: ":", with: "-")
        return directory()
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(safeName, isDirectory: true)
    }

    static func load<T: Decodable>(_ name: String) -> T? {
        let url = directory().appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, to name: String) {
        let url = directory().appendingPathComponent(name)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    static func removeAll() {
        try? FileManager.default.removeItem(at: directory())
    }
}

private struct AppInstallState: Codable {
    var fingerprint: String
}
