import Foundation

/// 下载并持久化成功任务的结果图片。
actor ResultImageStore {
    private let directory: URL
    private let transport: any HTTPTransport
    private let fileManager: FileManager
    private let maximumBytes: Int

    /// 创建结果图片仓库；测试可注入目录与网络传输层。
    init(
        directory: URL? = nil,
        transport: any HTTPTransport = URLSessionTransport(),
        fileManager: FileManager = .default,
        maximumBytes: Int = 50 * 1024 * 1024
    ) {
        self.transport = transport
        self.fileManager = fileManager
        self.maximumBytes = maximumBytes
        if let directory {
            self.directory = directory
        } else {
            let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Application Support", isDirectory: true)
            self.directory = support
                .appendingPathComponent("Grsai Canvas", isDirectory: true)
                .appendingPathComponent("Images", isDirectory: true)
        }
    }

    /// 下载单张 HTTPS 图片并返回本地绝对路径。
    func download(url: URL, taskID: String, index: Int) async throws -> String {
        guard url.scheme?.lowercased() == "https" else {
            throw GrsaiClientError.invalidInput("结果图片地址必须使用 HTTPS")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 45
        let response: HTTPTransportResponse
        do {
            response = try await transport.send(request)
        } catch {
            throw GrsaiClientError.requestFailed(
                code: "DOWNLOAD_FAILED",
                phase: "download",
                retryable: true,
                acceptanceUnknown: false,
                statusCode: nil
            )
        }
        guard (200..<300).contains(response.statusCode) else {
            throw GrsaiClientError.requestFailed(
                code: "HTTP_ERROR",
                phase: "download",
                retryable: response.statusCode == 429 || response.statusCode >= 500,
                acceptanceUnknown: false,
                statusCode: response.statusCode
            )
        }
        guard response.finalURL?.scheme?.lowercased() != "http" else {
            throw GrsaiClientError.invalidResponse
        }
        guard !response.data.isEmpty, response.data.count <= maximumBytes else {
            throw GrsaiClientError.persistence("结果图片为空或超过 50 MB")
        }
        let fileExtension = try detectedExtension(data: response.data)
        let safeTaskID = taskID.replacingOccurrences(
            of: "[^A-Za-z0-9_-]",
            with: "-",
            options: .regularExpression
        )
        let destination = directory.appendingPathComponent("\(safeTaskID)-\(index).\(fileExtension)")
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try response.data.write(to: destination, options: .atomic)
            return destination.path
        } catch {
            throw GrsaiClientError.persistence("结果图片保存失败")
        }
    }

    /// 将用户原始参考图复制到应用缓存，确保历史任务不依赖外部文件位置。
    func copyReferenceImages(urls: [URL], taskID: String) throws -> [String] {
        guard urls.count <= ReferenceImageEncoder.maximumImageCount else {
            throw GrsaiClientError.invalidInput("参考图最多允许 8 张")
        }
        let referenceDirectory = directory.appendingPathComponent("References", isDirectory: true)
        var copiedPaths: [String] = []
        do {
            try fileManager.createDirectory(at: referenceDirectory, withIntermediateDirectories: true)
            for (index, url) in urls.enumerated() {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                guard fileManager.fileExists(atPath: url.path) else {
                    throw GrsaiClientError.persistence("原始参考图不存在")
                }
                let extensionName = url.pathExtension.lowercased()
                guard ["jpg", "jpeg", "png", "webp"].contains(extensionName) else {
                    throw GrsaiClientError.invalidInput("仅支持 JPG、JPEG、PNG 和 WEBP 参考图")
                }
                let destination = referenceDirectory
                    .appendingPathComponent("\(taskID)-\(index + 1).\(extensionName)")
                try fileManager.copyItem(at: url, to: destination)
                copiedPaths.append(destination.path)
            }
            return copiedPaths
        } catch let error as GrsaiClientError {
            try? delete(paths: copiedPaths)
            throw error
        } catch {
            try? delete(paths: copiedPaths)
            throw GrsaiClientError.persistence("原始参考图缓存失败")
        }
    }

    /// 删除图片仓库直属的结果文件，拒绝越出应用管理目录的路径。
    func delete(paths: [String]) throws {
        let managedDirectory = directory.standardizedFileURL.resolvingSymlinksInPath()
        for path in paths {
            let candidate = URL(fileURLWithPath: path).standardizedFileURL
            let parent = candidate.deletingLastPathComponent().resolvingSymlinksInPath()
            let parentPath = parent.path
            guard parentPath == managedDirectory.path || parentPath.hasPrefix(managedDirectory.path + "/") else {
                throw GrsaiClientError.persistence("任务已删除，但检测到非应用管理的图片路径")
            }
            guard fileManager.fileExists(atPath: candidate.path) else { continue }
            do {
                try fileManager.removeItem(at: candidate)
            } catch {
                throw GrsaiClientError.persistence("任务已删除，但本地图片清理失败")
            }
        }
    }

    /// 清空应用管理的全部图片缓存，但保留缓存目录和历史元数据。
    func clearCache() throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        do {
            let entries = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            for entry in entries {
                try fileManager.removeItem(at: entry)
            }
        } catch {
            throw GrsaiClientError.persistence("图片缓存清理失败")
        }
    }

    /// 通过文件签名识别允许持久化的图片格式。
    private func detectedExtension(data: Data) throws -> String {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if bytes.count >= 12,
           Array(bytes[0..<4]) == [0x52, 0x49, 0x46, 0x46],
           Array(bytes[8..<12]) == [0x57, 0x45, 0x42, 0x50] {
            return "webp"
        }
        throw GrsaiClientError.invalidResponse
    }
}
