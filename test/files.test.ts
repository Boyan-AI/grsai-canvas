import assert from "node:assert/strict";
import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { downloadImages } from "../src/download.js";
import { normalizeImageInputs } from "../src/image-input.js";
import { GrsaiError } from "../src/errors.js";

test("本地参考图会转换为 data URL", async () => {
  const directory = await mkdtemp(join(tmpdir(), "grsai-input-"));
  const filePath = join(directory, "reference.png");
  await writeFile(filePath, Buffer.from([0x89, 0x50, 0x4e, 0x47]));

  const result = await normalizeImageInputs([filePath], 1_024);

  assert.match(result[0] ?? "", /^data:image\/png;base64,/);
});

test("下载生成结果不会覆盖已有文件", async () => {
  const directory = await mkdtemp(join(tmpdir(), "grsai-output-"));
  const fetcher = (async () =>
    new Response(Buffer.from("image-bytes"), {
      headers: { "Content-Type": "image/png" },
    })) as typeof fetch;

  const first = await downloadImages(
    ["https://images.example/result.png"],
    directory,
    "task/unsafe",
    1_024,
    fetcher,
  );
  const second = await downloadImages(
    ["https://images.example/result.png"],
    directory,
    "task/unsafe",
    1_024,
    fetcher,
  );

  assert.notEqual(first[0], second[0]);
  assert.equal(await readFile(first[0] ?? "", "utf8"), "image-bytes");
});

test("超大 data URL 会在调用接口前被拒绝", async () => {
  await assert.rejects(
    () => normalizeImageInputs([`data:image/png;base64,${"A".repeat(200)}`], 10),
    (error: unknown) =>
      error instanceof GrsaiError && error.code === "IMAGE_TOO_LARGE",
  );
});

test("参考图聚合体积超限会在计费调用前被拒绝", async () => {
  await assert.rejects(
    () =>
      normalizeImageInputs(
        [
          `data:image/png;base64,${"A".repeat(80)}`,
          `data:image/png;base64,${"A".repeat(80)}`,
        ],
        1_024,
        100,
      ),
    (error: unknown) =>
      error instanceof GrsaiError &&
      error.code === "REFERENCE_PAYLOAD_TOO_LARGE",
  );
});

test("结果下载超时会返回 download 阶段诊断", async () => {
  const directory = await mkdtemp(join(tmpdir(), "grsai-download-timeout-"));
  const fetcher = (async (_input: RequestInfo | URL, init?: RequestInit) =>
    new Promise<Response>((_resolve, reject) => {
      init?.signal?.addEventListener("abort", () => {
        reject(new DOMException("aborted", "AbortError"));
      });
    })) as typeof fetch;

  await assert.rejects(
    () =>
      downloadImages(
        ["https://images.example/result.png"],
        directory,
        "task-download-timeout",
        1_024,
        fetcher,
        10,
        "request-download",
      ),
    (error: unknown) =>
      error instanceof GrsaiError &&
      error.code === "DOWNLOAD_TIMEOUT" &&
      error.phase === "download" &&
      error.requestId === "request-download",
  );
});

test("结果响应体读取也受下载超时约束", async () => {
  const directory = await mkdtemp(join(tmpdir(), "grsai-body-timeout-"));
  const fetcher = (async (_input: RequestInfo | URL, init?: RequestInit) => {
    const stream = new ReadableStream<Uint8Array>({
      start(controller) {
        const fail = () =>
          controller.error(new DOMException("aborted", "AbortError"));
        const fallback = setTimeout(fail, 50);
        init?.signal?.addEventListener("abort", () => {
          clearTimeout(fallback);
          fail();
        });
      },
    });
    return new Response(stream, {
      headers: { "Content-Type": "image/png" },
    });
  }) as typeof fetch;

  await assert.rejects(
    () =>
      downloadImages(
        ["https://images.example/result.png"],
        directory,
        "task-body-timeout",
        1_024,
        fetcher,
        10,
        "request-body",
      ),
    (error: unknown) =>
      error instanceof GrsaiError &&
      error.code === "DOWNLOAD_TIMEOUT" &&
      error.phase === "download",
  );
});
