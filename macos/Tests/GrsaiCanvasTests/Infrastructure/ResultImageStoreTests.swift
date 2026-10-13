import Foundation
import Testing
@testable import GrsaiCanvasApp

@Suite("结果图片存储")
struct ResultImageStoreTests {
    /// 验证原图副本进入应用缓存，清理时不影响缓存目录外的源文件。
    @Test("复制原始参考图并可清空全部图片缓存")
    func copiesReferencesAndClearsCache() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.png")
        let imagesDirectory = root.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: source)
        let store = ResultImageStore(directory: imagesDirectory)

        let copied = try await store.copyReferenceImages(urls: [source], taskID: "task-copy")
        #expect(copied.count == 1)
        #expect(FileManager.default.fileExists(atPath: copied[0]))

        try await store.clearCache()

        #expect(!FileManager.default.fileExists(atPath: copied[0]))
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    /// 验证正常清理不会影响仓库外的文件。
    @Test("只删除图片仓库直属文件")
    func deletesManagedFileOnly() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let imagesDirectory = root.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        let managedFile = imagesDirectory.appendingPathComponent("result.png")
        let outsideFile = root.appendingPathComponent("outside.png")
        try Data([1]).write(to: managedFile)
        try Data([2]).write(to: outsideFile)
        let store = ResultImageStore(directory: imagesDirectory)

        try await store.delete(paths: [managedFile.path])

        #expect(!FileManager.default.fileExists(atPath: managedFile.path))
        #expect(FileManager.default.fileExists(atPath: outsideFile.path))
    }

    /// 验证异常历史路径不会扩大文件删除范围。
    @Test("拒绝删除图片仓库外的文件")
    func rejectsPathOutsideManagedDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let imagesDirectory = root.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        let outsideFile = root.appendingPathComponent("outside.png")
        try Data([3]).write(to: outsideFile)
        let store = ResultImageStore(directory: imagesDirectory)

        await #expect(throws: GrsaiClientError.self) {
            try await store.delete(paths: [outsideFile.path])
        }
        #expect(FileManager.default.fileExists(atPath: outsideFile.path))
    }

    /// 注入 MP4 文件签名，确认视频结果不会被保存成图片扩展名。
    @Test("保存 MP4 视频结果")
    func downloadsVideoResult() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let imagesDirectory = root.appendingPathComponent("images", isDirectory: true)
        let mp4 = Data([0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6F, 0x6D])
        let transport = StubStoreTransport(.success(HTTPTransportResponse(
            data: mp4,
            statusCode: 200,
            headers: ["Content-Type": "video/mp4"]
        )))
        let store = ResultImageStore(directory: imagesDirectory, transport: transport)

        let path = try await store.download(
            url: URL(string: "https://video.example/result")!,
            taskID: "video-task",
            index: 1
        )

        #expect(path.hasSuffix(".mp4"))
    }
}

/// 返回单条结果的测试传输层。
private actor StubStoreTransport: HTTPTransport {
    let result: Result<HTTPTransportResponse, Error>

    /// 创建固定响应。
    init(_ result: Result<HTTPTransportResponse, Error>) {
        self.result = result
    }

    /// 返回固定响应，不访问网络。
    func send(_ request: URLRequest) async throws -> HTTPTransportResponse {
        try result.get()
    }
}
