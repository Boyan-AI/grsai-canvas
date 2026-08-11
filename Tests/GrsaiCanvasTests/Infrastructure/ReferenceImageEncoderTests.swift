import Foundation
import Testing
@testable import GrsaiCanvasApp

@Suite("参考图编码")
struct ReferenceImageEncoderTests {
    @Test("PNG 会编码为 data URL")
    func encodesPNG() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: url)

        let images = try ReferenceImageEncoder.encode(urls: [url])

        #expect(images.count == 1)
        #expect(images[0].dataURL.hasPrefix("data:image/png;base64,"))
    }

    @Test("拒绝不支持的文件格式")
    func rejectsUnsupportedExtension() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([0x47, 0x49, 0x46]).write(to: url)

        #expect(throws: GrsaiClientError.self) {
            try ReferenceImageEncoder.encode(urls: [url])
        }
    }
}
