import Foundation
import Testing
@testable import GrsaiCanvasApp

/// 记录请求并按顺序返回预设结果的测试传输层。
private actor StubTransport: HTTPTransport {
    private var responses: [Result<HTTPTransportResponse, Error>]
    private var requests: [URLRequest] = []

    /// 创建预设响应队列。
    init(_ responses: [Result<HTTPTransportResponse, Error>]) {
        self.responses = responses
    }

    /// 保存请求并消费一条预设响应。
    func send(_ request: URLRequest) async throws -> HTTPTransportResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        return try responses.removeFirst().get()
    }

    /// 返回最后一次收到的请求。
    func lastRequest() -> URLRequest? {
        requests.last
    }
}

@Suite("Grsai API 客户端")
struct GrsaiAPIClientTests {
    /// 生成一个不含参考图的最小合法输入。
    private func draft() -> GenerationDraft {
        GenerationDraft(
            prompt: " 一只猫 ",
            model: .gptImage2,
            aspectRatio: .square,
            imageSize: nil,
            referenceImages: []
        )
    }

    /// 生成 HTTP 测试响应。
    private func response(_ json: String, status: Int = 200) -> HTTPTransportResponse {
        HTTPTransportResponse(data: Data(json.utf8), statusCode: status, headers: [:])
    }

    @Test("提交携带鉴权和异步请求体")
    func submitBuildsExpectedRequest() async throws {
        let transport = StubTransport([
            .success(response(#"{"id":"task-1","status":"running","progress":10}"#))
        ])
        let client = try GrsaiAPIClient(
            baseURL: URL(string: "https://example.test")!,
            transport: transport
        )

        let result = try await client.submit(draft: draft(), apiKey: " test-token ")
        let request = try #require(await transport.lastRequest())
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])

        #expect(result.id == "task-1")
        #expect(request.url?.absoluteString == "https://example.test/v1/api/generate")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        #expect(json["prompt"] as? String == "一只猫")
        #expect(json["replyType"] as? String == "async")
    }

    /// 验证 minimax-h3 请求体使用视频字段和异步响应。
    @Test("提交 minimax-h3 视频请求")
    func submitBuildsVideoRequest() async throws {
        let transport = StubTransport([
            .success(response(#"{"id":"video-1","status":"running","progress":4}"#))
        ])
        let client = try GrsaiAPIClient(
            baseURL: URL(string: "https://example.test")!,
            transport: transport
        )
        let draft = GenerationDraft(
            prompt: "湖面镜头",
            model: .minimaxH3,
            aspectRatio: .landscape,
            imageSize: nil,
            referenceImages: [],
            referenceAudios: ["https://audio.example/ref.mp3"],
            videoResolution: .p768,
            videoDuration: 6,
            videoSeed: 7
        )

        _ = try await client.submit(draft: draft, apiKey: "test-token")
        let body = try #require(await transport.lastRequest()?.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])

        #expect(json["model"] as? String == "minimax-h3")
        #expect(json["aspectRatio"] as? String == "landscape")
        #expect(json["resolution"] as? String == "768p")
        #expect(json["duration"] as? Int == 6)
        #expect(json["seed"] as? Int == 7)
        #expect((json["audios"] as? [String]) == ["https://audio.example/ref.mp3"])
    }

    @Test("查询只复用已有任务 ID")
    func resultUsesExistingTaskID() async throws {
        let transport = StubTransport([
            .success(response(#"{"id":"task-2","status":"succeeded","results":[{"url":"https://images.example/result.png"}]}"#))
        ])
        let client = try GrsaiAPIClient(
            baseURL: URL(string: "https://example.test")!,
            transport: transport
        )

        let result = try await client.result(taskID: "task-2", apiKey: "test-token")
        let request = try #require(await transport.lastRequest())

        #expect(result.status == .succeeded)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://example.test/v1/api/result?id=task-2")
    }

    @Test("提交超时标记接收状态未知且不泄露令牌")
    func submitTimeoutIsAcceptanceUnknown() async throws {
        let transport = StubTransport([.failure(URLError(.timedOut))])
        let client = try GrsaiAPIClient(
            baseURL: URL(string: "https://example.test")!,
            transport: transport
        )

        do {
            _ = try await client.submit(draft: draft(), apiKey: "test-private-token")
            Issue.record("预期提交失败")
        } catch let error as GrsaiClientError {
            guard case .requestFailed(let code, let phase, let retryable, let acceptanceUnknown, _) = error else {
                Issue.record("错误类型不正确")
                return
            }
            #expect(code == "REQUEST_TIMEOUT")
            #expect(phase == "submit")
            #expect(retryable)
            #expect(acceptanceUnknown)
            #expect(!String(describing: error).contains("test-private-token"))
        }
    }

    @Test("拒绝非 HTTPS 节点和结果地址")
    func rejectsInsecureURLs() async throws {
        #expect(throws: GrsaiClientError.self) {
            _ = try GrsaiAPIClient(baseURL: URL(string: "http://example.test")!)
        }

        let transport = StubTransport([
            .success(response(#"{"id":"task-3","status":"succeeded","results":[{"url":"http://images.example/result.png"}]}"#))
        ])
        let client = try GrsaiAPIClient(
            baseURL: URL(string: "https://example.test")!,
            transport: transport
        )
        await #expect(throws: GrsaiClientError.self) {
            _ = try await client.result(taskID: "task-3", apiKey: "test-token")
        }
    }
}
