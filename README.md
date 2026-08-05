# Grsai Image MCP

面向 Codex 的本地 STDIO MCP 服务，封装 Grsai 图片生成、异步任务查询、参考图上传和结果下载。

## 能力

- `generate_image`：调用 nano-banana 或 gpt-image-2 系列生成图片，可等待任务并保存到本地目录。
- `get_generation`：按任务 ID 查询进度和结果 URL，不创建新任务。
- 支持 HTTPS URL、data URL 和本地文件作为参考图。
- 同时实现 Grsai 原生接口和 OpenAI 兼容的 `/v1/images/generations` 接口。

`/v1/chat/completions` 不属于生图主链路，因此未作为 MCP 工具暴露。

## 安装与构建

要求 Node.js 20 或更高版本。

```bash
npm install
npm run build
```

设置 Grsai API Key。不要将真实值写入仓库或日志：

```bash
export GRSAI_API_KEY="你的密钥"
```

默认使用国内节点 `https://grsai.dakka.com.cn`。如需全球节点：

```bash
export GRSAI_BASE_URL="https://grsaiapi.com"
```

## Codex 配置

### macOS 桌面端

从 Dock 或 Finder 启动的 Codex 不应依赖终端会话中的临时环境变量。最简单的方案是在全局 `~/.codex/config.toml` 中为 MCP 直接配置环境变量：

```toml
[mcp_servers.grsai-image]
command = "node"
args = ["/Users/boyan/Desktop/Tools/image-gen/dist/src/index.js"]
tool_timeout_sec = 360
default_tools_approval_mode = "writes"

[mcp_servers.grsai-image.env]
GRSAI_API_KEY = "你的密钥"
```

该方案会在个人配置文件中明文保存 key，但不会进入项目仓库。填写后重启 Codex。

### 环境变量转发（CLI）

将以下配置加入全局 `~/.codex/config.toml`，或可信项目的 `.codex/config.toml`：

```toml
[mcp_servers.grsai-image]
command = "node"
args = ["/Users/boyan/Desktop/Tools/image-gen/dist/src/index.js"]
env_vars = ["GRSAI_API_KEY", "GRSAI_BASE_URL"]
tool_timeout_sec = 360
default_tools_approval_mode = "writes"
```

重启 Codex 后，可通过 `/mcp` 或 `codex mcp list` 检查连接状态。

### 默认生图路由

本机的配套 Skill 安装在 `~/.agents/skills/grsai-image-generation`，并通过全局 Codex 规则把未指定提供方的普通生图请求路由到 Grsai。系统内置 `imagegen` Skill 已在 `~/.codex/config.toml` 中禁用，以避免工具竞争；用户明确指定其他提供方时仍遵循用户选择。

修改全局 Skill 或 `skills.config` 后必须重启 Codex。重启后可以直接说“生成一张图片”，不需要在提示词中写 Grsai。

## 使用示例

- “用 nano-banana-2 生成一张 16:9 的未来城市夜景，保存到当前项目的 `generated` 目录。”
- “以 `/absolute/path/reference.png` 为参考图，把画面改成水彩风格。”
- “查询 Grsai 任务 `task-id` 的生成结果。”

生成图片可能产生费用。`generate_image` 被标记为外部写操作，Codex 应在用户未明确要求生图时先确认。

## 验证

```bash
npm test
npm run build
```

测试使用本地 mock，不会调用真实 Grsai 接口或产生费用。
