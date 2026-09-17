# Grsai 接口维护契约

本文档记录项目当前依据的 Grsai 接口来源和接入边界。维护接口参数前，先读取汇总文档，再核对对应的 Apifox 页面：

- 汇总：https://qmy27nhsd9.apifox.cn/llms.txt
- 节点：`https://grsai.dakka.com.cn`（国内）或 `https://grsaiapi.com`（全球）
- API Key：请求头使用 `Authorization: Bearer <API_KEY>`

## 当前已接入

### 原生异步图片生成

- `POST /v1/api/generate`
- `GET /v1/api/result?id=<task_id>`
- 模型：图片模型，以及视频模型 `minimax-h3`
- 通用字段：`model`、`prompt`、`images`、`aspectRatio`、`replyType: async`
- GPT 扩展字段：`quality`、`background: transparent`、原生接口 `mask`
- 返回：`id`、`status`、可选 `progress`、`results[].url`、`error`
- 状态：`running`、`violation`、`succeeded`、`failed`

Python Skill 会在请求前校验模型能力：

- `nano-banana` 使用 `aspectRatio` 加 `imageSize: 1K|2K|4K`。
- `gpt-image-2` 和 `gpt-image-2.5` 使用文档比例或 1K 像素值。
- `gpt-image-2-vip`、`gpt-image-2.5-flare`、`gpt-image-2.5-sunburst` 使用 `auto` 或文档像素值；VIP 允许满足边长、比例和像素总数约束的自定义像素值。
- `quality` 按模型能力表校验；透明背景只允许 GPT Premium 模型。
- 轮询只调用已有任务 ID，不会重新提交生成任务。

### 原生异步视频生成

- `POST /v1/api/generate` 使用 `model: minimax-h3`，查询仍使用 `GET /v1/api/result?id=<task_id>`。
- 请求字段：`prompt`、`aspectRatio: portrait|landscape|square`、`images`（最多 9 张）、`audios`（最多 3 个）、`resolution: 480p|768p|1080p`、`duration`（1–15 秒）、`replyType: async` 和可选 `seed`。
- `1080p` 时 `duration` 最多 10 秒；Python Skill 支持 HTTPS、data URL 和本地音频参考。
- 视频结果仍返回 `results[].url`，客户端以 `media_type: video` 保存历史并使用视频播放器预览；单文件下载上限继续为 50 MB。

### OpenAI 图片生成兼容接口

- `POST /v1/images/generations`
- Python Skill、macOS 和 Android 已接入 `model`、`prompt`、`size`、`quality` 和 `background` 字段。
- 该接口是同步响应；返回的本地合成 ID 不能交给原生 `get` 查询。

### OpenAI 图片编辑

- `POST /v1/images/edits`
- 使用 multipart/form-data 上传 `model`、`prompt`、`image`，可选 `quality`、`background`、`mask`。
- Python CLI 的 `edit`、macOS 和 Android UI 已接入；响应复用同步图片结果模型。

### Gemini 内容生成

- `POST /v1beta/models/{model_name}:generateContent`
- `POST /v1beta/models/{model_name}:streamGenerateContent`
- 请求使用 `contents[].parts[]`，图片使用 `inlineData`，可选 `generationConfig`。
- Python CLI 的 `gemini --stream`、macOS 的 Gemini/Gemini 流式模式和 Android 对应模式已接入。
- 流式传输层会把 SSE 增量合并为文本历史，保留完整结果供预览和恢复。

### OpenAI Chat

- `POST /v1/chat/completions`
- 请求使用 `model`、`messages` 和 `stream`；消息支持文本和 `image_url`。
- Python CLI 的 `chat --stream`、macOS Chat 模式和 Android Chat 模式已接入。
- SSE 增量会在客户端合并为一条文本结果；同步响应使用 `choices[].message.content`。

## 覆盖矩阵

| 接口 | Python CLI | macOS UI | Android UI | 结果 |
| --- | --- | --- | --- | --- |
| 原生图片生成 | `generate` | 原生图片 | 原生图片 | 异步图片任务 |
| GPT 图片生成 | `generate` / OpenAI 兼容 | OpenAI 图片 | OpenAI 图片 | 同步图片 |
| `minimax-h3` 视频 | `generate` | 原生视频 | 原生视频 | 异步视频 |
| 异步查询 | `get` | 自动轮询 | 自动轮询与后台续查 | 图片/视频 |
| Gemini `generateContent` | `gemini` | Gemini | Gemini | 文本 |
| Gemini `streamGenerateContent` | `gemini --stream` | Gemini 流式 | Gemini 流式 | 累积文本 |
| OpenAI Chat | `chat` | OpenAI Chat | OpenAI Chat | 文本 |
| OpenAI 图片编辑 | `edit` | 图片编辑 | 图片编辑 | 同步图片 |
| OpenAI 图片生成 | `generate --backend openai-compatible` | OpenAI 图片 | OpenAI 图片 | 同步图片 |

视频 URL 不能交给图片预览组件；新增媒体模型时需同步结果下载校验和历史持久化契约。

## 本地验证

以下命令只使用本地 Mock，不访问 Grsai，也不会产生费用：

```bash
python3 -m unittest discover -s test/python -p 'test_*.py' -v
python3 -m py_compile skills/grsai-image-generation/scripts/*.py
cd macos && swift test
cd android && ./gradlew :app:assembleDebug
```

最后核对文档源是否有字段变化，并同步更新 `skills/grsai-image-generation/`、macOS/Android 模型清单和测试。真实生图联调必须单独确认，因为提交接口可能产生费用。
