import Foundation

/// 校验本地参考图并转换为 Grsai 接受的 data URL。
enum ReferenceImageEncoder {
    static let maximumImageCount = 8
    static let maximumVideoImageCount = 9
    static let maximumSingleImageBytes = 10 * 1024 * 1024
    static let maximumTotalBytes = 8 * 1024 * 1024

    /// 读取参考图并执行格式与体积限制，视频模型可使用第九张参考图。
    static func encode(urls: [URL], maximumCount: Int = maximumImageCount) throws -> [ReferenceImagePayload] {
        guard urls.count <= maximumCount else {
            throw GrsaiClientError.invalidInput("参考图最多允许 (maximumCount) 张")
        }
        var totalBytes = 0
        return try urls.map { url in
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= maximumSingleImageBytes else {
                throw GrsaiClientError.invalidInput("单张参考图不能超过 10 MB")
            }
            totalBytes += data.count
            guard totalBytes <= maximumTotalBytes else {
                throw GrsaiClientError.invalidInput("参考图总大小不能超过 8 MB")
            }
            let mimeType = try supportedMIMEType(for: url)
            return ReferenceImagePayload(
                fileName: url.lastPathComponent,
                dataURL: "data:\(mimeType);base64,\(data.base64EncodedString())"
            )
        }
    }

    /// 根据扩展名返回受支持的图片 MIME 类型。
    private static func supportedMIMEType(for url: URL) throws -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "webp": return "image/webp"
        default:
            throw GrsaiClientError.invalidInput("仅支持 JPG、JPEG、PNG 和 WEBP 参考图")
        }
    }
}
