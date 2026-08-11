import Foundation

/// 抽象访问令牌存取，便于界面和测试替换实现。
protocol SecretStore: Sendable {
    /// 读取当前会话的访问令牌。
    func read() async -> String?
    /// 覆盖当前会话的访问令牌。
    func save(_ value: String) async throws
    /// 清除当前会话的访问令牌。
    func delete() async
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
