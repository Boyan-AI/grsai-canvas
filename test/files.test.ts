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
