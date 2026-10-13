import Foundation

/// 以原子 JSON 文件持久化生图任务，支持应用重启恢复。
actor GenerationHistoryStore {
    private let fileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// 创建历史仓库；测试可注入隔离路径。
    init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Application Support", isDirectory: true)
            self.fileURL = support
                .appendingPathComponent("Grsai Canvas", isDirectory: true)
                .appendingPathComponent("history.json", isDirectory: false)
        }
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    /// 读取历史；首次启动没有文件时返回空数组。
    func load() throws -> [GenerationTask] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        do {
            return try decoder.decode([GenerationTask].self, from: Data(contentsOf: fileURL))
        } catch {
            throw GrsaiClientError.persistence("历史记录损坏，无法读取")
        }
    }

    /// 原子保存全部任务，并自动创建父目录。
    func save(_ tasks: [GenerationTask]) throws {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try encoder.encode(tasks)
            try data.write(to: fileURL, options: .atomic)
        } catch let error as GrsaiClientError {
            throw error
        } catch {
            throw GrsaiClientError.persistence("历史记录保存失败")
        }
    }

    /// 删除历史元数据文件，供“清空应用数据”使用。
    func clear() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        do {
            try fileManager.removeItem(at: fileURL)
        } catch {
            throw GrsaiClientError.persistence("历史记录清理失败")
        }
    }
}
