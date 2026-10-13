import Foundation

/// 隔离 URLSession 的可测试 HTTP 响应。
struct HTTPTransportResponse: Sendable {
    let data: Data
    let statusCode: Int
    let headers: [String: String]
    let finalURL: URL?

    /// 创建可测试响应；未提供最终地址时沿用请求侧校验。
    init(data: Data, statusCode: Int, headers: [String: String], finalURL: URL? = nil) {
        self.data = data
        self.statusCode = statusCode
        self.headers = headers
        self.finalURL = finalURL
    }
}

/// 定义 Grsai 客户端需要的最小 HTTP 能力。
protocol HTTPTransport: Sendable {
    /// 发送单次请求并返回完整响应。
    func send(_ request: URLRequest) async throws -> HTTPTransportResponse
}

/// 使用短生命周期 URLSession 执行真实 HTTPS 请求。
final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession

    /// 创建不读取浏览器缓存和 Cookie 的网络会话。
    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
    }

    /// 发送请求并拒绝非 HTTP 响应。
    func send(_ request: URLRequest) async throws -> HTTPTransportResponse {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GrsaiClientError.invalidResponse
        }
        let headers = httpResponse.allHeaderFields.reduce(into: [String: String]()) { result, item in
            result[String(describing: item.key)] = String(describing: item.value)
        }
        return HTTPTransportResponse(
            data: data,
            statusCode: httpResponse.statusCode,
            headers: headers,
            finalURL: httpResponse.url
        )
    }
}
