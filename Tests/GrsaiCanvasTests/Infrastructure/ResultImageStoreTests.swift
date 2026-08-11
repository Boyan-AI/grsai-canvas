import Foundation
import Testing
@testable import GrsaiCanvasApp

@Suite("结果图片存储")
struct ResultImageStoreTests {
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
}
