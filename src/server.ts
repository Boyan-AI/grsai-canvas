import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { randomUUID } from "node:crypto";
import { isAbsolute } from "node:path";
import { z } from "zod";
import type { GrsaiConfig } from "./config.js";
import {
  ASPECT_RATIOS,
  GPT_IMAGE_PIXEL_SIZES,
  IMAGE_MODELS,
  IMAGE_SIZES,
  type GenerateImageRequest,
  type GenerationResponse,
} from "./contracts.js";
import { downloadImages } from "./download.js";
import {
  GrsaiError,
  toSafeErrorMessage,
  type ErrorPhase,
} from "./errors.js";
import { GrsaiClient } from "./grsai-client.js";
import { normalizeImageInputs } from "./image-input.js";

const pixelSizeSchema = z.enum(GPT_IMAGE_PIXEL_SIZES);

const toolOutputSchema = {
  request_id: z.string(),
  id: z.string().optional(),
  status: z.enum(["running", "succeeded", "failed"]),
  progress: z.number().int().min(0).max(100).optional(),
  urls: z.array(z.string().url()),
  files: z.array(z.string()),
  error: z
    .object({
      code: z.string(),
      message: z.string(),
      phase: z
        .enum(["input", "submit", "poll", "sync_generate", "download"])
        .optional(),
      backend: z.enum(["native", "openai-compatible"]).optional(),
      retryable: z.boolean(),
      acceptance_unknown: z.boolean(),
      http_status: z.number().int().optional(),
      upstream_request_id: z.string().optional(),
      elapsed_ms: z.number().int().nonnegative().optional(),
      timeout_ms: z.number().int().positive().optional(),
    })
    .optional(),
};

type ToolSuccessOutput = {
  request_id: string;
  id: string;
  status: "running" | "succeeded";
  progress?: number;
  urls: string[];
  files: string[];
};

type ToolErrorOutput = {
  request_id: string;
  id?: string;
  status: "failed";
  urls: string[];
  files: string[];
  error: {
    code: string;
    message: string;
    phase?: ErrorPhase;
    backend?: "native" | "openai-compatible";
    retryable: boolean;
    acceptance_unknown: boolean;
    http_status?: number;
    upstream_request_id?: string;
    elapsed_ms?: number;
    timeout_ms?: number;
  };
};

