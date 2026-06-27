import Foundation

struct LocalLlamaService {
    func generate(messages: [ChatMessage], settings: AppSettings) async throws -> String {
        var result = ""
        for try await delta in stream(messages: messages, settings: settings) {
            result += delta
        }
        return cleanModelOutput(result)
    }

    func stream(messages: [ChatMessage], settings: AppSettings) -> AsyncThrowingStream<String, Error> {
#if !OMNIPERSONA_ENABLE_LLAMA_BRIDGE
        return singleDeltaStream("当前构建未启用本地 llama.cpp bridge。请运行脚本生成并接入 iOS XCFramework，或切换到 OpenAI 兼容接口。")
#else
        guard let selected = settings.localModels.first(where: { $0.isSelected }),
              let localPath = selected.llmLocalPath,
              FileManager.default.fileExists(atPath: localPath) else {
            return singleDeltaStream("本地 llama.cpp 模型尚未加载。请先在模型管理中下载或导入 GGUF，并安装上游 iOS XCFramework。")
        }
        let imagePaths = messages.flatMap { message in
            message.attachments
                .filter { $0.kind == .image && FileManager.default.fileExists(atPath: $0.localPath) }
                .map(\.localPath)
        }
        let hasUnsupportedAttachments = messages.contains { message in
            message.attachments.contains { $0.kind != .image }
        }
        if hasUnsupportedAttachments {
            return singleDeltaStream("本地 llama.cpp 当前只默认接入图片 mtmd 推理，视频附件请先切换到远程或 Wi-Fi 内网 OpenAI 兼容多模态接口。")
        }
        if !imagePaths.isEmpty,
           !(selected.mmprojLocalPath?.isEmpty == false && FileManager.default.fileExists(atPath: selected.mmprojLocalPath ?? "")) {
            return singleDeltaStream("当前本地模型只有 LLM GGUF，没有下载 mmproj GGUF，因此只能文本推理。请在模型详情里下载 mmproj 后再传图片。")
        }

        let payload = buildTemplateMessages(messages: messages)
        return AsyncThrowingStream { continuation in
            Task.detached(priority: .userInitiated) {
                var error: NSError?
                let bridge = OPLlamaBridge()
                let result: String
                if !imagePaths.isEmpty, let mmprojPath = selected.mmprojLocalPath {
                    result = bridge.generate(
                        withModelPath: localPath,
                        mmprojPath: mmprojPath,
                        messages: payload,
                        imagePaths: imagePaths,
                        seed: 0,
                        temperature: Float(settings.generation.temperature),
                        topP: Float(settings.generation.topP),
                        maxTokens: Int32(settings.generation.maxTokens),
                        nCtx: Int32(settings.generation.localContextSize),
                        nThreads: Int32(settings.generation.localThreadCount),
                        nGpuLayers: Int32(settings.generation.localGPULayers),
                        nBatch: Int32(settings.generation.localBatchSize),
                        nUBatch: Int32(settings.generation.localMicroBatchSize),
                        enableThinking: settings.generation.enableThinking,
                        tokenHandler: { token in
                            continuation.yield(token)
                        },
                        error: &error
                    )
                } else {
                    result = bridge.generate(
                        withModelPath: localPath,
                        messages: payload,
                        seed: 0,
                        temperature: Float(settings.generation.temperature),
                        topP: Float(settings.generation.topP),
                        maxTokens: Int32(settings.generation.maxTokens),
                        nCtx: Int32(settings.generation.localContextSize),
                        nThreads: Int32(settings.generation.localThreadCount),
                        nGpuLayers: Int32(settings.generation.localGPULayers),
                        nBatch: Int32(settings.generation.localBatchSize),
                        nUBatch: Int32(settings.generation.localMicroBatchSize),
                        enableThinking: settings.generation.enableThinking,
                        tokenHandler: { token in
                            continuation.yield(token)
                        },
                        error: &error
                    )
                }
                if let error {
                    continuation.finish(throwing: error)
                    return
                }
                let cleaned = cleanModelOutput(result)
                if cleaned.isEmpty, !result.isEmpty {
                    continuation.yield(cleaned)
                }
                continuation.finish()
            }
        }
#endif
    }

    private func singleDeltaStream(_ text: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(text)
            continuation.finish()
        }
    }

    private func buildTemplateMessages(messages: [ChatMessage]) -> [[String: String]] {
        return messages.compactMap { message in
            let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty || !message.attachments.isEmpty else { return nil }
            var content = trimmed
            let imageCount = message.attachments.filter { $0.kind == .image }.count
            if imageCount > 0 {
                let markers = Array(repeating: "<__media__>", count: imageCount).joined(separator: "\n")
                content = content.isEmpty ? "\(markers)\n请分析图片内容。" : "\(markers)\n\(content)"
            }
            return [
                "role": message.role.rawValue,
                "content": content
            ]
        }
    }
}

func cleanModelOutput(_ text: String) -> String {
    var result = text
        .replacingOccurrences(of: "<|im_end|>", with: "")
        .replacingOccurrences(of: "<|endoftext|>", with: "")
        .replacingOccurrences(of: "</s>", with: "")

    while let start = result.range(of: "<think>") {
        if let end = result.range(of: "</think>", range: start.upperBound..<result.endIndex) {
            result.removeSubrange(start.lowerBound..<end.upperBound)
        } else {
            result.removeSubrange(start.lowerBound..<result.endIndex)
            break
        }
    }

    let stopMarkers = [
        "\nUser:", "\n用户:", "\n用户：",
        "\nAssistant:", "\n助手:", "\n助手：",
        "User:", "用户:", "用户：",
        "Assistant:", "助手:", "助手："
    ]
    if let stop = stopMarkers.compactMap({ result.range(of: $0)?.lowerBound }).min() {
        result = String(result[..<stop])
    }

    let rolePrefixes = ["Assistant:", "助手:", "助手："]
    for prefix in rolePrefixes where result.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(prefix) {
        if let range = result.range(of: prefix) {
            result.removeSubrange(range)
        }
        break
    }

    return result.trimmingCharacters(in: .whitespacesAndNewlines)
}
