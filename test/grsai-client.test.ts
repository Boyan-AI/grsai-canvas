import assert from "node:assert/strict";
import { test } from "node:test";
import { loadConfig, type GrsaiConfig } from "../src/config.js";
import { GrsaiError } from "../src/errors.js";
import { GrsaiClient } from "../src/grsai-client.js";

/** 创建供单元测试使用的最小安全配置。 */
function testConfig(): GrsaiConfig {
  return {
    apiKey: "test-key",
    baseUrl: "https://example.test",
    submitTimeoutMs: 1_000,
    statusTimeoutMs: 1_000,
    syncGenerationTimeoutMs: 1_000,
    downloadTimeoutMs: 1_000,
    pollIntervalMs: 1,
    maxReferenceImageBytes: 1_024,
    maxReferenceTotalBytes: 2_048,
    maxDownloadBytes: 1_024,
  };
}

test("提交原生异步任务并携带 Bearer 鉴权", async () => {
  let authorization = "";
  let body = "";
  const fetcher = (async (_input: RequestInfo | URL, init?: RequestInit) => {
    authorization = new Headers(init?.headers).get("Authorization") ?? "";
    body = String(init?.body);
    return Response.json({ id: "task-1", status: "running", progress: 10 });
  }) as typeof fetch;
  const client = new GrsaiClient(testConfig(), fetcher);

  const result = await client.generate({
    model: "nano-banana-2",
    prompt: "一只猫",
    replyType: "async",
  });

  assert.equal(result.id, "task-1");
  assert.equal(authorization, "Bearer test-key");
  assert.equal(JSON.parse(body).prompt, "一只猫");
});

test("轮询任务直到成功", async () => {
  let calls = 0;
  const fetcher = (async () => {
    calls += 1;
    return Response.json(
      calls === 1
        ? { id: "task-2", status: "running", progress: 50 }
        : {
            id: "task-2",
            status: "succeeded",
            results: [{ url: "https://images.example/result.png" }],
          },
    );
  }) as typeof fetch;
  const client = new GrsaiClient(testConfig(), fetcher, async () => {});

  const result = await client.waitForResult("task-2", 1_000, 1);

  assert.equal(result.status, "succeeded");
  assert.equal(calls, 2);
});

test("失败响应被转换为稳定错误", async () => {
  const fetcher = (async () =>
    Response.json(
      { error: { message: "quota exceeded" } },
      { status: 429 },
    )) as typeof fetch;
  const client = new GrsaiClient(testConfig(), fetcher);

  await assert.rejects(
    () => client.getResult("task-3"),
    (error: unknown) =>
      error instanceof GrsaiError &&
      error.code === "HTTP_ERROR" &&
      error.retryable,
  );
});

test("OpenAI 兼容接口返回图片 URL", async () => {
  const fetcher = (async () =>
    Response.json({
      created: 123,
      data: [{ url: "https://images.example/result.png" }],
      usage: { total_tokens: 10 },
    })) as typeof fetch;
  const client = new GrsaiClient(testConfig(), fetcher);

  const result = await client.generateOpenAi({
    model: "gpt-image-2",
    prompt: "海边日落",
    response_format: "url",
  });

  assert.equal(result.data[0]?.url, "https://images.example/result.png");
});

test("缺少密钥时不会发出网络请求", async () => {
  let called = false;
  const fetcher = (async () => {
    called = true;
    return Response.json({});
  }) as typeof fetch;
  const client = new GrsaiClient({ ...testConfig(), apiKey: "" }, fetcher);

  await assert.rejects(
    () => client.getResult("task-without-key"),
    (error: unknown) =>
      error instanceof GrsaiError && error.code === "MISSING_API_KEY",
  );
  assert.equal(called, false);
});

test("异步提交超时会标明阶段、预算和接收状态未知", async () => {
  const config = { ...testConfig(), submitTimeoutMs: 10 };
  const fetcher = (async (_input: RequestInfo | URL, init?: RequestInit) =>
    new Promise<Response>((_resolve, reject) => {
      init?.signal?.addEventListener("abort", () => {
        reject(new DOMException("aborted", "AbortError"));
      });
    })) as typeof fetch;
  const client = new GrsaiClient(config, fetcher);
  await assert.rejects(
    () =>
      client.generate(
        { model: "gpt-image-2", prompt: "一只猫", replyType: "async" },
        { requestId: "request-submit", timeoutMs: 10 },
      ),
    (error: unknown) => {
      const diagnostic = error as GrsaiError & Record<string, unknown>;
      return (
        diagnostic.code === "REQUEST_TIMEOUT" &&
        diagnostic.phase === "submit" &&
        diagnostic.requestId === "request-submit" &&
        diagnostic.timeoutMs === 10 &&
        diagnostic.acceptanceUnknown === true
      );
    },
  );
});

test("同步兼容接口使用独立超时并标明可能已计费", async () => {
  const fetcher = (async (_input: RequestInfo | URL, init?: RequestInit) =>
    new Promise<Response>((_resolve, reject) => {
      init?.signal?.addEventListener("abort", () => {
        reject(new DOMException("aborted", "AbortError"));
      });
    })) as typeof fetch;
  const client = new GrsaiClient(testConfig(), fetcher);
  await assert.rejects(
    () =>
      client.generateOpenAi(
        { model: "gpt-image-2", prompt: "一只猫" },
        { requestId: "request-sync", timeoutMs: 12 },
      ),
    (error: unknown) => {
      const diagnostic = error as GrsaiError & Record<string, unknown>;
      return (
        diagnostic.phase === "sync_generate" &&
        diagnostic.timeoutMs === 12 &&
        diagnostic.acceptanceUnknown === true
      );
    },
  );
});

test("默认端到端超时预算小于 MCP 工具超时", () => {
  const config = loadConfig({ GRSAI_API_KEY: "test-key" });
  const pollBudgetMs = 180_000;
  const mcpToolTimeoutMs = 360_000;

  assert.ok(
    config.submitTimeoutMs + pollBudgetMs + config.downloadTimeoutMs <
      mcpToolTimeoutMs,
  );
  assert.ok(
    config.syncGenerationTimeoutMs + config.downloadTimeoutMs <
      mcpToolTimeoutMs,
  );
});
