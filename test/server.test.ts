import assert from "node:assert/strict";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { test } from "node:test";
import type { GrsaiConfig } from "../src/config.js";
import { GrsaiClient } from "../src/grsai-client.js";
import { createServer } from "../src/server.js";

/** 创建 MCP 协议测试所需配置。 */
function testConfig(): GrsaiConfig {
  return {
    apiKey: "test-key",
    baseUrl: "https://api.example.test",
    requestTimeoutMs: 1_000,
    pollIntervalMs: 1,
    maxReferenceImageBytes: 1_024,
    maxDownloadBytes: 1_024,
  };
}

test("MCP 暴露生成与查询工具并可完成原生任务", async () => {
  let resultQueries = 0;
  let submittedModel = "";
  const fetcher = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input);
    if (url.includes("/v1/api/generate")) {
      submittedModel = String(
        (JSON.parse(String(init?.body)) as { model?: unknown }).model ?? "",
      );
      return Response.json({ id: "task-mcp", status: "running" });
    }
    resultQueries += 1;
    return Response.json({
      id: "task-mcp",
      status: "succeeded",
      results: [{ url: "https://images.example/result.png" }],
    });
  }) as typeof fetch;
  const config = testConfig();
  const server = createServer(config, {
    client: new GrsaiClient(config, fetcher, async () => {}),
    fetcher,
  });
  const client = new Client({ name: "grsai-test", version: "1.0.0" });
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();

  await Promise.all([
    server.connect(serverTransport),
    client.connect(clientTransport),
  ]);
  try {
    const tools = await client.listTools();
    assert.deepEqual(
      tools.tools.map((tool) => tool.name).sort(),
      ["generate_image", "get_generation"],
    );

    const generated = await client.callTool({
      name: "generate_image",
      arguments: {
        prompt: "未来城市",
        wait: true,
        wait_timeout_seconds: 10,
      },
    });
    assert.equal(generated.isError, undefined);
    assert.equal(
      (generated.structuredContent as { status?: unknown } | undefined)?.status,
      "succeeded",
    );
    assert.equal(submittedModel, "gpt-image-2");
    assert.equal(resultQueries, 1);

    const queried = await client.callTool({
      name: "get_generation",
      arguments: { id: "task-mcp" },
    });
    assert.equal(queried.isError, undefined);
    assert.equal(
      (queried.structuredContent as { status?: unknown } | undefined)?.status,
      "succeeded",
    );
  } finally {
    await client.close();
    await server.close();
  }
});

test("编译后的 STDIO 服务在缺少密钥时仍可列出工具", async () => {
  const client = new Client({ name: "grsai-stdio-test", version: "1.0.0" });
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: ["dist/src/index.js"],
    env: { PATH: process.env.PATH ?? "" },
  });

  await client.connect(transport);
  try {
    const tools = await client.listTools();
    assert.deepEqual(
      tools.tools.map((tool) => tool.name).sort(),
      ["generate_image", "get_generation"],
    );
  } finally {
    await client.close();
  }
});
