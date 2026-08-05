import { randomUUID } from "node:crypto";
import type { GrsaiConfig } from "./config.js";
import {
  GenerationResponseSchema,
  OpenAiGenerationResponseSchema,
  type GenerateImageRequest,
  type GenerationResponse,
  type OpenAiGenerateImageRequest,
  type OpenAiGenerationResponse,
} from "./contracts.js";
import { GrsaiError, type ErrorPhase } from "./errors.js";

type Sleep = (milliseconds: number) => Promise<void>;

interface RequestContext {
  requestId?: string;
  timeoutMs?: number;
}

interface ResolvedRequestContext {
  requestId: string;
  timeoutMs: number;
  phase: ErrorPhase;
  acceptanceUnknownOnTimeout: boolean;
}

/** 封装 Grsai 原生与 OpenAI 兼容生图接口，并统一处理鉴权、超时和错误。 */
export class GrsaiClient {
  constructor(
    private readonly config: GrsaiConfig,
    private readonly fetcher: typeof fetch = fetch,
    private readonly sleep: Sleep = (milliseconds) =>
      new Promise((resolve) => setTimeout(resolve, milliseconds)),
  ) {}

  /** 提交原生 Grsai 生图任务。 */
  async generate(
    request: GenerateImageRequest,
    context: RequestContext = {},
  ): Promise<GenerationResponse> {
    const payload = await this.requestJson(
      "/v1/api/generate",
      {
        method: "POST",
        body: JSON.stringify(request),
      },
      {
        requestId: context.requestId ?? randomUUID(),
        timeoutMs: context.timeoutMs ?? this.config.submitTimeoutMs,
        phase: "submit",
        acceptanceUnknownOnTimeout: true,
      },
    );
    return this.parseGenerationResponse(payload);
  }

  /** 查询异步生图任务状态。 */
  async getResult(
    id: string,
    context: RequestContext = {},
  ): Promise<GenerationResponse> {
    const path = `/v1/api/result?id=${encodeURIComponent(id)}`;
    const payload = await this.requestJson(
      path,
      { method: "GET" },
      {
        requestId: context.requestId ?? randomUUID(),
        timeoutMs: context.timeoutMs ?? this.config.statusTimeoutMs,
        phase: "poll",
        acceptanceUnknownOnTimeout: false,
      },
    );
    return this.parseGenerationResponse(payload);
  }

  /** 轮询任务直至完成、失败或达到调用方给定的等待上限。 */
  async waitForResult(
    id: string,
    timeoutMs: number,
    pollIntervalMs = this.config.pollIntervalMs,
    context: RequestContext = {},
  ): Promise<GenerationResponse> {
    const startedAt = Date.now();
    const deadline = startedAt + timeoutMs;
    const requestId = context.requestId ?? randomUUID();
    let result = await this.getResultWithinDeadline(id, deadline, requestId);
    while (result.status === "running") {
      if (Date.now() + pollIntervalMs > deadline) {
        throw new GrsaiError("等待生图任务超时，可使用任务 ID 稍后查询", {
          code: "POLL_TIMEOUT",
          retryable: true,
          phase: "poll",
          requestId,
          elapsedMs: Date.now() - startedAt,
          timeoutMs,
        });
      }
      await this.sleep(pollIntervalMs);
      result = await this.getResultWithinDeadline(id, deadline, requestId);
    }
    return result;
  }

  /** 在轮询总预算内查询一次，避免单次状态请求突破调用方截止时间。 */
  private async getResultWithinDeadline(
    id: string,
    deadline: number,
    requestId: string,
  ): Promise<GenerationResponse> {
    const remainingMs = deadline - Date.now();
    if (remainingMs <= 0) {
      throw new GrsaiError("等待生图任务超时，可使用任务 ID 稍后查询", {
        code: "POLL_TIMEOUT",
        retryable: true,
        phase: "poll",
        requestId,
        timeoutMs: 0,
      });
    }
    return this.getResult(id, {
      requestId,
      timeoutMs: Math.min(this.config.statusTimeoutMs, remainingMs),
    });
  }

  /** 调用 OpenAI 兼容的同步图片生成接口。 */
  async generateOpenAi(
    request: OpenAiGenerateImageRequest,
    context: RequestContext = {},
  ): Promise<OpenAiGenerationResponse> {
    const payload = await this.requestJson(
      "/v1/images/generations",
      {
        method: "POST",
        body: JSON.stringify(request),
      },
      {
        requestId: context.requestId ?? randomUUID(),
        timeoutMs: context.timeoutMs ?? this.config.syncGenerationTimeoutMs,
        phase: "sync_generate",
        acceptanceUnknownOnTimeout: true,
      },
    );
    const parsed = OpenAiGenerationResponseSchema.safeParse(payload);
    if (!parsed.success) {
      throw new GrsaiError("Grsai 返回了无法识别的兼容接口响应", {
        code: "INVALID_RESPONSE",
      });
    }
    return parsed.data;
  }

