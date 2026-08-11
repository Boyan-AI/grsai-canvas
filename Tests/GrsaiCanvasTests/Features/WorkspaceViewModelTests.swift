import Foundation
import Testing
@testable import GrsaiCanvasApp

/// 为工作台按顺序提供提交和查询响应。
private actor WorkspaceTransport: HTTPTransport {
    private var responses: [HTTPTransportResponse]

    /// 创建固定响应队列。
    init(_ responses: [HTTPTransportResponse]) {
        self.responses = responses
    }

    /// 返回下一条响应并阻止额外请求。
    func send(_ request: URLRequest) async throws -> HTTPTransportResponse {
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        return responses.removeFirst()
    }
}

@Suite("工作台任务编排")
@MainActor
struct WorkspaceViewModelTests {
    @Test("提交后持久化任务 ID 并只轮询该任务至成功")
    func submitsAndPollsExistingTask() async throws {
        let submit = HTTPTransportResponse(
            data: Data(#"{"id":"task-workspace","status":"running","progress":5}"#.utf8),
            statusCode: 200,
            headers: [:]
        )
        let result = HTTPTransportResponse(
            data: Data(#"{"id":"task-workspace","status":"succeeded","progress":100,"results":[]}"#.utf8),
            statusCode: 200,
            headers: [:]
        )
        let transport = WorkspaceTransport([submit, result])
        let client = GrsaiAPIClient(transport: transport)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = GenerationHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
        let imageStore = ResultImageStore(directory: directory.appendingPathComponent("images"))
        let secretStore = SessionSecretStore()
        let model = WorkspaceViewModel(
            apiClient: client,
            historyStore: history,
            imageStore: imageStore,
            secretStore: secretStore,
            pollInterval: .zero,
            retryInterval: .zero
        )
        model.credentialInput = "test-token"
        await model.saveCredential()
        model.prompt = "一只猫"

        await model.generate()
        for _ in 0..<100 where model.tasks.first?.status != .succeeded {
            await Task.yield()
        }

        #expect(model.tasks.count == 1)
        #expect(model.tasks.first?.id == "task-workspace")
        #expect(model.tasks.first?.status == .succeeded)
        let persisted = try await history.load()
        #expect(persisted.first?.id == "task-workspace")
        #expect(persisted.first?.status == .succeeded)
    }
}
