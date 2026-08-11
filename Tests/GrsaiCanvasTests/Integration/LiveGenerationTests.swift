import Foundation
import Testing
@testable import GrsaiCanvasApp

/// 真实集成验收的本地错误，不包含请求凭据。
private enum LiveGenerationError: Error {
    case missingCredential
    case timedOut(taskID: String)
    case terminalStatus(taskID: String, status: GenerationStatus)
    case missingResult(taskID: String)
}

@Suite("真实 Grsai 集成验收")
struct LiveGenerationTests {
    @Test(
        "客户端提交、轮询并下载一张图片",
        .enabled(if: ProcessInfo.processInfo.environment["GRSAI_LIVE_TEST"] == "1")
    )
    func generatesAndDownloadsImage() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let apiKey = environment["GRSAI_API_KEY"], !apiKey.isEmpty else {
            throw LiveGenerationError.missingCredential
        }

        let client = GrsaiAPIClient()
        let draft = GenerationDraft(
            prompt: "一只可爱的柴犬幼犬坐在窗边，温暖自然光，简洁背景，高品质摄影，无文字，无水印",
            model: .gptImage2,
            aspectRatio: .square,
            imageSize: nil,
            referenceImages: []
        )
        var response = try await client.submit(draft: draft, apiKey: apiKey)
        print("GRSAI_LIVE_TASK_ID=\(response.id)")

        let deadline = Date().addingTimeInterval(180)
        while response.status == .running, Date() < deadline {
            try await Task.sleep(for: .seconds(2))
            response = try await client.result(taskID: response.id, apiKey: apiKey)
            print("GRSAI_LIVE_STATUS=\(response.status.rawValue) PROGRESS=\(response.progress ?? 0)")
        }

        guard response.status != .running else {
            throw LiveGenerationError.timedOut(taskID: response.id)
        }
        guard response.status == .succeeded else {
            throw LiveGenerationError.terminalStatus(taskID: response.id, status: response.status)
        }
        guard let resultURL = response.results.first?.url else {
            throw LiveGenerationError.missingResult(taskID: response.id)
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("grsai-canvas-live", isDirectory: true)
        let imageStore = ResultImageStore(directory: directory)
        let path = try await imageStore.download(url: resultURL, taskID: response.id, index: 1)
        print("GRSAI_LIVE_FILE=\(path)")
        #expect(FileManager.default.fileExists(atPath: path))
    }
}
