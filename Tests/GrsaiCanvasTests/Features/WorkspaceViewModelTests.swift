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

    /// 验证用户确认删除后的完整持久化结果。
    @Test("删除任务会同步清理历史和本地结果")
    func deletesTaskHistoryAndLocalResults() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let imagesDirectory = directory.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        let imageURL = imagesDirectory.appendingPathComponent("task-delete-1.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imageURL)

        let draft = GenerationDraft(
            prompt: "待删除作品",
            model: .gptImage2,
            aspectRatio: .square,
            imageSize: nil,
            referenceImages: []
        )
        let response = GenerationResponse(
            id: "task-delete",
            status: .succeeded,
            progress: 100,
            results: []
        )
        var task = GenerationTask.submitted(response: response, requestID: UUID(), draft: draft)
        task.localImagePaths = [imageURL.path]

        let history = GenerationHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
        try await history.save([task])
        let model = WorkspaceViewModel(
            historyStore: history,
            imageStore: ResultImageStore(directory: imagesDirectory),
            secretStore: SessionSecretStore()
        )
        await model.load()

        await model.deleteTask(id: task.id)

        #expect(model.tasks.isEmpty)
        #expect(try await history.load().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: imageURL.path))
    }

    /// 验证历史任务可以分别加载原始参考图或生成结果。
    @Test("继续修改可选择原图或生成图")
    func continuesEditingFromSelectedSource() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let imagesDirectory = directory.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        let originalURL = directory.appendingPathComponent("original.png")
        let generatedURL = imagesDirectory.appendingPathComponent("generated.png")
        try Data([1]).write(to: originalURL)
        try Data([2]).write(to: generatedURL)

        let draft = GenerationDraft(
            prompt: "把这张图改成水彩风格",
            model: .nanoBanana2,
            aspectRatio: .square,
            imageSize: .twoK,
            referenceImages: []
        )
        let response = GenerationResponse(
            id: "task-edit",
            status: .succeeded,
            progress: 100,
            results: [GenerationOutput(url: URL(string: "https://example.com/generated.png")!)]
        )
        var task = GenerationTask.submitted(response: response, requestID: UUID(), draft: draft)
        task.referenceImagePaths = [originalURL.path]
        task.localImagePaths = [generatedURL.path]

        let history = GenerationHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
        try await history.save([task])
        let model = WorkspaceViewModel(
            historyStore: history,
            imageStore: ResultImageStore(directory: imagesDirectory),
            secretStore: SessionSecretStore()
        )
        await model.load()
        guard let loadedTask = model.tasks.first else {
            Issue.record("历史任务未加载")
            return
        }

        await model.continueEditing(task: loadedTask, source: .original)
        #expect(model.prompt == task.prompt)
        #expect(model.selectedModel == task.model)
        #expect(model.selectedAspectRatio == task.aspectRatio)
        #expect(model.selectedImageSize == task.imageSize)
        #expect(model.referenceImageURLs == [originalURL])

        await model.continueEditing(task: loadedTask, source: .generated)
        #expect(model.referenceImageURLs == [generatedURL])
    }
}
