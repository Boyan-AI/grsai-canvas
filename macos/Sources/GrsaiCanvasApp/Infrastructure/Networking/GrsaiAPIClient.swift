import Foundation

/// OpenAI Chat 消息，图片以 data URL 形式附加到当前消息。
struct GrsaiChatMessage: Sendable {
    let role: String
    let content: String
    let imageDataURLs: [String]

    init(role: String = "user", content: String, imageDataURLs: [String] = []) {
        self.role = role
        self.content = content
        self.imageDataURLs = imageDataURLs
    }
}

/// Chat 和 Gemini 接口统一使用的文本响应。
struct GrsaiTextResponse: Sendable, Equatable {
    let id: String
    let text: String
}

/// 对接 Grsai 原生异步生图接口的安全客户端。
actor GrsaiAPIClient {
    private struct SubmitPayload: Encodable {
        let model: String
        let prompt: String
        let replyType = "async"
        let images: [String]?
        let aspectRatio: String
        let imageSize: String?
        let audios: [String]?
        let resolution: String?
        let duration: Int?
        let seed: Int?
    }

    private struct ResponsePayload: Decodable {
        struct ResultPayload: Decodable {
            let url: String
        }

        let id: String?
        let status: String?
        let progress: Int?
        let error: String?
        let results: [ResultPayload]?
    }

    private struct OpenAIImagePayload: Encodable {
        let model: String
        let prompt: String
        let n = 1
        let size: String
        let quality: String?
        let background: String?
    }

    private let baseURL: URL
    private let transport: any HTTPTransport
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// 使用生产 Grsai 节点创建客户端。
    init(transport: any HTTPTransport = URLSessionTransport()) {
        self.baseURL = URL(string: "https://grsai.dakka.com.cn")!
        self.transport = transport
    }

    /// 创建只允许 HTTPS 节点的 Grsai 客户端。
    init(
        baseURL: URL,
        transport: any HTTPTransport = URLSessionTransport()
    ) throws {
        guard baseURL.scheme?.lowercased() == "https", baseURL.host != nil else {
            throw GrsaiClientError.invalidConfiguration("Grsai 节点必须是有效的 HTTPS 地址")
        }
        self.baseURL = baseURL
        self.transport = transport
    }

    /// 提交一次可能产生费用的原生异步生图任务。
    func submit(
        draft: GenerationDraft,
        apiKey: String,
        requestID: UUID = UUID()
    ) async throws -> GenerationResponse {
        let validatedDraft = try draft.validated()
        let key = try validatedKey(apiKey)
        let payload = SubmitPayload(
            model: validatedDraft.model.rawValue,
            prompt: validatedDraft.prompt,
            images: validatedDraft.referenceImages.isEmpty ? nil : validatedDraft.referenceImages.map(\.dataURL),
            aspectRatio: validatedDraft.model.isVideo ? validatedDraft.model.videoAspectRatioValue(validatedDraft.aspectRatio) : validatedDraft.aspectRatio.rawValue,
            imageSize: validatedDraft.imageSize?.rawValue,
            audios: validatedDraft.referenceAudios.isEmpty ? nil : validatedDraft.referenceAudios,
            resolution: validatedDraft.videoResolution?.rawValue,
            duration: validatedDraft.videoDuration,
            seed: validatedDraft.videoSeed
        )
        let request = try makeRequest(
            path: "/v1/api/generate",
            method: "POST",
            apiKey: key,
            requestID: requestID,
            body: encoder.encode(payload),
            timeout: 120
        )
        do {
            let response = try await transport.send(request)
            return try parse(response, phase: "submit", acceptanceUnknown: false)
        } catch let error as GrsaiClientError {
            throw error
        } catch {
            throw mapTransportError(error, phase: "submit", acceptanceUnknown: true)
        }
    }

    /// 查询既有任务，不创建新的计费任务。
    func result(
        taskID: String,
        apiKey: String,
        requestID: UUID = UUID()
    ) async throws -> GenerationResponse {
        guard !taskID.isEmpty, taskID.count <= 200 else {
            throw GrsaiClientError.invalidInput("任务 ID 无效")
        }
        let key = try validatedKey(apiKey)
        var components = URLComponents()
        components.path = "/v1/api/result"
        components.queryItems = [URLQueryItem(name: "id", value: taskID)]
        guard let relativeURL = components.url else {
            throw GrsaiClientError.invalidInput("任务 ID 无法编码")
        }
        let request = try makeRequest(
            path: relativeURL.absoluteString,
            method: "GET",
            apiKey: key,
            requestID: requestID,
            body: nil,
            timeout: 30
        )
        do {
            let response = try await transport.send(request)
            return try parse(response, phase: "poll", acceptanceUnknown: false)
        } catch let error as GrsaiClientError {
            throw error
        } catch {
            throw mapTransportError(error, phase: "poll", acceptanceUnknown: false)
        }
    }

    /// 调用 OpenAI 兼容图片生成接口，并转换为统一图片结果。
    func openAIImage(
        prompt: String,
        model: String,
        size: String = "1024x1024",
        quality: String? = nil,
        background: String? = nil,
        apiKey: String,
        requestID: UUID = UUID()
    ) async throws -> GenerationResponse {
        let key = try validatedKey(apiKey)
        let trimmedPrompt = try validatedPrompt(prompt)
        let payload = OpenAIImagePayload(
            model: model,
            prompt: trimmedPrompt,
            size: size,
            quality: quality,
            background: background
        )
        let request = try makeRequest(
            path: "/v1/images/generations",
            method: "POST",
            apiKey: key,
            requestID: requestID,
            body: try encoder.encode(payload),
            contentType: "application/json",
            timeout: 180
        )
        do {
            return try parseSynchronousImages(try await transport.send(request), phase: "openai-image")
        } catch let error as GrsaiClientError {
            throw error
        } catch {
            throw mapTransportError(error, phase: "openai-image", acceptanceUnknown: true)
        }
    }

    /// 调用 OpenAI 兼容图片编辑 multipart 接口。
    func editImage(
        prompt: String,
        model: String,
        imageData: Data,
        imageFileName: String = "image.png",
        imageMimeType: String = "image/png",
        quality: String? = nil,
        background: String? = nil,
        maskData: Data? = nil,
        apiKey: String,
        requestID: UUID = UUID()
    ) async throws -> GenerationResponse {
        let key = try validatedKey(apiKey)
        let trimmedPrompt = try validatedPrompt(prompt)
        let boundary = "Boundary-\(UUID().uuidString)"
        var multipart = Data()
        appendField("model", value: model, boundary: boundary, to: &multipart)
        appendField("prompt", value: trimmedPrompt, boundary: boundary, to: &multipart)
        if let quality { appendField("quality", value: quality, boundary: boundary, to: &multipart) }
        if let background { appendField("background", value: background, boundary: boundary, to: &multipart) }
        appendFile("image", fileName: imageFileName, mimeType: imageMimeType, data: imageData, boundary: boundary, to: &multipart)
        if let maskData {
            appendFile("mask", fileName: "mask.png", mimeType: "image/png", data: maskData, boundary: boundary, to: &multipart)
        }
        multipart.append(Data("--\(boundary)--\r\n".utf8))
        let request = try makeRequest(
            path: "/v1/images/edits",
            method: "POST",
            apiKey: key,
            requestID: requestID,
            body: multipart,
            contentType: "multipart/form-data; boundary=\(boundary)",
            timeout: 180
        )
        do {
            return try parseSynchronousImages(try await transport.send(request), phase: "image-edit")
        } catch let error as GrsaiClientError {
            throw error
        } catch {
            throw mapTransportError(error, phase: "image-edit", acceptanceUnknown: true)
        }
    }

    /// 调用 OpenAI Chat，流式模式在本地合并 SSE 增量文本。
    func chatCompletion(
        model: String,
        messages: [GrsaiChatMessage],
        stream: Bool,
        apiKey: String,
        requestID: UUID = UUID()
    ) async throws -> GrsaiTextResponse {
        let key = try validatedKey(apiKey)
        let messagePayload = messages.map { message in
            if message.imageDataURLs.isEmpty {
                return ["role": message.role, "content": message.content] as [String: Any]
            }
            var content: [[String: Any]] = [["type": "text", "text": message.content]]
            content += message.imageDataURLs.map { ["type": "image_url", "image_url": ["url": $0]] }
            return ["role": message.role, "content": content] as [String: Any]
        }
        let payload: [String: Any] = ["model": model, "messages": messagePayload, "stream": stream]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let request = try makeRequest(path: "/v1/chat/completions", method: "POST", apiKey: key, requestID: requestID, body: body, contentType: "application/json", timeout: 180)
        do {
            let response = try await transport.send(request)
            try validateStatus(response, phase: "chat", acceptanceUnknown: true)
            let text = stream ? parseSSEText(response.data, kind: .chat) : parseChatText(response.data)
            guard !text.isEmpty else { throw GrsaiClientError.invalidResponse }
            return GrsaiTextResponse(id: responseID(response.data, prefix: "chat"), text: text)
        } catch let error as GrsaiClientError {
            throw error
        } catch {
            throw mapTransportError(error, phase: "chat", acceptanceUnknown: true)
        }
    }

    /// 调用 Gemini generateContent 或 streamGenerateContent 接口。
    func geminiContent(
        model: String,
        prompt: String,
        referenceImageDataURLs: [String] = [],
        generationConfigJSON: String = "{}",
        stream: Bool,
        apiKey: String,
        requestID: UUID = UUID()
    ) async throws -> GrsaiTextResponse {
        let key = try validatedKey(apiKey)
        let trimmedPrompt = try validatedPrompt(prompt)
        var parts: [[String: Any]] = [["text": trimmedPrompt]]
        parts += referenceImageDataURLs.compactMap(Self.inlineImagePart)
        let contents: [[String: Any]] = [["role": "user", "parts": parts]]
        var payload: [String: Any] = ["contents": contents]
        if let config = try? JSONSerialization.jsonObject(with: Data(generationConfigJSON.utf8)) as? [String: Any], !config.isEmpty {
            payload["generationConfig"] = config
        }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let endpoint = stream ? "streamGenerateContent" : "generateContent"
        let request = try makeRequest(path: "/v1beta/models/\(model):\(endpoint)", method: "POST", apiKey: key, requestID: requestID, body: body, contentType: "application/json", timeout: 180)
        do {
            let response = try await transport.send(request)
            try validateStatus(response, phase: stream ? "gemini-stream" : "gemini", acceptanceUnknown: true)
            let text = stream ? parseSSEText(response.data, kind: .gemini) : parseGeminiText(response.data)
            guard !text.isEmpty else { throw GrsaiClientError.invalidResponse }
            return GrsaiTextResponse(id: responseID(response.data, prefix: "gemini"), text: text)
        } catch let error as GrsaiClientError {
            throw error
        } catch {
            throw mapTransportError(error, phase: stream ? "gemini-stream" : "gemini", acceptanceUnknown: true)
        }
    }

    /// 校验密钥但绝不把密钥写入错误文本。
    private func validatedKey(_ apiKey: String) throws -> String {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw GrsaiClientError.missingAPIKey }
        return key
    }

    /// 构造带关联 ID 的标准 JSON 请求。
    private func makeRequest(
        path: String,
        method: String,
        apiKey: String,
        requestID: UUID,
        body: Data?,
        contentType: String = "application/json",
        timeout: TimeInterval
    ) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL), url.scheme == "https" else {
            throw GrsaiClientError.invalidConfiguration("请求地址必须使用 HTTPS")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.httpBody = body
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(requestID.uuidString, forHTTPHeaderField: "X-Request-ID")
        return request
    }

    /// 校验文本输入，避免空请求和异常大请求进入可能计费的接口。
    private func validatedPrompt(_ prompt: String) throws -> String {
        let value = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 32_000 else {
            throw GrsaiClientError.invalidInput("提示词不能为空且最多允许 32000 个字符")
        }
        return value
    }

    /// 校验同步接口状态并复用统一错误模型。
    private func validateStatus(_ response: HTTPTransportResponse, phase: String, acceptanceUnknown: Bool) throws {
        guard (200..<300).contains(response.statusCode) else {
            throw GrsaiClientError.requestFailed(code: "HTTP_ERROR", phase: phase, retryable: response.statusCode == 429 || response.statusCode >= 500, acceptanceUnknown: acceptanceUnknown, statusCode: response.statusCode)
        }
    }

    /// 解析 OpenAI 图片生成和编辑的 data 数组。
    private func parseSynchronousImages(_ response: HTTPTransportResponse, phase: String) throws -> GenerationResponse {
        try validateStatus(response, phase: phase, acceptanceUnknown: true)
        guard let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let items = object["data"] as? [[String: Any]] else { throw GrsaiClientError.invalidResponse }
        let outputs = try items.compactMap { item -> GenerationOutput? in
            guard let raw = item["url"] as? String ?? item["b64_json"] as? String else { return nil }
            if raw.hasPrefix("data:"), let url = URL(string: raw) { return GenerationOutput(url: url) }
            guard let url = URL(string: raw), url.scheme?.lowercased() == "https" else { throw GrsaiClientError.invalidResponse }
            return GenerationOutput(url: url)
        }
        guard !outputs.isEmpty else { throw GrsaiClientError.invalidResponse }
        return GenerationResponse(id: responseID(response.data, prefix: phase), status: .succeeded, progress: 100, results: outputs)
    }

    private enum StreamKind { case chat, gemini }

    /// 解析一次性 Chat 响应中的首个文本候选。
    private func parseChatText(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else { return "" }
        if let text = message["content"] as? String { return text }
        return ""
    }

    /// 解析一次性 Gemini 响应中的所有文本片段。
    private func parseGeminiText(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = object["candidates"] as? [[String: Any]] else { return "" }
        return candidates.compactMap { candidate in
            (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]]
        }.flatMap { $0 }.compactMap { $0["text"] as? String }.joined()
    }

    /// 合并 Chat/Gemini 的 SSE data 行，兼容 JSON 数组和 [DONE] 结束标记。
    private func parseSSEText(_ data: Data, kind: StreamKind) -> String {
        let source = String(decoding: data, as: UTF8.self)
        return source.split(whereSeparator: \.isNewline).compactMap { line in
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.hasPrefix("data:") else { return nil }
            let payload = value.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]", let json = payload.data(using: .utf8) else { return nil }
            switch kind {
            case .chat:
                return parseChatDelta(json)
            case .gemini:
                return parseGeminiText(json)
            }
        }.joined()
    }

    private func parseChatDelta(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (object["choices"] as? [[String: Any]])?.first,
              let delta = choice["delta"] as? [String: Any] else { return "" }
        return delta["content"] as? String ?? ""
    }

    private func responseID(_ data: Data, prefix: String) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let id = object["id"] as? String, !id.isEmpty { return id }
        return "\(prefix)-\(UUID().uuidString)"
    }

    /// 把 data URL 转换成 Gemini inlineData 请求片段。
    private static func inlineImagePart(_ value: String) -> [String: Any]? {
        let pieces = value.split(separator: ",", maxSplits: 1).map(String.init)
        guard pieces.count == 2, pieces[0].hasPrefix("data:"),
              let mime = pieces[0].split(separator: ";").first?.dropFirst(5) else { return nil }
        return ["inlineData": ["mimeType": String(mime), "data": pieces[1]]]
    }

    /// 追加 multipart 文本字段。
    private func appendField(_ name: String, value: String, boundary: String, to data: inout Data) {
        data.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }

    /// 追加 multipart 二进制字段。
    private func appendFile(_ name: String, fileName: String, mimeType: String, data fileData: Data, boundary: String, to data: inout Data) {
        data.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\nContent-Type: \(mimeType)\r\n\r\n".utf8))
        data.append(fileData)
        data.append(Data("\r\n".utf8))
    }

    /// 把上游数据转换为稳定任务模型，并拒绝非 HTTPS 结果地址。
    private func parse(
        _ response: HTTPTransportResponse,
        phase: String,
        acceptanceUnknown: Bool
    ) throws -> GenerationResponse {
        guard (200..<300).contains(response.statusCode) else {
            throw GrsaiClientError.requestFailed(
                code: "HTTP_ERROR",
                phase: phase,
                retryable: response.statusCode == 429 || response.statusCode >= 500,
                acceptanceUnknown: acceptanceUnknown,
                statusCode: response.statusCode
            )
        }
        guard
            let payload = try? decoder.decode(ResponsePayload.self, from: response.data),
            let id = payload.id,
            !id.isEmpty,
            let rawStatus = payload.status,
            let status = GenerationStatus(rawValue: rawStatus)
        else {
            throw GrsaiClientError.invalidResponse
        }
        let outputs = try (payload.results ?? []).map { item -> GenerationOutput in
            guard let url = URL(string: item.url), url.scheme?.lowercased() == "https" else {
                throw GrsaiClientError.invalidResponse
            }
            return GenerationOutput(url: url)
        }
        return GenerationResponse(
            id: id,
            status: status,
            progress: payload.progress,
            results: outputs,
            errorMessage: payload.error.map(Self.friendlyError)
        )
    }

    /// 将服务端错误转换为用户可理解的提示，同时保留未知错误原文便于排查。
    private static func friendlyError(_ error: String) -> String {
        if error.localizedCaseInsensitiveContains("excessive system load") {
            return "服务器当前负载过高，请稍后重新生成"
        }
        return error
    }

    /// 将网络失败映射为不泄露请求内容的阶段化错误。
    private func mapTransportError(
        _ error: Error,
        phase: String,
        acceptanceUnknown: Bool
    ) -> GrsaiClientError {
        let nsError = error as NSError
        let retryableCodes = [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet]
        return .requestFailed(
            code: nsError.code == NSURLErrorTimedOut ? "REQUEST_TIMEOUT" : "NETWORK_ERROR",
            phase: phase,
            retryable: retryableCodes.contains(nsError.code),
            acceptanceUnknown: acceptanceUnknown,
            statusCode: nil
        )
    }
}
