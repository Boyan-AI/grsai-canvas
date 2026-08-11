import Foundation

/// 对接 Grsai 原生异步生图接口的安全客户端。
actor GrsaiAPIClient {
    private struct SubmitPayload: Encodable {
        let model: String
        let prompt: String
        let replyType = "async"
        let images: [String]?
        let aspectRatio: String
        let imageSize: String?
    }

    private struct ResponsePayload: Decodable {
        struct ResultPayload: Decodable {
            let url: String
        }

        let id: String?
        let status: String?
        let progress: Int?
        let results: [ResultPayload]?
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
            aspectRatio: validatedDraft.aspectRatio.rawValue,
            imageSize: validatedDraft.imageSize?.rawValue
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
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(requestID.uuidString, forHTTPHeaderField: "X-Request-ID")
        return request
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
        return GenerationResponse(id: id, status: status, progress: payload.progress, results: outputs)
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
