import { readFile, stat } from "node:fs/promises";
import { extname, resolve } from "node:path";
import { GrsaiError } from "./errors.js";

const MIME_TYPES: Record<string, string> = {
  ".avif": "image/avif",
  ".gif": "image/gif",
  ".jpeg": "image/jpeg",
  ".jpg": "image/jpeg",
  ".png": "image/png",
  ".webp": "image/webp",
};

/** 将 URL、data URL 或本地图片路径转换为 Grsai 接受的参考图字符串。 */
export async function normalizeImageInputs(
  inputs: string[] | undefined,
  maxBytes: number,
  maxTotalBytes = maxBytes * 8,
): Promise<string[]> {
  if (!inputs) {
    return [];
  }
  const normalized: string[] = [];
  let totalInlineBytes = 0;
  for (const input of inputs) {
    const result = await normalizeImageInput(input, maxBytes);
    totalInlineBytes += result.inlineBytes;
    if (totalInlineBytes > maxTotalBytes) {
      throw new GrsaiError(
        `参考图内联总量超过限制：约 ${formatMegabytes(totalInlineBytes)} MB，限制 ${formatMegabytes(maxTotalBytes)} MB；请减少图片、压缩图片或改用 HTTPS URL`,
        { code: "REFERENCE_PAYLOAD_TOO_LARGE", phase: "input" },
      );
    }
    normalized.push(result.value);
  }
  return normalized;
}

interface NormalizedImageInput {
  value: string;
  inlineBytes: number;
}

/** 校验单个参考图；本地文件会以内联 data URL 形式发送。 */
async function normalizeImageInput(
  input: string,
  maxBytes: number,
): Promise<NormalizedImageInput> {
  const value = input.trim();
  if (/^https:\/\//i.test(value)) {
    return { value, inlineBytes: 0 };
  }
  if (/^data:image\//i.test(value)) {
    return { value, inlineBytes: validateDataUrl(value, maxBytes) };
  }
  if (/^http:\/\//i.test(value)) {
    throw new GrsaiError("参考图 URL 必须使用 HTTPS", {
      code: "INVALID_IMAGE_URL",
    });
  }

  const filePath = resolve(value);
  const fileStat = await stat(filePath).catch(() => undefined);
  if (!fileStat?.isFile()) {
    throw new GrsaiError(`参考图不存在或不是文件：${filePath}`, {
      code: "IMAGE_NOT_FOUND",
    });
  }
  if (fileStat.size > maxBytes) {
    throw new GrsaiError(`参考图超过大小限制：${filePath}`, {
      code: "IMAGE_TOO_LARGE",
    });
  }

  const mimeType = MIME_TYPES[extname(filePath).toLowerCase()];
  if (!mimeType) {
    throw new GrsaiError(`不支持的参考图格式：${filePath}`, {
      code: "UNSUPPORTED_IMAGE_TYPE",
    });
  }
  const data = await readFile(filePath);
  return {
    value: `data:${mimeType};base64,${data.toString("base64")}`,
    inlineBytes: fileStat.size,
  };
}

/** 校验内联图片编码与近似解码尺寸，避免超大输入占用内存。 */
function validateDataUrl(value: string, maxBytes: number): number {
  const separator = value.indexOf(",");
  if (separator < 0 || !/;base64$/i.test(value.slice(0, separator))) {
    throw new GrsaiError("参考图 data URL 必须使用 base64 编码", {
      code: "INVALID_IMAGE_DATA_URL",
    });
  }
  const encodedLength = value.length - separator - 1;
  const approximateBytes = Math.floor((encodedLength * 3) / 4);
  if (approximateBytes > maxBytes) {
    throw new GrsaiError("内联参考图超过大小限制", {
      code: "IMAGE_TOO_LARGE",
    });
  }
  return approximateBytes;
}

/** 把字节数格式化为便于用户处理的 MB 数值。 */
function formatMegabytes(bytes: number): string {
  return (bytes / (1024 * 1024)).toFixed(1);
}
