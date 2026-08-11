import Foundation

/// 抽象访问令牌存取，便于界面和测试替换实现。
protocol SecretStore: Sendable {
    /// 读取已保存的访问令牌。
    func read() async -> String?
    /// 覆盖已保存的访问令牌。
    func save(_ value: String) async throws
    /// 清除已保存的访问令牌。
    func delete() async
}

/// 将访问令牌保存到应用的 UserDefaults 数据区，供应用重启后继续使用。
actor ApplicationDataSecretStore: SecretStore {
    private let defaults: UserDefaults
    private let storageKey: String

    /// 创建应用数据存储；可注入独立 UserDefaults 以隔离测试数据。
    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "grsai.apiKey"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    /// 使用独立 suite 创建隔离存储，避免测试跨并发域传递 UserDefaults 实例。
    init(suiteName: String, storageKey: String = "grsai.apiKey") {
        self.defaults = UserDefaults(suiteName: suiteName) ?? UserDefaults()
        self.storageKey = storageKey
    }

    /// 读取并校验应用数据中的令牌。
    func read() -> String? {
        guard let value = defaults.string(forKey: storageKey) else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    /// 校验并持久化令牌，不在错误或日志中暴露原始内容。
    func save(_ value: String) throws {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw GrsaiClientError.missingAPIKey }
        defaults.set(normalized, forKey: storageKey)
    }

    /// 从应用数据中彻底移除令牌。
    func delete() {
        defaults.removeObject(forKey: storageKey)
    }
}

/// 仅在进程内保存访问令牌，关闭应用后自动清除。
actor SessionSecretStore: SecretStore {
    private var value: String?

    /// 读取当前进程内的令牌。
    func read() -> String? {
        value
    }

    /// 校验并保存当前进程内的令牌。
    func save(_ value: String) throws {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw GrsaiClientError.missingAPIKey }
        self.value = normalized
    }

    /// 清除当前进程内的令牌。
    func delete() {
        value = nil
    }
}