/** 创建并注册 Grsai 生图 MCP 服务及其两个公开工具。 */
export function createServer(
  config: GrsaiConfig,
  dependencies: {
    client?: GrsaiClient;
    fetcher?: typeof fetch;
  } = {},
): McpServer {
  const client = dependencies.client ?? new GrsaiClient(config);
  const fetcher = dependencies.fetcher ?? fetch;
  const server = new McpServer(
    { name: "grsai-canvas", version: "0.1.0" },
    {
      instructions:
        "generate_image 可能产生费用，调用前确认用户确实要求生图。已有任务 ID 且状态为 running 时使用 get_generation；错误标记 acceptance_unknown 时上游可能已接收，请勿盲目重试。",
    },
  );

  server.registerTool(
    "generate_image",
    {
      title: "使用 Grsai 生成图片",
      description:
        "根据提示词生成或参考图片编辑图像。该操作会调用可能计费的 Grsai 外部服务；支持 nano-banana 和 gpt-image-2 系列。",
      inputSchema: {
        prompt: z.string().trim().min(1).max(32_000).describe("生图提示词"),
        model: z
          .enum(IMAGE_MODELS)
          .default("gpt-image-2")
          .describe("Grsai 图片模型"),
        reference_images: z
          .array(z.string().min(1))
          .max(8)
          .optional()
          .describe("HTTPS URL、data URL 或本地图片绝对路径"),
        aspect_ratio: z
          .union([z.enum(ASPECT_RATIOS), pixelSizeSchema])
          .optional()
          .describe(
            "图片比例，或 gpt-image-2 的标准像素尺寸 1024x1024、1536x1024、1024x1536",
          ),
        image_size: z
          .enum(IMAGE_SIZES)
          .optional()
          .describe("nano-banana 系列分辨率"),
        backend: z
          .enum(["native", "openai-compatible"])
          .default("native")
          .describe("默认原生异步接口；兼容模式使用同步 images/generations"),
        wait: z
          .boolean()
          .default(true)
          .describe("原生后端返回任务 ID 后是否继续轮询完成"),
        wait_timeout_seconds: z
          .number()
          .int()
          .min(5)
          .max(300)
          .default(180)
          .describe("原生后端拿到任务 ID 后的最长轮询秒数"),
        output_dir: z
          .string()
          .min(1)
          .refine(isAbsolute, "output_dir 必须是绝对路径")
          .optional()
          .describe("成功后下载图片的本地绝对目录"),
      },
      outputSchema: toolOutputSchema,
      annotations: {
        readOnlyHint: false,
        destructiveHint: false,
        openWorldHint: true,
      },
    },
    async (input) => {
      const requestId = randomUUID();
      let phase: ErrorPhase = "input";
      let taskId: string | undefined;
      try {
        validateGenerationInput(
          input.model,
          input.backend,
          input.aspect_ratio,
          input.image_size,
        );
        const images = await normalizeImageInputs(
          input.reference_images,
          config.maxReferenceImageBytes,
          config.maxReferenceTotalBytes,
        );
        let result: GenerationResponse;

        if (input.backend === "openai-compatible") {
          phase = "sync_generate";
          const response = await client.generateOpenAi(
            {
              model: input.model,
              prompt: input.prompt,
              ...(images.length > 0 ? { image: images } : {}),
              ...(input.aspect_ratio
                ? {
                    size:
                      input.aspect_ratio as NonNullable<
                        GenerateImageRequest["aspectRatio"]
                      >,
                  }
                : {}),
              response_format: "url",
            },
            { requestId },
          );
          result = {
            id: `openai-${response.created}`,
            status: "succeeded",
            results: response.data,
          };
          taskId = result.id;
        } else {
          phase = "submit";
          const request: GenerateImageRequest = {
            model: input.model,
            prompt: input.prompt,
            replyType: "async",
            ...(images.length > 0 ? { images } : {}),
            ...(input.aspect_ratio
              ? {
                  aspectRatio:
                    input.aspect_ratio as NonNullable<
                      GenerateImageRequest["aspectRatio"]
                    >,
                }
              : {}),
            ...(input.image_size ? { imageSize: input.image_size } : {}),
          };
          result = await client.generate(request, { requestId });
          taskId = result.id;
          if (input.wait && result.status === "running") {
            phase = "poll";
            try {
              result = await client.waitForResult(
                result.id,
                input.wait_timeout_seconds * 1_000,
                config.pollIntervalMs,
                { requestId },
              );
            } catch (error) {
              if (isRecoverablePollingError(error)) {
                return successResult({
                  request_id: requestId,
                  id: result.id,
                  status: "running",
                  ...(result.progress !== undefined
                    ? { progress: result.progress }
                    : {}),
                  urls: [],
                  files: [],
                });
              }
              throw error;
            }
          }
        }

        phase = "download";
        return successResult(
          await prepareToolOutput(
            result,
            requestId,
            input.output_dir,
            config.maxDownloadBytes,
            fetcher,
            config.downloadTimeoutMs,
          ),
        );
      } catch (error) {
        return errorResult(error, {
          requestId,
          ...(taskId ? { taskId } : {}),
          backend: input.backend,
          fallbackPhase: phase,
        });
      }
    },
  );

  server.registerTool(
    "get_generation",
    {
      title: "查询 Grsai 生图任务",
      description:
        "使用 generate_image 返回的任务 ID 查询异步生图进度和结果 URL；该工具不会创建新任务或下载文件。",
      inputSchema: {
        id: z.string().trim().min(1).max(200).describe("Grsai 任务 ID"),
        wait_timeout_seconds: z
          .number()
          .int()
          .min(0)
          .max(300)
          .default(0)
          .describe("为 0 时只查询一次，否则轮询至完成或超时"),
      },
      outputSchema: toolOutputSchema,
      annotations: {
        readOnlyHint: true,
        destructiveHint: false,
        openWorldHint: true,
      },
    },
    async ({ id, wait_timeout_seconds }) => {
      const requestId = randomUUID();
      try {
        let result: GenerationResponse;
        try {
          result = await client.getResult(id, { requestId });
        } catch (error) {
          if (isRecoverablePollingError(error)) {
            return successResult({
              request_id: requestId,
              id,
              status: "running",
              urls: [],
              files: [],
            });
          }
          throw error;
        }
        if (result.status === "running" && wait_timeout_seconds > 0) {
          try {
            result = await client.waitForResult(
              id,
              wait_timeout_seconds * 1_000,
              config.pollIntervalMs,
              { requestId },
            );
          } catch (error) {
            if (!isRecoverablePollingError(error)) {
              throw error;
            }
          }
        }
        return successResult(await prepareToolOutput(result, requestId));
      } catch (error) {
        return errorResult(error, {
          requestId,
          taskId: id,
          backend: "native",
          fallbackPhase: "poll",
        });
      }
    },
  );

  return server;
}

