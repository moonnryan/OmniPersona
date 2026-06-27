import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showAdvancedGeneration = false
    @State private var showLocalLlamaAdvanced = false
    @State private var mossCacheExists = TTSService.mossCacheExists()
    @State private var mossIsDownloading = false
    @State private var mossProgress = 0.0
    @State private var mossMessage = ""
    @State private var confirmMossUnload = false
    @State private var showAudioImporter = false
    @State private var cloneName = ""
    @State private var cloneReferenceText = ""
    @State private var cloneAudioPath: String?
    @State private var editingCloneVoice: ClonedVoiceProfile?

    var body: some View {
        Form {
            Section("模型接口") {
                Picker("后端", selection: $store.settings.endpoints.backend) {
                    ForEach(ChatBackend.pickerOrder) { backend in
                        Text(backend.title).tag(backend)
                    }
                }
                endpointFields
            }

            Section("推理") {
                Toggle("启用思考模式", isOn: $store.settings.generation.enableThinking)
                DisclosureGroup("参数", isExpanded: $showAdvancedGeneration) {
                    SliderRow(title: "Temperature", value: $store.settings.generation.temperature, range: 0...2)
                    SliderRow(title: "Top P", value: $store.settings.generation.topP, range: 0...1)
                    Stepper("Max tokens: \(store.settings.generation.maxTokens)", value: $store.settings.generation.maxTokens, in: 128...8192, step: 128)
                    Stepper("多轮记忆: \(store.settings.generation.contextTurns)", value: $store.settings.generation.contextTurns, in: 0...30)
                }
            }

            Section("TTS") {
                Picker("引擎", selection: $store.settings.tts.engine) {
                    ForEach(TTSEngineKind.pickerOrder) { engine in
                        Text(engine.title).tag(engine)
                    }
                }

                if store.settings.tts.engine != .off {
                    if store.settings.tts.engine == .system {
                        Picker("系统音色", selection: $store.settings.tts.systemVoiceIdentifier) {
                            Text("自动匹配语言").tag("")
                            ForEach(SystemVoiceCatalog.options) { voice in
                                Text(voice.title).tag(voice.id)
                            }
                        }
                    }
                    Toggle("分句朗读", isOn: $store.settings.tts.speakWhileStreaming)
                    if store.settings.tts.engine == .mossLocal {
                        Picker("音色来源", selection: $store.settings.tts.voiceMode) {
                            ForEach(TTSVoiceMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        voiceControls
                        DisclosureGroup("MOSS 高级参数") {
                            IntSliderRow(
                                title: "Max New Frames",
                                value: $store.settings.tts.mossMaxNewFrames,
                                range: 96...900,
                                step: 25
                            )
                            IntSliderRow(
                                title: "Clone Text Tokens",
                                value: $store.settings.tts.mossVoiceCloneMaxTextTokens,
                                range: 24...240,
                                step: 1
                            )
                            SliderRow(title: "Temperature", value: $store.settings.tts.mossTemperature, range: 0...1.5)
                            SliderRow(title: "Top P", value: $store.settings.tts.mossTopP, range: 0.05...1)
                            Stepper("Top K: \(store.settings.tts.mossTopK)", value: $store.settings.tts.mossTopK, in: 0...200, step: 5)
                            SliderRow(title: "Repetition penalty", value: $store.settings.tts.mossRepetitionPenalty, range: 0.8...2)
                            Text("当前 MOSS Nano Swift 实现没有 batched codec decode，所以 TTS/Codec batch 先不展示。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    SliderRow(title: "语速", value: $store.settings.tts.speed, range: 0.5...2)
                    TextField("试听文本", text: $store.settings.tts.previewText, axis: .vertical)
                        .lineLimit(2...4)
                    Button {
                        Task { await store.previewTTS() }
                    } label: {
                        Label(store.isPreviewingTTS ? "试听中" : "试听当前音色", systemImage: store.isPreviewingTTS ? "hourglass" : "play.circle")
                    }
                    .disabled(store.isPreviewingTTS)
                }

                if store.settings.tts.engine == .remote {
                    TextField("接口 URL", text: $store.settings.tts.remoteURL)
                        .textInputAutocapitalization(.never)
                    TextField("TTS API Key", text: $store.settings.tts.remoteAPIKey)
                        .textInputAutocapitalization(.never)
                    TextField("Speaker（可选）", text: remoteSpeakerBinding)
                        .textInputAutocapitalization(.never)
                }

                if store.settings.tts.engine == .mossLocal {
                    mossDownloadControls
                }

                if store.settings.tts.engine == .mossLocal {
                    voiceManagementControls
                    savedCloneVoices
                }
            }
        }
        .navigationTitle("设置")
        .scrollDismissesKeyboard(.interactively)
        .background(KeyboardDismissGestureInstaller())
        .fileImporter(isPresented: $showAudioImporter, allowedContentTypes: [.audio], allowsMultipleSelection: false) { result in
            importCloneAudio(result)
        }
        .sheet(item: $editingCloneVoice) { voice in
            CloneVoiceEditorSheet(voice: voice) { updated, oldAudioPath in
                store.updateClonedVoice(updated, removeOldAudioPath: oldAudioPath)
            }
        }
        .onChange(of: store.settings) {
            store.save()
            refreshMossCacheState()
        }
        .onChange(of: store.settings.tts.presetVoice) {
            updatePreviewTextIfUsingDefault(language: TTSPresetVoices.language(for: store.settings.tts.presetVoice))
        }
        .onChange(of: store.settings.tts.systemVoiceIdentifier) {
            guard let identifier = store.settings.tts.systemVoiceIdentifier.nilIfEmpty,
                  let voice = AVSpeechSynthesisVoice(identifier: identifier)
            else { return }
            updatePreviewTextIfUsingDefault(language: voice.language.languagePrefix)
        }
        .onAppear {
            refreshMossCacheState()
        }
    }

    @ViewBuilder
    private var voiceControls: some View {
        switch store.settings.tts.voiceMode {
        case .preset:
            Picker("预设音色", selection: $store.settings.tts.presetVoice) {
                ForEach(TTSPresetVoices.all) { voice in
                    Text(voice.title).tag(voice.id)
                }
            }
        case .clone:
            if store.settings.clonedVoices.isEmpty {
                Text("还没有克隆音色。先在下方音色管理中导入参考音频并保存。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("克隆音色", selection: $store.settings.tts.selectedCloneVoiceID) {
                    ForEach(store.settings.clonedVoices) { voice in
                        Text(voice.name).tag(Optional(voice.id))
                    }
                }
            }
        }
    }

    private var mossDownloadControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(mossCacheExists ? "权重已下载" : "权重未下载", systemImage: mossCacheExists ? "checkmark.circle.fill" : "icloud.and.arrow.down")
                .foregroundStyle(mossCacheExists ? .green : .secondary)

            if mossIsDownloading {
                ProgressView(value: mossProgress)
                Text(mossMessage.isEmpty ? "正在下载..." : mossMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if mossCacheExists {
                if confirmMossUnload {
                    HStack(spacing: 10) {
                        Button(role: .destructive) {
                            store.unloadMossTTSWeights()
                            confirmMossUnload = false
                            refreshMossCacheState()
                        } label: {
                            Label("确认卸载", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                        }
                        Button {
                            confirmMossUnload = false
                        } label: {
                            Text("取消")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button(role: .destructive) {
                        confirmMossUnload = true
                    } label: {
                        Label("卸载 MOSS TTS 权重", systemImage: "trash")
                    }
                }
            } else {
                Button {
                    Task { await downloadMossWeights() }
                } label: {
                    Label("下载 MOSS TTS 权重", systemImage: "arrow.down.circle")
                }
            }
        }
    }

    @ViewBuilder
    private var voiceManagementControls: some View {
        Text("音色管理")
            .font(.subheadline.weight(.semibold))
            .listRowSeparator(.hidden)

        TextField("克隆音色名称", text: $cloneName)

        TextField("参考音频文本", text: $cloneReferenceText, prompt: Text("建议填写参考音频中实际说的话"), axis: .vertical)
            .lineLimit(2...5)

        if let cloneAudioPath {
            HStack(spacing: 10) {
                Label((cloneAudioPath as NSString).lastPathComponent, systemImage: "waveform")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button {
                    clearCloneAudioSelection()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("取消参考音频")
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .listRowSeparator(.hidden)
        }

        HStack(spacing: 10) {
            Button {
                showAudioImporter = true
            } label: {
                Label("选择参考音频", systemImage: "waveform")
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(.primary)
            }

            Button {
                if let cloneAudioPath {
                    store.addClonedVoice(name: cloneName, referenceText: cloneReferenceText, audioPath: cloneAudioPath)
                    cloneName = ""
                    cloneReferenceText = ""
                    self.cloneAudioPath = nil
                }
            } label: {
                Label("保存克隆音色", systemImage: "tray.and.arrow.down")
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(.primary)
            }
            .disabled(cloneAudioPath == nil)
        }
        .buttonStyle(.bordered)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        .listRowSeparator(.hidden)
    }

    private var savedCloneVoices: some View {
        Group {
            if store.settings.clonedVoices.isEmpty {
                Text("未保存克隆音色。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(store.settings.clonedVoices) { voice in
                    Button {
                        editingCloneVoice = voice
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(voice.name)
                                Text((voice.referenceAudioPath as NSString).lastPathComponent)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if store.settings.tts.selectedCloneVoiceID == voice.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button(role: .destructive) {
                            store.deleteClonedVoice(voice)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                    .listRowSeparator(.hidden)
                }
            }
        }
    }

    @ViewBuilder
    private var endpointFields: some View {
        switch store.settings.endpoints.backend {
        case .openAICompatible, .remoteOpenAI, .lanOpenAI:
            Text("在模型页维护 OpenAI 兼容接口，可添加多个 Base URL / API Key / 模型名配置。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .listRowSeparator(.hidden)
        case .localLlama:
            Text("默认使用本地 llama.cpp。请在模型页下载并选择一个 GGUF。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .listRowSeparator(.hidden)
            DisclosureGroup("本地 llama.cpp 进阶参数", isExpanded: $showLocalLlamaAdvanced) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("上下文窗口")
                        Spacer()
                        TextField("8192", value: $store.settings.generation.localContextSize, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 96)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(store.settings.generation.localContextSize) },
                            set: { store.settings.generation.localContextSize = Int($0) }
                        ),
                        in: 512...32768,
                        step: 512
                    )
                }
                Stepper("线程数: \(store.settings.generation.localThreadCount)", value: $store.settings.generation.localThreadCount, in: 1...8)
                Stepper("GPU layers: \(store.settings.generation.localGPULayers)", value: $store.settings.generation.localGPULayers, in: 0...99)
                Stepper("batch: \(store.settings.generation.localBatchSize)", value: $store.settings.generation.localBatchSize, in: 32...1024, step: 32)
                Stepper("micro-batch: \(store.settings.generation.localMicroBatchSize)", value: $store.settings.generation.localMicroBatchSize, in: 16...1024, step: 16)
                Text("上下文越大，KV cache 占用越高；大模型、图片 mmproj 和高上下文叠加时可能触发系统内存回收。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func downloadMossWeights() async {
        mossIsDownloading = true
        mossProgress = 0
        mossMessage = "准备下载..."
        do {
            try await TTSService.downloadMossWeights { progress in
                mossProgress = progress.fractionCompleted.isFinite ? progress.fractionCompleted : 0
                mossMessage = "\(Int(mossProgress * 100))%"
            }
            mossMessage = "下载完成"
        } catch {
            mossMessage = "下载失败：\(error.localizedDescription)"
        }
        mossIsDownloading = false
        refreshMossCacheState()
    }

    private func importCloneAudio(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let source = urls.first else { return }
        let accessed = source.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                source.stopAccessingSecurityScopedResource()
            }
        }
        let ext = source.pathExtension.isEmpty ? "m4a" : source.pathExtension
        let destination = Persistence.directory().appendingPathComponent("voice-\(UUID().uuidString).\(ext)")
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
            clearCloneAudioSelection()
            cloneAudioPath = destination.path
        } catch {
            mossMessage = "参考音频导入失败：\(error.localizedDescription)"
        }
    }

    private func clearCloneAudioSelection() {
        if let cloneAudioPath {
            try? FileManager.default.removeItem(atPath: cloneAudioPath)
        }
        cloneAudioPath = nil
    }

    private func refreshMossCacheState() {
        mossCacheExists = TTSService.mossCacheExists()
    }

    private func updatePreviewTextIfUsingDefault(language: String) {
        let trimmed = store.settings.tts.previewText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty || TTSSettings.isDefaultPreviewText(trimmed) else { return }
        store.settings.tts.previewText = TTSSettings.defaultPreviewText(forLanguage: language)
    }

    private var remoteSpeakerBinding: Binding<String> {
        Binding {
            let voice = store.settings.tts.voice.trimmingCharacters(in: .whitespacesAndNewlines)
            if voice.isEmpty || TTSPresetVoices.all.contains(where: { $0.id == voice }) || voice.hasPrefix("clone:") {
                return ""
            }
            return voice
        } set: { value in
            store.settings.tts.voice = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

private struct CloneVoiceEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ClonedVoiceProfile
    @State private var originalAudioPath: String
    @State private var replacementAudioPath: String?
    @State private var showAudioImporter = false
    @State private var player: AVAudioPlayer?
    @State private var errorMessage = ""
    let save: (ClonedVoiceProfile, String?) -> Void

    init(voice: ClonedVoiceProfile, save: @escaping (ClonedVoiceProfile, String?) -> Void) {
        self._draft = State(initialValue: voice)
        self._originalAudioPath = State(initialValue: voice.referenceAudioPath)
        self.save = save
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("克隆音色") {
                    TextField("名称", text: $draft.name)
                    TextField("参考音频文本", text: $draft.referenceText, axis: .vertical)
                        .lineLimit(2...5)
                }

                Section("参考音频") {
                    HStack(spacing: 10) {
                        Label((draft.referenceAudioPath as NSString).lastPathComponent, systemImage: "waveform")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Button {
                            previewAudio()
                        } label: {
                            Label("预览", systemImage: "play.circle")
                        }
                        .buttonStyle(.bordered)
                    }

                    Button {
                        showAudioImporter = true
                    } label: {
                        Label("替换 wav", systemImage: "waveform")
                    }

                    if !errorMessage.isEmpty {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("编辑克隆音色")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        discardReplacementIfNeeded()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        draft.name = normalizedName
                        draft.referenceText = draft.referenceText.trimmingCharacters(in: .whitespacesAndNewlines)
                        save(draft, replacementAudioPath == nil ? nil : originalAudioPath)
                        dismiss()
                    }
                }
            }
            .fileImporter(isPresented: $showAudioImporter, allowedContentTypes: [.audio], allowsMultipleSelection: false) { result in
                importReplacementAudio(result)
            }
            .onDisappear {
                player?.stop()
            }
        }
    }

    private var normalizedName: String {
        let trimmed = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "克隆音色" : trimmed
    }

    private func previewAudio() {
        do {
            player?.stop()
            let player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: draft.referenceAudioPath))
            self.player = player
            player.prepareToPlay()
            player.play()
            errorMessage = ""
        } catch {
            errorMessage = "预览失败：\(error.localizedDescription)"
        }
    }

    private func importReplacementAudio(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let source = urls.first else { return }
        let accessed = source.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                source.stopAccessingSecurityScopedResource()
            }
        }
        let ext = source.pathExtension.isEmpty ? "wav" : source.pathExtension
        let destination = Persistence.directory().appendingPathComponent("voice-\(UUID().uuidString).\(ext)")
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
            discardReplacementIfNeeded()
            replacementAudioPath = destination.path
            draft.referenceAudioPath = destination.path
            errorMessage = ""
        } catch {
            errorMessage = "音频导入失败：\(error.localizedDescription)"
        }
    }

    private func discardReplacementIfNeeded() {
        if let replacementAudioPath {
            try? FileManager.default.removeItem(atPath: replacementAudioPath)
        }
        replacementAudioPath = nil
    }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading) {
            Text("\(title): \(value, specifier: "%.2f")")
            Slider(value: $value, in: range)
        }
    }
}

private struct IntSliderRow: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value)")
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: {
                        let stepped = Int(($0 / Double(step)).rounded()) * step
                        value = min(range.upperBound, max(range.lowerBound, stepped))
                    }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: Double(step)
            )
        }
    }
}

