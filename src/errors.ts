/** 对外稳定暴露的 Grsai 调用错误，不携带密钥或完整响应体。 */
export class GrsaiError extends Error {
  readonly code: string;
  readonly status?: number;
  readonly retryable: boolean;

  constructor(
    message: string,
    options: { code: string; status?: number; retryable?: boolean },
  ) {
    super(message);
    this.name = "GrsaiError";
    this.code = options.code;
    this.retryable = options.retryable ?? false;
    if (options.status !== undefined) {
      this.status = options.status;
    }
  }
}

/** 将未知异常转换为适合返回给 MCP 客户端的安全文本。 */
export function toSafeErrorMessage(error: unknown): string {
  if (error instanceof GrsaiError) {
    return `${error.message}（${error.code}）`;
  }
  if (error instanceof Error) {
    return error.message;
  }
  return "发生未知错误";
}