/** 校验模型、后端与尺寸参数组合，避免静默忽略或映射高风险输入。 */
function validateGenerationInput(
  model: (typeof IMAGE_MODELS)[number],
  backend: "native" | "openai-compatible",
  aspectRatio?:
    | (typeof ASPECT_RATIOS)[number]
    | (typeof GPT_IMAGE_PIXEL_SIZES)[number],
  imageSize?: (typeof IMAGE_SIZES)[number],
): void {
  const isGptImage = model.startsWith("gpt-image-2");
  const isPixelSize = GPT_IMAGE_PIXEL_SIZES.includes(
    aspectRatio as (typeof GPT_IMAGE_PIXEL_SIZES)[number],
  );

  if (isGptImage && imageSize) {
    throw new GrsaiError("gpt-image-2 系列不支持 image_size，请使用 aspect_ratio", {
      code: "INVALID_PARAMETER_COMBINATION",
      phase: "input",
    });
  }
  if (!isGptImage && isPixelSize) {
    throw new GrsaiError("nano-banana 系列不接受像素尺寸，请使用比例和 image_size", {
      code: "INVALID_PARAMETER_COMBINATION",
      phase: "input",
    });
  }
  if (backend === "openai-compatible" && imageSize) {
    throw new GrsaiError("OpenAI 兼容后端不会处理 image_size", {
      code: "INVALID_PARAMETER_COMBINATION",
      phase: "input",
    });
  }
  if (
    backend === "openai-compatible" &&
    aspectRatio !== undefined &&
    aspectRatio !== "auto" &&
    !isPixelSize
  ) {
    throw new GrsaiError(
      "OpenAI 兼容后端仅接受 auto 或标准像素尺寸；比例请使用 native 后端",
      { code: "INVALID_PARAMETER_COMBINATION", phase: "input" },
    );
  }
}

/** 把 API 任务结果转换为 MCP 稳定输出，并按需下载成功图片。 */
async function prepareToolOutput(
  result: GenerationResponse,
  requestId: string,
  outputDir?: string,
  maxDownloadBytes?: number,
  fetcher?: typeof fetch,
  downloadTimeoutMs?: number,
): Promise<ToolSuccessOutput> {
  if (result.status === "failed" || result.status === "violation") {
    throw new GrsaiError(result.error ?? "图片生成失败", {
      code:
        result.status === "violation"
          ? "CONTENT_VIOLATION"
          : "GENERATION_FAILED",
    });
  }
  const urls = result.results?.map((item) => item.url) ?? [];
  const files =
    result.status === "succeeded" && outputDir && urls.length > 0
      ? await downloadImages(
          urls,
          outputDir,
          result.id,
          maxDownloadBytes ?? 50 * 1024 * 1024,
          fetcher,
          downloadTimeoutMs,
          requestId,
        )
      : [];
  return {
    request_id: requestId,
    id: result.id,
    status: result.status,
    ...(result.progress !== undefined ? { progress: result.progress } : {}),
    urls,
    files,
  };
}

/** 创建同时包含机器可读数据和简短文本摘要的成功结果。 */
function successResult(output: ToolSuccessOutput) {
  const summary =
    output.status === "succeeded"
      ? `任务 ${output.id} 已完成，生成 ${output.urls.length} 张图片${output.files.length > 0 ? `，已保存到 ${output.files.join("、")}` : ""}。`
      : `任务 ${output.id} 仍在进行中${output.progress !== undefined ? `，进度 ${output.progress}%` : ""}。`;
  return {
    structuredContent: output,
    content: [{ type: "text" as const, text: summary }],
  };
}

/** 判断状态查询故障是否可通过已有任务 ID 稍后恢复。 */
function isRecoverablePollingError(error: unknown): boolean {
  return (
    error instanceof GrsaiError &&
    error.phase === "poll" &&
    error.retryable
  );
}

/** 创建包含安全诊断字段、但不含密钥或完整响应体的 MCP 错误结果。 */
function errorResult(
  error: unknown,
  context: {
    requestId: string;
    taskId?: string;
    backend: "native" | "openai-compatible";
    fallbackPhase: ErrorPhase;
  },
) {
  const grsaiError = error instanceof GrsaiError ? error : undefined;
  const output: ToolErrorOutput = {
    request_id: context.requestId,
    ...(context.taskId ? { id: context.taskId } : {}),
    status: "failed",
    urls: [],
    files: [],
    error: {
      code: grsaiError?.code ?? "UNKNOWN_ERROR",
      message: grsaiError?.message ?? "发生未知错误",
      phase: grsaiError?.phase ?? context.fallbackPhase,
      backend: context.backend,
      retryable: grsaiError?.retryable ?? false,
      acceptance_unknown: grsaiError?.acceptanceUnknown ?? false,
      ...(grsaiError?.status !== undefined
        ? { http_status: grsaiError.status }
        : {}),
      ...(grsaiError?.upstreamRequestId
        ? { upstream_request_id: grsaiError.upstreamRequestId }
        : {}),
      ...(grsaiError?.elapsedMs !== undefined
        ? { elapsed_ms: grsaiError.elapsedMs }
        : {}),
      ...(grsaiError?.timeoutMs !== undefined
        ? { timeout_ms: grsaiError.timeoutMs }
        : {}),
    },
  };
  return {
    isError: true,
    structuredContent: output,
    content: [{ type: "text" as const, text: toSafeErrorMessage(error) }],
  };
}