private struct SystemVoiceOption: Identifiable {
    let id: String
    let title: String
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

    var languagePrefix: String {
        split(separator: "-").first.map(String.init) ?? self
    }
}

private struct KeyboardDismissGestureInstaller: UIViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        DispatchQueue.main.async {
            context.coordinator.install(from: view)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.install(from: uiView)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private weak var recognizer: UITapGestureRecognizer?

        func install(from view: UIView) {
            guard recognizer == nil, let window = view.window else { return }
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            window.addGestureRecognizer(recognizer)
            self.recognizer = recognizer
        }

        @objc private func dismissKeyboard() {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }

        deinit {
            let recognizer = recognizer
            DispatchQueue.main.async {
                if let recognizer {
                    recognizer.view?.removeGestureRecognizer(recognizer)
                }
            }
        }
    }
}

private enum SystemVoiceCatalog {
    static var options: [SystemVoiceOption] {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        return preferredSlots.compactMap { slot in
            guard let voice = bestVoice(for: slot, in: voices) else { return nil }
            return SystemVoiceOption(
                id: voice.identifier,
                title: "\(slot.title) · \(voice.name)\(qualitySuffix(voice.quality))"
            )
        }
    }

    private static let preferredSlots: [VoiceSlot] = [
        VoiceSlot(title: "中文女声", language: "zh-CN", gender: .female),
        VoiceSlot(title: "中文男声", language: "zh-CN", gender: .male),
        VoiceSlot(title: "English Female", language: "en-US", gender: .female),
        VoiceSlot(title: "English Male", language: "en-US", gender: .male),
        VoiceSlot(title: "日本語女声", language: "ja-JP", gender: .female),
        VoiceSlot(title: "日本語男声", language: "ja-JP", gender: .male)
    ]

