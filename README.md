# Grsai Canvas

面向 Codex 的本地 STDIO MCP 服务，封装 Grsai 图片生成、异步任务查询、参考图上传和结果下载。

## 能力

- `generate_image`：调用 nano-banana 或 gpt-image-2 系列生成图片，可等待任务并保存到本地目录。
- `get_generation`：按任务 ID 查询进度和结果 URL，不创建新任务。
- 支持 HTTPS URL、data URL 和本地文件作为参考图。
- 同时实现 Grsai 原生接口和 OpenAI 兼容的 `/v1/images/generations` 接口。
- 失败响应包含本地请求 ID、故障阶段、耗时、超时预算和上游请求 ID 等安全诊断字段。

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

可按网络和 MCP 客户端预算调整分阶段超时：

```bash
export GRSAI_SUBMIT_TIMEOUT_MS="120000"
export GRSAI_STATUS_TIMEOUT_MS="30000"
export GRSAI_SYNC_GENERATION_TIMEOUT_MS="300000"
export GRSAI_DOWNLOAD_TIMEOUT_MS="45000"
```

默认预算分别是异步提交 120 秒、状态查询 30 秒、同步生成 300 秒和结果下载 45 秒。旧版 `GRSAI_REQUEST_TIMEOUT_MS` 仍可作为提交、查询和同步生成的统一回退值，但不推荐继续使用。修改后应确保“提交或同步生成 + 轮询 + 下载”的总预算小于 MCP `tool_timeout_sec`。

## Codex 配置

### macOS 桌面端

从 Dock 或 Finder 启动的 Codex 不应依赖终端会话中的临时环境变量。最简单的方案是在全局 `~/.codex/config.toml` 中为 MCP 直接配置环境变量：

```toml
[mcp_servers.grsai-image]
command = "node"
args = ["/Users/boyan/Desktop/Tools/grsai-canvas/dist/src/index.js"]
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
args = ["/Users/boyan/Desktop/Tools/grsai-canvas/dist/src/index.js"]
env_vars = ["GRSAI_API_KEY", "GRSAI_BASE_URL"]
tool_timeout_sec = 360
default_tools_approval_mode = "writes"
```

重启 Codex 后，可通过 `/mcp` 或 `codex mcp list` 检查连接状态。

### 默认生图路由

本机的配套 Skill 安装在 `~/.agents/skills/grsai-image-generation`，并通过全局 Codex 规则把未指定提供方的普通生图请求路由到 Grsai。常规 1K 生图默认使用 `gpt-image-2`；需要 Nano Banana 或 2K/4K 输出时应显式指定对应模型。系统内置 `imagegen` Skill 已在 `~/.codex/config.toml` 中禁用，以避免工具竞争；用户明确指定其他提供方时仍遵循用户选择。

修改全局 Skill 或 `skills.config` 后必须重启 Codex。重启后可以直接说“生成一张图片”，不需要在提示词中写 Grsai。

## 使用示例

- “生成一张 1:1 的未来城市夜景，保存到当前项目的 `generated` 目录。”
- “用 nano-banana-2 生成一张 4K 的未来城市夜景。”
- “以 `/absolute/path/reference.png` 为参考图，把画面改成水彩风格。”
- “查询 Grsai 任务 `task-id` 的生成结果。”

## 超时与异步语义

- `wait_timeout_seconds` 只控制原生接口返回任务 ID 后的轮询时间，不控制任务提交、同步生成或下载。
- 原生接口查询超时但已有任务 ID 时，工具返回 `status: running`，可稍后使用 `get_generation`，不要重新创建付费任务。
- 提交或同步生成超时且没有任务 ID 时，错误中的 `acceptance_unknown: true` 表示上游可能已经接收或计费。应使用 `request_id` 联查日志或账单，不要盲目重试。
- `openai-compatible` 是同步接口，不返回可供 `get_generation` 查询的真实任务 ID；优先使用默认 `native` 后端。

错误响应的 `phase` 为 `input`、`submit`、`poll`、`sync_generate` 或 `download`，可用于快速定位失败阶段。服务不会在错误中返回 API Key 或完整上游响应体。

## 输入与尺寸边界

- 本地文件和 data URL 会内联进 JSON。单张默认最多 10 MB，所有内联参考图解码后合计默认最多 8 MB；可用 `GRSAI_MAX_REFERENCE_BYTES` 和 `GRSAI_MAX_REFERENCE_TOTAL_BYTES` 调整。
- 多张大图应先缩小或压缩；已有安全 HTTPS 地址时优先传 URL，避免 Base64 约 33% 的体积膨胀。
- `gpt-image-2` 系列像素值仅接受 `1024x1024`、`1536x1024`、`1024x1536`。比例参数由供应商按 best-effort 方式处理，不承诺任意精确像素映射。
- OpenAI 兼容后端仅接受 `auto` 或上述标准像素值；需要比例参数时使用原生后端。
- `image_size` 只适用于 nano-banana 系列；gpt-image-2 使用 `aspect_ratio`。

生图模型不是精确排版或逐帧动画引擎。Sprite Sheet、固定网格、严格透明补格等任务应拆成“生成角色素材或单组动作，再由本地程序确定性裁切、排版和校验”，不要依赖一次提示词精确完成最终图集。

生成图片可能产生费用。`generate_image` 被标记为外部写操作，Codex 应在用户未明确要求生图时先确认。

## 验证

```bash
npm test
npm run build
```

测试使用本地 mock，不会调用真实 Grsai 接口或产生费用。
