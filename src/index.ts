#!/usr/bin/env node
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { loadConfig } from "./config.js";
import { createServer } from "./server.js";

/** 启动 STDIO MCP 服务；stdout 专用于协议，诊断信息仅写 stderr。 */
async function main(): Promise<void> {
  const config = loadConfig();
  const server = createServer(config);
  await server.connect(new StdioServerTransport());
}

main().catch((error: unknown) => {
  const message = error instanceof Error ? error.message : "未知启动错误";
  console.error(`Grsai MCP 启动失败：${message}`);
  process.exitCode = 1;
});
