import Foundation

struct HuggingFaceFile: Identifiable, Hashable {
    var id: String { path }
    var path: String
    var size: Int64?
    var source: ModelHubSource = .hfMirror

    var displayName: String {
        (path as NSString).lastPathComponent
    }

    var isMMProj: Bool {
        let lower = path.lowercased()
        return lower.contains("mmproj") || lower.contains("projector")
    }
}

enum ModelHubSource: String, Hashable {
    case hfMirror
    case modelScope

    var listRevision: String {
        switch self {
        case .hfMirror: return "main"
        case .modelScope: return "master"
        }
    }

    func listURL(repoID: String, hfEndpoint: String) -> URL? {
        switch self {
        case .hfMirror:
            return URL(string: "\(hfEndpoint)/api/models/\(repoID)/tree/main?recursive=true")
        case .modelScope:
            return URL(string: "https://modelscope.cn/api/v1/models/\(repoID)/repo/files?Revision=\(listRevision)&Recursive=true")
        }
    }

    func downloadURL(repoID: String, filePath: String, hfEndpoint: String) -> URL? {
        let encodedFile = filePath
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        switch self {
        case .hfMirror:
            return URL(string: "\(hfEndpoint)/\(repoID)/resolve/main/\(encodedFile)")
        case .modelScope:
            return URL(string: "https://modelscope.cn/models/\(repoID)/resolve/master/\(encodedFile)")
        }
    }
}

struct ModelDownloadPlan: Identifiable, Hashable {
    var id: String { repoID }
    var repoID: String
    var llm: HuggingFaceFile
    var mmproj: HuggingFaceFile?
    var llmOptions: [HuggingFaceFile] = []
    var mmprojOptions: [HuggingFaceFile] = []

    var totalSize: Int64? {
        guard let llmSize = llm.size else { return nil }
        return llmSize + (mmproj?.size ?? 0)
    }
}

enum LocalModelComponent: Equatable {
    case llm
    case mmproj
}

struct ModelHubService {
    static let defaultRepoID = "unsloth/Qwen3.5-0.8B-GGUF"

    var hfEndpoint = "https://hf-mirror.com"

    func listGGUFFiles(repoID: String) async throws -> [HuggingFaceFile] {
        var lastError: Error?
        for source in [ModelHubSource.modelScope, .hfMirror] {
            do {
                let files = try await listGGUFFiles(repoID: repoID, source: source)
                if !files.isEmpty {
                    return files
                }
            } catch {
                lastError = error
            }
        }
        if let lastError {
            throw lastError
        }
        return []
    }

    private func listGGUFFiles(repoID: String, source: ModelHubSource) async throws -> [HuggingFaceFile] {
        guard let url = source.listURL(repoID: repoID, hfEndpoint: hfEndpoint) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let object = try JSONSerialization.jsonObject(with: data)
        let array: [[String: Any]]
        switch source {
        case .hfMirror:
            array = object as? [[String: Any]] ?? []
        case .modelScope:
            let root = object as? [String: Any]
            let data = root?["Data"] as? [String: Any]
            array = data?["Files"] as? [[String: Any]] ?? []
        }
        return array.compactMap { item in
            let path = (item["path"] as? String) ?? (item["Path"] as? String)
            guard let path, path.lowercased().hasSuffix(".gguf") else { return nil }
            let size = int64Value(item["size"] ?? item["Size"])
            return HuggingFaceFile(path: path, size: size, source: source)
        }
        .sorted { lhs, rhs in
            score(lhs.path) > score(rhs.path)
        }
    }

    func downloadPlan(repoID: String) async throws -> ModelDownloadPlan {
        let files = try await listGGUFFiles(repoID: repoID)
        let llmOptions = files.filter { !$0.isMMProj }
        let mmprojOptions = files.filter { $0.isMMProj }
        guard let llm = llmOptions.first else {
            throw NSError(domain: "ModelHubService", code: 1, userInfo: [NSLocalizedDescriptionKey: "没有找到主体 llm GGUF。"])
        }
        return ModelDownloadPlan(
            repoID: repoID,
            llm: llm,
            mmproj: mmprojOptions.first,
            llmOptions: llmOptions,
            mmprojOptions: mmprojOptions
        )
    }

    func downloadPlan(repoID: String, llmPath: String?, mmprojPath: String?) async throws -> ModelDownloadPlan {
        let base = try await downloadPlan(repoID: repoID)
        let llm = llmPath.flatMap { path in base.llmOptions.first { $0.path == path } } ?? base.llm
        let mmproj = mmprojPath.flatMap { path in base.mmprojOptions.first { $0.path == path } } ?? base.mmproj
        return ModelDownloadPlan(
            repoID: repoID,
            llm: llm,
            mmproj: mmproj,
            llmOptions: base.llmOptions,
            mmprojOptions: base.mmprojOptions
        )
    }

    func downloadURL(repoID: String, filePath: String) -> URL? {
        ModelHubSource.hfMirror.downloadURL(repoID: repoID, filePath: filePath, hfEndpoint: hfEndpoint)
    }