    private static let excludedVoiceNames: Set<String> = [
        "Albert", "Bad News", "Bahh", "Bells", "Boing", "Bubbles", "Cellos", "Eddy",
        "Flo", "Fred", "Good News", "Grandma", "Grandpa", "Jester", "Junior", "Kathy",
        "Organ", "Reed", "Ralph", "Rocko", "Sandy", "Shelley", "Superstar", "Trinoids",
        "Whisper", "Wobble", "Zarvox"
    ]

    private static func bestVoice(for slot: VoiceSlot, in voices: [AVSpeechSynthesisVoice]) -> AVSpeechSynthesisVoice? {
        let languageVoices = voices.filter { $0.language == slot.language && !excludedVoiceNames.contains($0.name) }
        let genderMatched = languageVoices.filter { $0.gender == slot.gender }
        let candidates = genderMatched.isEmpty ? languageVoices : genderMatched
        return candidates.max { score($0, for: slot) < score($1, for: slot) }
    }

    private static func score(_ voice: AVSpeechSynthesisVoice, for slot: VoiceSlot) -> Int {
        var value = 0
        let searchable = "\(voice.name) \(voice.identifier)".lowercased()
        if searchable.contains("siri") {
            value += 1_000
        }
        if voice.gender == slot.gender {
            value += 300
        }
        switch voice.quality {
        case .premium:
            value += 220
        case .enhanced:
            value += 160
        default:
            break
        }
        if voice.identifier.localizedCaseInsensitiveContains(slot.language) {
            value += 20
        }
        return value
    }

    private static func qualitySuffix(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .enhanced: return " · enhanced"
        case .premium: return " · premium"
        default: return ""
        }
    }

    private struct VoiceSlot {
        let title: String
        let language: String
        let gender: AVSpeechSynthesisVoiceGender
    }
}
