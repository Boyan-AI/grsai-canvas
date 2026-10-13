import Foundation

/// 客户端对界面稳定暴露且不包含凭据的错误。
enum GrsaiClientError: Error, Equatable, LocalizedError, Sendable {
    case invalidInput(String)
    case missingAPIKey
    case invalidConfiguration(String)
    case requestFailed(
        code: String,
        phase: String,
        retryable: Bool,
        acceptanceUnknown: Bool,
        statusCode: Int?
    )
    case invalidResponse
    case persistence(String)
    case keychain(Int32)

    var errorDescription: String? {
        switch self {
        case .invalidInput(let message), .invalidConfiguration(let message), .persistence(let message):
            return message
        case .missingAPIKey:
            return "请先在设置中保存 Grsai API Key"
        case .requestFailed(_, let phase, _, let acceptanceUnknown, _):
            if acceptanceUnknown {
                return "提交结果未知，上游可能已接收任务，请勿直接重复生成"
            }
            return "Grsai 请求失败（阶段：\(phase)）"
        case .invalidResponse:
            return "Grsai 返回了无法识别的数据"
        case .keychain(let status):
            return "Keychain 操作失败（\(status)）"
        }
    }
}
