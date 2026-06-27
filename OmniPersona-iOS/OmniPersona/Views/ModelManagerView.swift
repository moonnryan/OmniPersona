import SwiftUI

struct ModelManagerView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        ModelManagerContent(controller: store.modelDownloadController)
            .environmentObject(store)
    }
}

private struct ModelManagerContent: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var controller: ModelDownloadController
    @State private var editingOpenAIModel: OpenAIModelConfig?

    var body: some View {
        List {
            Section {
                if store.settings.localModels.isEmpty {
                    ContentUnavailableView("还没有本地模型", systemImage: "externaldrive.badge.plus", description: Text("在下方输入 repo id 后下载到设备。"))
                } else {
                    ForEach(store.settings.localModels) { model in
                        NavigationLink(value: model.id) {
                            LocalModelRow(model: model)
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                withAnimation(.snappy(duration: 0.18)) {
                                    store.deleteLocalModel(model)
                                }
                            } label: {
                                Label("卸载", systemImage: "trash")
                            }
                        }
                    }
                }
            } header: {
                CardEdgeSectionHeader("本地模型")
            }

            Section {
                TextField("Repo ID", text: $controller.repoID)
                    .textInputAutocapitalization(.never)
                    .textContentType(.URL)

                HStack {
                    Button {
                        Task { await controller.refresh() }
                    } label: {
                        Label("解析可下载文件", systemImage: "magnifyingglass")
                    }
                    .disabled(controller.isLoading || controller.isDownloading)

                    Spacer()
                    if controller.isLoading {
                        ProgressView()
                    }
                }

                if let plan = controller.plan {
                    if let existing = store.settings.localModels.first(where: { $0.repoID == plan.repoID }) {
                        ExistingModelNotice(model: existing)
                    }
                    DownloadPlanSelectionRow(
                        plan: plan,
                        selectedLLMPath: Binding(
                            get: { controller.selectedLLMPath },
                            set: { controller.selectPlanFiles(llmPath: $0) }
                        ),
                        selectedMMProjPath: Binding(
                            get: { controller.selectedMMProjPath },
                            set: { controller.selectPlanFiles(mmprojPath: $0) }
                        )
                    )
                    Button {
                        Task { await downloadResolvedPlan() }
                    } label: {
                        Label(downloadButtonTitle(for: plan), systemImage: "arrow.down.circle")
                    }
                    .disabled(controller.isDownloading)
                }

                if controller.isDownloading {
                    DownloadProgressRow(controller: controller)
                }
                if !controller.message.isEmpty {
                    Text(controller.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                CardEdgeSectionHeader("下载模型")
            }

            Section {
                if store.settings.endpoints.openAIModels.isEmpty {
                    ContentUnavailableView("还没有接口模型", systemImage: "network", description: Text("添加 Base URL、API Key 和模型名后可在聊天中使用。"))
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(store.settings.endpoints.openAIModels) { model in
                        HStack(spacing: 12) {
                            Button {
                                editingOpenAIModel = model
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(model.displayTitle)
                                        .font(.headline)
                                    Text(model.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            .buttonStyle(.plain)

                            Spacer()

                            Button {
                                store.selectOpenAIModel(model.id)
                            } label: {
                                Image(systemName: store.settings.endpoints.selectedOpenAIModelID == model.id ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(store.settings.endpoints.selectedOpenAIModelID == model.id ? Color.accentColor : Color.secondary)
                                    .font(.title3)
                            }
                            .buttonStyle(.plain)
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                store.deleteOpenAIModel(model)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }

                Button {
                    editingOpenAIModel = OpenAIModelConfig(
                        name: "",
                        baseURL: "http://192.168.31.11:1234/v1",
                        apiKey: "",
                        model: "",
                        sendsThinking: true
                    )
                } label: {
                    Label("添加接口模型", systemImage: "plus.circle")
                }
            } header: {
                CardEdgeSectionHeader("OpenAI 兼容模型")
            }
        }
        .navigationTitle("模型")
        .navigationDestination(for: UUID.self) { id in
            ModelDetailView(modelID: id, controller: store.modelDetailDownloadController)
                .environmentObject(store)
        }
        .sheet(item: $editingOpenAIModel) { model in
            OpenAIModelEditorSheet(model: model) { updated in
                store.upsertOpenAIModel(updated)
            }
        }
        .onAppear {
            store.validateLocalModels()
        }
        .animation(.snappy(duration: 0.18), value: store.settings.localModels)
    }

    private func downloadResolvedPlan() async {
        do {
            let model = try await controller.downloadResolvedPlan()
            store.upsertLocalModel(model)
            store.showNotification("模型下载完成：\(model.repoID)")
        } catch {
            controller.message = "下载失败：\(error.localizedDescription)"
            store.showNotification("模型下载失败")
        }
    }

    private func downloadButtonTitle(for plan: ModelDownloadPlan) -> String {
        var total: Int64 = 0
        var hasSize = false
        if let llmSize = plan.llmOptions.first(where: { $0.path == controller.selectedLLMPath })?.size ?? plan.llm.size {
            total += llmSize
            hasSize = true
        }
        if let mmprojSize = plan.mmprojOptions.first(where: { $0.path == controller.selectedMMProjPath })?.size {
            total += mmprojSize
            hasSize = true
        }
        return hasSize ? "总大小：\(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))" : "下载这一套"
    }

}

private struct CardEdgeSectionHeader: View {
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

private struct OpenAIModelEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: OpenAIModelConfig
    let save: (OpenAIModelConfig) -> Void

    init(model: OpenAIModelConfig, save: @escaping (OpenAIModelConfig) -> Void) {
        self._draft = State(initialValue: model)
        self.save = save
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("接口模型") {
                    TextField("Base URL", text: $draft.baseURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    TextField("API Key", text: $draft.apiKey)
                        .textInputAutocapitalization(.never)
                    TextField("模型名", text: $draft.model)
                        .textInputAutocapitalization(.never)
                }
            }
            .navigationTitle(draft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "添加接口模型" : "编辑接口模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        draft.baseURL = draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                        draft.apiKey = draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        draft.model = draft.model.trimmingCharacters(in: .whitespacesAndNewlines)
                        save(draft)
                        dismiss()
                    }
                    .disabled(draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }
}

private struct ExistingModelNotice: View {
    let model: LocalModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("这个 repo 已在本机记录中", systemImage: "checkmark.circle")
                .font(.subheadline)
            if let llm = model.llmFileName, model.hasTextModel {
                Text("当前 llm：\(llm)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let mmproj = model.mmprojFileName, model.hasVisionProjector {
                Text("当前 mmproj：\(mmproj)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct DownloadProgressRow: View {
    @ObservedObject var controller: ModelDownloadController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                ProgressView(value: controller.downloadProgress)
                Text(controller.downloadPercentText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
            }
            Text(controller.activeDownloadName.isEmpty ? "正在下载..." : controller.activeDownloadName)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }
}

private struct DownloadPlanSelectionRow: View {
    let plan: ModelDownloadPlan
    @Binding var selectedLLMPath: String
    @Binding var selectedMMProjPath: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(plan.repoID)
                .font(.headline)
                .lineLimit(2)

            DownloadFilePickerRow(
                title: "llm",
                files: plan.llmOptions,
                selectedPath: $selectedLLMPath,
                selectedFile: selectedLLMFile ?? plan.llm
            )

            if !plan.mmprojOptions.isEmpty {
                DownloadFilePickerRow(
                    title: "mmproj",
                    files: plan.mmprojOptions,
                    selectedPath: $selectedMMProjPath,
                    selectedFile: selectedMMProjFile,
                    allowsNone: true,
                    noneTitle: "不下载，仅文本能力"
                )
            } else if plan.mmproj == nil {
                Label("未发现 mmproj，仅文本能力", systemImage: "text.bubble")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var selectedLLMFile: HuggingFaceFile? {
        plan.llmOptions.first { $0.path == selectedLLMPath }
    }

    private var selectedMMProjFile: HuggingFaceFile? {
        plan.mmprojOptions.first { $0.path == selectedMMProjPath }
    }

}

private struct DownloadFilePickerRow: View {
    let title: String
    let files: [HuggingFaceFile]
    @Binding var selectedPath: String
    let selectedFile: HuggingFaceFile?
    var allowsNone = false
    var noneTitle = "不下载"

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 58, alignment: .leading)

            Menu {
                if allowsNone {
                    Button(noneTitle) {
                        selectedPath = ""
                    }
                }
                ForEach(files) { file in
                    Button(file.displayName) {
                        selectedPath = file.path
                    }
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(selectedFile?.displayName ?? noneTitle)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Text(sizeText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var sizeText: String {
        guard let size = selectedFile?.size else {
            return selectedFile == nil ? "不下载" : "大小未知"
        }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

private struct LocalModelRow: View {
    let model: LocalModel

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.repoID)
                    .font(.headline)
                    .lineLimit(2)
                Text(model.capabilityTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct ModelDetailView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var controller: ModelDownloadController
    let modelID: UUID
    @State private var pendingReplacement: PendingModelReplacement?

    init(modelID: UUID, controller: ModelDownloadController) {
        self.modelID = modelID
        self._controller = ObservedObject(wrappedValue: controller)
    }

    private var model: LocalModel? {
        store.settings.localModels.first { $0.id == modelID }
    }

    var body: some View {
        List {
            if let model {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.repoID)
                            .font(.headline)
                        Text(model.capabilityTitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        withAnimation(.snappy(duration: 0.18)) {
                            store.toggleLocalModelLoaded(model)
                        }
                    } label: {
                        Label(
                            store.loadedLocalModelID == model.id ? "offload 模型" : "加载这个模型",
                            systemImage: store.loadedLocalModelID == model.id ? "eject" : "bolt"
                        )
                    }
                }

                Section("llm") {
                    ModelComponentDetailRow(
                        title: "llm",
                        currentFileName: model.llmFileName,
                        replacementFiles: controller.plan?.llmOptions ?? [],
                        selectedPath: Binding(
                            get: { controller.selectedLLMPath },
                            set: { path in prepareReplacement(.llm, path: path, model: model) }
                        ),
                        path: model.llmLocalPath,
                        size: model.llmSize,
                        unloadTitle: "卸载模型",
                        isWorking: controller.isDownloading,
                        unload: { store.unloadLocalModelComponent(modelID: model.id, component: .llm) }
                    )
                    .listRowSeparator(.hidden)
                }

                Section("mmproj") {
                    ModelComponentDetailRow(
                        title: "mmproj",
                        currentFileName: model.mmprojFileName,
                        replacementFiles: controller.plan?.mmprojOptions ?? [],
                        selectedPath: Binding(
                            get: { controller.selectedMMProjPath },
                            set: { path in prepareReplacement(.mmproj, path: path, model: model) }
                        ),
                        path: model.mmprojLocalPath,
                        size: model.mmprojSize,
                        unloadTitle: "卸载模型",
                        isWorking: controller.isDownloading,
                        unload: { store.unloadLocalModelComponent(modelID: model.id, component: .mmproj) }
                    )
                    .listRowSeparator(.hidden)
                }

                if !controller.message.isEmpty {
                    Section {
                        Text(controller.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if controller.isDownloading {
                    Section {
                        DownloadProgressRow(controller: controller)
                    }
                }
            } else {
                ContentUnavailableView("模型已卸载", systemImage: "trash")
            }
        }
        .navigationTitle("模型详情")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: modelID) {
            guard let model else { return }
            controller.repoID = model.repoID
            await controller.refresh()
            alignSelections(with: model)
        }
        .alert("替换模型文件？", isPresented: Binding(
            get: { pendingReplacement != nil },
            set: { if !$0 { pendingReplacement = nil } }
        )) {
            Button("取消", role: .cancel) {
                if let model { alignSelections(with: model) }
            }
            Button("删除旧文件并下载", role: .destructive) {
                guard let model, let pendingReplacement else { return }
                Task { await redownload(pendingReplacement.component, model: model) }
            }
        } message: {
            Text("将替换为 \(pendingReplacement?.fileName ?? "新文件")。旧文件会先卸载。")
        }
    }

    private func prepareReplacement(_ component: LocalModelComponent, path: String, model: LocalModel) {
        switch component {
        case .llm:
            guard path != controller.selectedLLMPath else { return }
            controller.selectPlanFiles(llmPath: path)
        case .mmproj:
            guard path != controller.selectedMMProjPath else { return }
            controller.selectPlanFiles(mmprojPath: path)
        }
        let file = fileForPendingReplacement(component)
        pendingReplacement = PendingModelReplacement(
            component: component,
            fileName: file?.displayName ?? (path as NSString).lastPathComponent
        )
    }

    private func fileForPendingReplacement(_ component: LocalModelComponent) -> HuggingFaceFile? {
        guard let plan = controller.plan else { return nil }
        switch component {
        case .llm:
            return plan.llmOptions.first { $0.path == controller.selectedLLMPath }
        case .mmproj:
            return plan.mmprojOptions.first { $0.path == controller.selectedMMProjPath }
        }
    }

    private func redownload(_ component: LocalModelComponent, model: LocalModel) async {
        do {
            store.unloadLocalModelComponent(modelID: model.id, component: component)
            let url = try await controller.download(component: component, for: model)
            guard let resolved = controller.plan else { return }
            switch component {
            case .llm:
                store.updateLocalModelComponent(modelID: model.id, component: component, path: url.path, fileName: resolved.llm.displayName, size: resolved.llm.size)
            case .mmproj:
                guard let mmproj = resolved.mmproj else { return }
                store.updateLocalModelComponent(modelID: model.id, component: component, path: url.path, fileName: mmproj.displayName, size: mmproj.size)
            }
            store.showNotification("模型文件下载完成")
        } catch {
            controller.message = "操作失败：\(error.localizedDescription)"
            store.showNotification("模型文件下载失败")
        }
    }

    private func alignSelections(with model: LocalModel) {
        if let plan = controller.plan {
            if let fileName = model.llmFileName,
               let match = plan.llmOptions.first(where: { $0.displayName == fileName }) {
                controller.selectPlanFiles(llmPath: match.path)
            }
            if let fileName = model.mmprojFileName,
               let match = plan.mmprojOptions.first(where: { $0.displayName == fileName }) {
                controller.selectPlanFiles(mmprojPath: match.path)
            }
        }
    }
}

private struct ModelComponentDetailRow: View {
    let title: String
    let currentFileName: String?
    let replacementFiles: [HuggingFaceFile]
    @Binding var selectedPath: String
    let path: String?
    let size: Int64?
    let unloadTitle: String
    let isWorking: Bool
    let unload: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if replacementFiles.isEmpty {
                Text(currentFileName ?? "\(title) GGUF")
                    .font(.subheadline)
                    .lineLimit(2)
            } else {
                Menu {
                    ForEach(replacementFiles) { file in
                        Button(file.displayName) {
                            selectedPath = file.path
                        }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Text(currentFileName ?? "选择 \(title) GGUF")
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }

            if let path, !path.isEmpty {
                Label("已下载", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            } else {
                Label("未下载", systemImage: "icloud.and.arrow.down")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            if let size {
                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if path?.isEmpty == false {
                Button(role: .destructive) {
                    unload()
                } label: {
                    Text(unloadTitle)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(isWorking)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct PendingModelReplacement: Identifiable {
    var id = UUID()
    var component: LocalModelComponent
    var fileName: String
}