    func download(file: HuggingFaceFile, repoID: String, progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        guard let sourceURL = file.source.downloadURL(repoID: repoID, filePath: file.path, hfEndpoint: hfEndpoint) else {
            throw URLError(.badURL)
        }
        let (bytes, response) = try await URLSession.shared.bytes(from: sourceURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let directory = Persistence.modelDirectory(for: repoID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(file.displayName)
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("omnipersona-\(UUID().uuidString)-\(file.displayName)")
        FileManager.default.createFile(atPath: temporaryURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temporaryURL)
        defer {
            try? FileManager.default.removeItem(at: temporaryURL)
        }

        let expectedBytes = file.size ?? http.expectedContentLength
        var receivedBytes: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(256 * 1024)
        for try await byte in bytes {
            buffer.append(byte)
            receivedBytes += 1
            if buffer.count >= 256 * 1024 {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
                if expectedBytes > 0 {
                    progress?(min(1, max(0, Double(receivedBytes) / Double(expectedBytes))))
                }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
        }
        try handle.close()
        progress?(1)

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    private func score(_ name: String) -> Int {
        let lower = name.lowercased()
        if lower.contains("mmproj") || lower.contains("projector") { return 10 }
        if lower.contains("q4_k_m") { return 100 }
        if lower.contains("q4_0") { return 90 }
        if lower.contains("q5") { return 80 }
        if lower.contains("q3") { return 70 }
        return 50
    }

    private func int64Value(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? Double { return Int64(value) }
        if let value = value as? String { return Int64(value) }
        return nil
    }
}

@MainActor
final class ModelDownloadController: ObservableObject {
    @Published var repoID = ModelHubService.defaultRepoID
    @Published var plan: ModelDownloadPlan?
    @Published var selectedLLMPath = ""
    @Published var selectedMMProjPath = ""
    @Published var isLoading = false
    @Published var isDownloading = false
    @Published var downloadProgress = 0.0
    @Published var activeDownloadName = ""
    @Published var message = ""

    var downloadPercentText: String {
        "\(Int(downloadProgress * 100))%"
    }

    private let service = ModelHubService()

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let resolved = try await service.downloadPlan(repoID: repoID)
            selectedLLMPath = resolved.llm.path
            selectedMMProjPath = resolved.mmproj?.path ?? ""
            plan = resolved
            let total = resolved.totalSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "未知大小"
            message = resolved.mmproj == nil ? "已选择主体 GGUF，未发现 mmproj，将只提供文本能力。总大小：\(total)" : "已选择主体 GGUF + mmproj。总大小：\(total)"
        } catch {
            plan = nil
            message = "解析失败：\(error.localizedDescription)"
        }
    }

    func selectPlanFiles(llmPath: String? = nil, mmprojPath: String? = nil) {
        guard let current = plan else { return }
        if let llmPath {
            selectedLLMPath = llmPath
        }
        if let mmprojPath {
            selectedMMProjPath = mmprojPath
        }
        let llm = current.llmOptions.first { $0.path == selectedLLMPath } ?? current.llm
        let mmproj = selectedMMProjPath.isEmpty ? nil : current.mmprojOptions.first { $0.path == selectedMMProjPath }
        plan = ModelDownloadPlan(
            repoID: current.repoID,
            llm: llm,
            mmproj: mmproj,
            llmOptions: current.llmOptions,
            mmprojOptions: current.mmprojOptions
        )
        let total = plan?.totalSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "未知大小"
        message = plan?.mmproj == nil ? "将下载 llm，仅文本能力。总大小：\(total)" : "将下载 llm + mmproj。总大小：\(total)"
    }

    func downloadResolvedPlan() async throws -> LocalModel {
        guard let plan else {
            throw NSError(domain: "ModelDownloadController", code: 1, userInfo: [NSLocalizedDescriptionKey: "请先解析 repo。"])
        }
        isDownloading = true
        downloadProgress = 0
        defer {
            isDownloading = false
            activeDownloadName = ""
            downloadProgress = 0
        }

        message = "正在下载主体 GGUF..."
        activeDownloadName = plan.llm.displayName
        let llmURL = try await service.download(file: plan.llm, repoID: plan.repoID) { [weak self] value in
            Task { @MainActor in self?.downloadProgress = value }
        }
        var model = LocalModel(
            repoID: plan.repoID,
            llmFileName: plan.llm.displayName,
            llmLocalPath: llmURL.path,
            llmSize: plan.llm.size
        )

        if let mmproj = plan.mmproj {
            message = "正在下载 mmproj..."
            activeDownloadName = mmproj.displayName
            downloadProgress = 0
            let mmprojURL = try await service.download(file: mmproj, repoID: plan.repoID) { [weak self] value in
                Task { @MainActor in self?.downloadProgress = value }
            }
            model.mmprojFileName = mmproj.displayName
            model.mmprojLocalPath = mmprojURL.path
            model.mmprojSize = mmproj.size
        }

        message = "下载完成。"
        return model
    }

    func download(component: LocalModelComponent, for model: LocalModel) async throws -> URL {
        isDownloading = true
        downloadProgress = 0
        defer {
            isDownloading = false
            activeDownloadName = ""
            downloadProgress = 0
        }

        let resolved = try await service.downloadPlan(
            repoID: model.repoID,
            llmPath: selectedLLMPath.isEmpty ? nil : selectedLLMPath,
            mmprojPath: selectedMMProjPath.isEmpty ? nil : selectedMMProjPath
        )
        switch component {
        case .llm:
            message = "正在重新下载主体 GGUF..."
            activeDownloadName = resolved.llm.displayName
            return try await service.download(file: resolved.llm, repoID: model.repoID) { [weak self] value in
                Task { @MainActor in self?.downloadProgress = value }
            }
        case .mmproj:
            guard let mmproj = resolved.mmproj else {
                throw NSError(domain: "ModelDownloadController", code: 2, userInfo: [NSLocalizedDescriptionKey: "这个 repo 没有可用的 mmproj。"])
            }
            message = "正在重新下载 mmproj..."
            activeDownloadName = mmproj.displayName
            return try await service.download(file: mmproj, repoID: model.repoID) { [weak self] value in
                Task { @MainActor in self?.downloadProgress = value }
            }
        }
    }
}
