import Foundation

struct OpenAIChatService {
    func stream(messages: [ChatMessage], settings: AppSettings) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let request = try makeRequest(messages: messages, settings: settings)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        throw URLError(.badServerResponse)
                    }

                    for try await line in bytes.lines {
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { continue }
                        if trimmed == "data: [DONE]" || trimmed == "[DONE]" { break }
                        let payload = trimmed.hasPrefix("data: ") ? String(trimmed.dropFirst(6)) : trimmed
                        if let delta = parseDelta(payload), !delta.isEmpty {
                            continuation.yield(delta)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func makeRequest(messages: [ChatMessage], settings: AppSettings) throws -> URLRequest {
        let endpoint = settings.endpoints
        let baseURLString: String
        let apiKey: String
        let model: String
        let sendsThinking: Bool

        switch endpoint.backend {
        case .openAICompatible:
            let selected = endpoint.openAIModels.first { $0.id == endpoint.selectedOpenAIModelID }
                ?? endpoint.openAIModels.first
            baseURLString = selected?.baseURL ?? endpoint.lanBaseURL
            apiKey = selected?.apiKey ?? endpoint.lanAPIKey
            model = selected?.model ?? endpoint.lanModel
            sendsThinking = selected?.sendsThinking ?? true
        case .remoteOpenAI:
            baseURLString = endpoint.remoteBaseURL
            apiKey = endpoint.remoteAPIKey
            model = endpoint.remoteModel
            sendsThinking = false
        case .lanOpenAI:
            baseURLString = endpoint.lanBaseURL
            apiKey = endpoint.lanAPIKey
            model = endpoint.lanModel
            sendsThinking = true
        case .localLlama:
            baseURLString = endpoint.lanBaseURL
            apiKey = endpoint.lanAPIKey
            model = endpoint.lanModel
            sendsThinking = false
        }

        let normalized = baseURLString.hasSuffix("/") ? String(baseURLString.dropLast()) : baseURLString
        let chatURLString = normalized.hasSuffix("/chat/completions")
            ? normalized
            : normalized + "/chat/completions"
        guard let url = URL(string: chatURLString) else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        var body: [String: Any] = [
            "model": model,
            "messages": try messages.map(apiMessage),
            "temperature": settings.generation.temperature,
            "top_p": settings.generation.topP,
            "max_tokens": settings.generation.maxTokens,
            "stream": settings.generation.streamResponse
        ]
        if sendsThinking {
            body["enable_thinking"] = settings.generation.enableThinking
            body["chat_template_kwargs"] = ["enable_thinking": settings.generation.enableThinking]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func apiMessage(_ message: ChatMessage) throws -> [String: Any] {
        if message.attachments.isEmpty {
            return ["role": message.role.rawValue, "content": message.text]
        }

        var content: [[String: Any]] = []
        for attachment in message.attachments {
            switch attachment.kind {
            case .image:
                let dataURL = try dataURL(for: attachment)
                content.append(["type": "image_url", "image_url": ["url": dataURL]])
            case .video:
                let dataURL = try dataURL(for: attachment)
                content.append(["type": "video_url", "video_url": ["url": dataURL]])
            case .audio:
                let dataURL = try dataURL(for: attachment)
                content.append(["type": "input_audio", "input_audio": ["data": dataURL, "format": attachment.mimeType]])
            }
        }
        content.append(["type": "text", "text": message.text.isEmpty ? "请分析附件内容。" : message.text])
        return ["role": message.role.rawValue, "content": content]
    }

    private func dataURL(for attachment: ChatAttachment) throws -> String {
        let url = URL(fileURLWithPath: attachment.localPath)
        let data = try Data(contentsOf: url)
        return "data:\(attachment.mimeType);base64,\(data.base64EncodedString())"
    }

    private func parseDelta(_ payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let first = choices.first else {
            return nil
        }
        if let delta = first["delta"] as? [String: Any], let content = delta["content"] as? String {
            return content
        }
        if let message = first["message"] as? [String: Any], let content = message["content"] as? String {
            return content
        }
        return nil
    }
}
