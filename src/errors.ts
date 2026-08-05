/** MCP 生图链路中可安全暴露的故障阶段。 */
export type ErrorPhase =
  | "input"
  | "submit"
  | "poll"
  | "sync_generate"
  | "download";

/** 对外稳定暴露的 Grsai 调用错误，不携带密钥或完整响应体。 */
export class GrsaiError extends Error {
  readonly code: string;
  readonly status?: number;
  readonly retryable: boolean;
  readonly phase?: ErrorPhase;
  readonly requestId?: string;
  readonly upstreamRequestId?: string;
  readonly elapsedMs?: number;
  readonly timeoutMs?: number;
  readonly acceptanceUnknown: boolean;

  constructor(
    message: string,
    options: {
      code: string;
      status?: number;
      retryable?: boolean;
      phase?: ErrorPhase;
      requestId?: string;
      upstreamRequestId?: string;
      elapsedMs?: number;
      timeoutMs?: number;
      acceptanceUnknown?: boolean;
    },
  ) {
    super(message);
    this.name = "GrsaiError";
    this.code = options.code;
    this.retryable = options.retryable ?? false;
    this.acceptanceUnknown = options.acceptanceUnknown ?? false;
    if (options.status !== undefined) {
      this.status = options.status;
    }
    if (options.phase !== undefined) {
      this.phase = options.phase;
    }
    if (options.requestId !== undefined) {
      this.requestId = options.requestId;
    }
    if (options.upstreamRequestId !== undefined) {
      this.upstreamRequestId = options.upstreamRequestId;
    }
    if (options.elapsedMs !== undefined) {
      this.elapsedMs = options.elapsedMs;
    }
    if (options.timeoutMs !== undefined) {
      this.timeoutMs = options.timeoutMs;
    }
  }
}

/** 将未知异常转换为适合返回给 MCP 客户端的安全文本。 */
export function toSafeErrorMessage(error: unknown): string {
  if (error instanceof GrsaiError) {
    const details = [error.code];
    if (error.phase) {
      details.push(`阶段 ${error.phase}`);
    }
    if (error.requestId) {
      details.push(`请求 ${error.requestId}`);
    }
    const warning = error.acceptanceUnknown
      ? "；上游是否已接收任务未知，请勿直接重复提交"
      : "";
    return `${error.message}（${details.join("；")}）${warning}`;
  }
  if (error instanceof Error) {
    return error.message;
  }
  return "发生未知错误";
}
