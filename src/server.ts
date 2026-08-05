import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { isAbsolute } from "node:path";
import { z } from "zod";
import type { GrsaiConfig } from "./config.js";
import {
  ASPECT_RATIOS,
  IMAGE_MODELS,
  IMAGE_SIZES,
  type GenerateImageRequest,
  type GenerationResponse,
} from "./contracts.js";
import { downloadImages } from "./download.js";
import { GrsaiError, toSafeErrorMessage } from "./errors.js";
import { GrsaiClient } from "./grsai-client.js";
import { normalizeImageInputs } from "./image-input.js";

const pixelSizeSchema = z
  .string()
  .regex(/^\d{2,4}x\d{2,4}$/, "像素尺寸必须使用 1024x1024 格式");

const toolOutputSchema = {
  id: z.string(),
  status: z.enum(["running", "succeeded"]),
  progress: z.number().int().min(0).max(100).optional(),
  urls: z.array(z.string().url()),
  files: z.array(z.string()),
};

type ToolOutput = {
  id: string;
  status: "running" | "succeeded";
  progress?: number;
  urls: string[];
  files: string[];
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
    { name: "grsai-image", version: "0.1.0" },
    {
      instructions:
        "generate_image 可能产生费用，调用前确认用户确实要求生图。需要最终文件时传入绝对 output_dir 并等待完成；超时或异步提交后使用 get_generation 查询任务。",
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
          .describe("图片比例或 gpt-image-2 像素尺寸"),
        image_size: z
          .enum(IMAGE_SIZES)
          .optional()
          .describe("nano-banana 系列分辨率"),
        backend: z
          .enum(["native", "openai-compatible"])
          .default("native")
          .describe("默认原生异步接口；兼容模式使用同步 images/generations"),
        wait: z.boolean().default(true).describe("是否等待任务完成"),
        wait_timeout_seconds: z
          .number()
          .int()
          .min(5)
          .max(300)
          .default(180)
          .describe("最长等待秒数"),
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
      try {
        const images = await normalizeImageInputs(
          input.reference_images,
          config.maxReferenceImageBytes,
        );
        let result: GenerationResponse;

        if (input.backend === "openai-compatible") {
          const response = await client.generateOpenAi({
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
          });
          result = {
            id: `openai-${response.created}`,
            status: "succeeded",
            results: response.data,
          };
        } else {
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
          result = await client.generate(request);
          if (input.wait && result.status === "running") {
            try {
              result = await client.waitForResult(
                result.id,
                input.wait_timeout_seconds * 1_000,
              );
            } catch (error) {
              if (error instanceof GrsaiError && error.code === "POLL_TIMEOUT") {
                return successResult({
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

        return successResult(
          await prepareToolOutput(
            result,
            input.output_dir,
            config.maxDownloadBytes,
            fetcher,
          ),
        );
      } catch (error) {
        return errorResult(error);
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
      try {
        let result = await client.getResult(id);
        if (result.status === "running" && wait_timeout_seconds > 0) {
          try {
            result = await client.waitForResult(
              id,
              wait_timeout_seconds * 1_000,
            );
          } catch (error) {
            if (!(error instanceof GrsaiError) || error.code !== "POLL_TIMEOUT") {
              throw error;
            }
          }
        }
        return successResult(await prepareToolOutput(result));
      } catch (error) {
        return errorResult(error);
      }
    },
  );

  return server;
}

/** 把 API 任务结果转换为 MCP 稳定输出，并按需下载成功图片。 */
async function prepareToolOutput(
  result: GenerationResponse,
  outputDir?: string,
  maxDownloadBytes?: number,
  fetcher?: typeof fetch,
): Promise<ToolOutput> {
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
        )
      : [];
  return {
    id: result.id,
    status: result.status,
    ...(result.progress !== undefined ? { progress: result.progress } : {}),
    urls,
    files,
  };
}

/** 创建同时包含机器可读数据和简短文本摘要的成功结果。 */
function successResult(output: ToolOutput) {
  const summary =
    output.status === "succeeded"
      ? `任务 ${output.id} 已完成，生成 ${output.urls.length} 张图片${output.files.length > 0 ? `，已保存到 ${output.files.join("、")}` : ""}。`
      : `任务 ${output.id} 仍在进行中${output.progress !== undefined ? `，进度 ${output.progress}%` : ""}。`;
  return {
    structuredContent: output,
    content: [{ type: "text" as const, text: summary }],
  };
}

/** 创建不含敏感响应信息的 MCP 错误结果。 */
function errorResult(error: unknown) {
  return {
    isError: true,
    content: [{ type: "text" as const, text: toSafeErrorMessage(error) }],
  };
}
