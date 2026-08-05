import { mkdir, writeFile } from "node:fs/promises";
import { extname, resolve } from "node:path";
import { GrsaiError } from "./errors.js";

const CONTENT_TYPE_EXTENSIONS: Record<string, string> = {
  "image/avif": ".avif",
  "image/gif": ".gif",
  "image/jpeg": ".jpg",
  "image/png": ".png",
  "image/webp": ".webp",
};

/** 将 Grsai 返回的 HTTPS 图片下载到指定目录，且绝不覆盖已有文件。 */
export async function downloadImages(
  urls: string[],
  outputDir: string,
  taskId: string,
  maxBytes: number,
  fetcher: typeof fetch = fetch,
): Promise<string[]> {
  const directory = resolve(outputDir);
  await mkdir(directory, { recursive: true });
  const downloaded: string[] = [];

  for (const [index, source] of urls.entries()) {
    const url = new URL(source);
    if (url.protocol !== "https:" && !isLocalTestUrl(url)) {
      throw new GrsaiError("生成结果 URL 必须使用 HTTPS", {
        code: "INVALID_RESULT_URL",
      });
    }

    const response = await fetcher(url, { redirect: "follow" });
    if (!response.ok) {
      throw new GrsaiError(`下载生成结果失败，HTTP ${response.status}`, {
        code: "DOWNLOAD_FAILED",
        status: response.status,
        retryable: response.status >= 500,
      });
    }
    const contentLength = Number(response.headers.get("content-length") ?? 0);
    if (contentLength > maxBytes) {
      throw new GrsaiError("生成结果超过下载大小限制", {
        code: "DOWNLOAD_TOO_LARGE",
      });
    }
    const bytes = Buffer.from(await response.arrayBuffer());
    if (bytes.byteLength > maxBytes) {
      throw new GrsaiError("生成结果超过下载大小限制", {
        code: "DOWNLOAD_TOO_LARGE",
      });
    }

    const extension = inferExtension(
      response.headers.get("content-type"),
      url.pathname,
    );
    const baseName = `grsai-${safeTaskId(taskId)}-${index + 1}`;
    downloaded.push(
      await writeWithoutOverwrite(directory, baseName, extension, bytes),
    );
  }
  return downloaded;
}

/** 根据响应类型或 URL 路径推断安全的图片扩展名。 */
function inferExtension(contentType: string | null, pathname: string): string {
  const normalizedType = contentType?.split(";")[0]?.trim().toLowerCase();
  if (normalizedType && CONTENT_TYPE_EXTENSIONS[normalizedType]) {
    return CONTENT_TYPE_EXTENSIONS[normalizedType];
  }
  const extension = extname(pathname).toLowerCase();
  return Object.values(CONTENT_TYPE_EXTENSIONS).includes(extension)
    ? extension
    : ".img";
}

/** 使用 wx 标志和递增后缀写文件，防止覆盖用户已有内容。 */
async function writeWithoutOverwrite(
  directory: string,
  baseName: string,
  extension: string,
  bytes: Buffer,
): Promise<string> {
  for (let suffix = 0; suffix < 10_000; suffix += 1) {
    const name =
      suffix === 0
        ? `${baseName}${extension}`
        : `${baseName}-${suffix}${extension}`;
    const filePath = resolve(directory, name);
    try {
      await writeFile(filePath, bytes, { flag: "wx" });
      return filePath;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "EEXIST") {
        throw error;
      }
    }
  }
  throw new GrsaiError("无法为生成结果分配唯一文件名", {
    code: "OUTPUT_NAME_EXHAUSTED",
  });
}

/** 清理任务 ID，避免服务端返回值影响本地路径结构。 */
function safeTaskId(taskId: string): string {
  return taskId.replace(/[^a-zA-Z0-9_-]/g, "_").slice(0, 96);
}

/** 仅允许自动化测试从本机 HTTP mock 服务下载。 */
function isLocalTestUrl(url: URL): boolean {
  return (
    process.env.NODE_ENV === "test" &&
    url.protocol === "http:" &&
    (url.hostname === "127.0.0.1" || url.hostname === "localhost")
  );
}
