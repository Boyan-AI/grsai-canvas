import Foundation
import Testing
@testable import GrsaiCanvasApp

@Suite("任务历史持久化")
struct GenerationHistoryStoreTests {
    /// 验证历史元数据可独立清除。
    @Test("清除历史元数据文件")
    func clearsHistoryFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("history.json")
        let store = GenerationHistoryStore(fileURL: fileURL)
        try await store.save([])

        try await store.clear()

        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        #expect(try await store.load().isEmpty)
    }

    @Test("任务可原子保存并重新读取")
    func roundTripsTasks() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GenerationHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
        let draft = GenerationDraft(
            prompt: "海边灯塔",
            model: .nanoBanana2,
            aspectRatio: .landscape,
            imageSize: .twoK,
            referenceImages: []
        )
        let response = GenerationResponse(id: "task-1", status: .running, progress: 20, results: [])
        let task = GenerationTask.submitted(
            response: response,
            requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            draft: draft,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )

        try await store.save([task])
        let loaded = try await store.load()

        #expect(loaded == [task])
    }
}