  /** 发送 JSON 请求并把 HTTP/网络异常转换为稳定错误。 */
  private async requestJson(
    path: string,
    init: RequestInit,
    context: ResolvedRequestContext,
  ): Promise<unknown> {
    if (!this.config.apiKey) {
      throw new GrsaiError("缺少 GRSAI_API_KEY 环境变量", {
        code: "MISSING_API_KEY",
      });
    }
    const startedAt = Date.now();
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), context.timeoutMs);
    try {
      const response = await this.fetcher(`${this.config.baseUrl}${path}`, {
        ...init,
        headers: {
          Authorization: `Bearer ${this.config.apiKey}`,
          "Content-Type": "application/json",
          Accept: "application/json",
        },
        signal: controller.signal,
      });
      const payload = await parseJsonSafely(response);
      if (!response.ok) {
        const upstreamRequestId = extractUpstreamRequestId(response);
        throw new GrsaiError(extractErrorMessage(payload, response.status), {
          code: "HTTP_ERROR",
          status: response.status,
          retryable: response.status === 429 || response.status >= 500,
          phase: context.phase,
          requestId: context.requestId,
          ...(upstreamRequestId ? { upstreamRequestId } : {}),
          elapsedMs: Date.now() - startedAt,
        });
      }
      return payload;
    } catch (error) {
      if (error instanceof GrsaiError) {
        throw error;
      }
      if ((error as Error).name === "AbortError") {
        throw new GrsaiError("Grsai 请求超时", {
          code: "REQUEST_TIMEOUT",
          retryable: true,
          phase: context.phase,
          requestId: context.requestId,
          elapsedMs: Date.now() - startedAt,
          timeoutMs: context.timeoutMs,
          acceptanceUnknown: context.acceptanceUnknownOnTimeout,
        });
      }
      throw new GrsaiError("无法连接 Grsai 服务", {
        code: "NETWORK_ERROR",
        retryable: true,
        phase: context.phase,
        requestId: context.requestId,
        elapsedMs: Date.now() - startedAt,
        acceptanceUnknown: context.acceptanceUnknownOnTimeout,
      });
    } finally {
      clearTimeout(timeout);
    }
  }

  /** 校验原生接口响应，并将失败或违规状态转换为明确错误。 */
  private parseGenerationResponse(payload: unknown): GenerationResponse {
    const parsed = GenerationResponseSchema.safeParse(payload);
    if (!parsed.success) {
      throw new GrsaiError("Grsai 返回了无法识别的任务响应", {
        code: "INVALID_RESPONSE",
      });
    }
    if (parsed.data.status === "failed" || parsed.data.status === "violation") {
      throw new GrsaiError(
        parsed.data.error ||
          (parsed.data.status === "violation"
            ? "生成内容未通过安全检查"
            : "图片生成失败"),
        {
          code:
            parsed.data.status === "violation"
              ? "CONTENT_VIOLATION"
              : "GENERATION_FAILED",
        },
      );
    }
    return parsed.data;
  }
}

/** 提取常见上游请求标识，便于在不暴露响应体的情况下联查日志。 */
function extractUpstreamRequestId(response: Response): string | undefined {
  return (
    response.headers.get("x-request-id") ??
    response.headers.get("request-id") ??
    response.headers.get("cf-ray") ??
    undefined
  )?.slice(0, 200);
}

/** 安全解析 JSON，避免把完整非 JSON 响应泄露到错误信息。 */
async function parseJsonSafely(response: Response): Promise<unknown> {
  try {
    return await response.json();
  } catch {
    throw new GrsaiError("Grsai 返回了非 JSON 响应", {
      code: "INVALID_JSON",
      status: response.status,
      retryable: response.status >= 500,
    });
  }
}

/** 从已解析错误对象中提取有限的公开错误文本。 */
function extractErrorMessage(payload: unknown, status: number): string {
  if (typeof payload === "object" && payload !== null) {
    const record = payload as Record<string, unknown>;
    if (typeof record.error === "string") {
      return record.error.slice(0, 500);
    }
    if (
      typeof record.error === "object" &&
      record.error !== null &&
      typeof (record.error as Record<string, unknown>).message === "string"
    ) {
      return String((record.error as Record<string, unknown>).message).slice(
        0,
        500,
      );
    }
  }
  return `Grsai 请求失败，HTTP ${status}`;
}
