/** Grsai MCP 服务的运行时配置。 */
export interface GrsaiConfig {
  apiKey: string;
  baseUrl: string;
  requestTimeoutMs: number;
  pollIntervalMs: number;
  maxReferenceImageBytes: number;
  maxDownloadBytes: number;
}

const DEFAULT_BASE_URL = "https://grsai.dakka.com.cn";

/** 从环境变量读取配置；密钥缺失时仍允许 MCP 启动以暴露工具。 */
export function loadConfig(env: NodeJS.ProcessEnv = process.env): GrsaiConfig {
  const apiKey = env.GRSAI_API_KEY?.trim() ?? "";

  const baseUrl = normalizeBaseUrl(env.GRSAI_BASE_URL ?? DEFAULT_BASE_URL);
  return {
    apiKey,
    baseUrl,
    requestTimeoutMs: readPositiveInteger(env.GRSAI_REQUEST_TIMEOUT_MS, 60_000),
    pollIntervalMs: readPositiveInteger(env.GRSAI_POLL_INTERVAL_MS, 2_000),
    maxReferenceImageBytes: readPositiveInteger(
      env.GRSAI_MAX_REFERENCE_BYTES,
      10 * 1024 * 1024,
    ),
    maxDownloadBytes: readPositiveInteger(
      env.GRSAI_MAX_DOWNLOAD_BYTES,
      50 * 1024 * 1024,
    ),
  };
}

/** 规范化并校验 Grsai 基础节点，避免请求被发送到非 HTTPS 地址。 */
function normalizeBaseUrl(value: string): string {
  const url = new URL(value.trim());
  if (url.protocol !== "https:" && !isLocalTestUrl(url)) {
    throw new Error("GRSAI_BASE_URL 必须使用 HTTPS");
  }
  return url.toString().replace(/\/$/, "");
}

/** 仅允许自动化测试使用本机 HTTP mock 服务。 */
function isLocalTestUrl(url: URL): boolean {
  return (
    process.env.NODE_ENV === "test" &&
    url.protocol === "http:" &&
    (url.hostname === "127.0.0.1" || url.hostname === "localhost")
  );
}

/** 读取正整数环境变量，未配置时返回安全默认值。 */
function readPositiveInteger(value: string | undefined, fallback: number): number {
  if (value === undefined) {
    return fallback;
  }
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed <= 0) {
    throw new Error(`环境变量必须是正整数，实际值为 ${value}`);
  }
  return parsed;
}
