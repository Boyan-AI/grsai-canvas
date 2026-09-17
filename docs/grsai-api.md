# Grsai 接口维护契约

本文档记录项目当前依据的 Grsai 接口来源和接入边界。维护接口参数前，先读取汇总文档，再核对对应的 Apifox 页面：

- 汇总：https://qmy27nhsd9.apifox.cn/llms.txt
- 节点：`https://grsai.dakka.com.cn`（国内）或 `https://grsaiapi.com`（全球）
- API Key：请求头使用 `Authorization: Bearer <API_KEY>`

## 当前已接入

### 原生异步图片生成

- `POST /v1/api/generate`
- `GET /v1/api/result?id=<task_id>`
- 模型：`nano-banana` 系列、`gpt-image-2`、`gpt-image-2-vip`、`gpt-image-2.5`、`gpt-image-2.5-flare`、`gpt-image-2.5-sunburst`
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

### OpenAI 图片生成兼容接口

- `POST /v1/images/generations`
- Python Skill 的 `--backend openai-compatible` 已接入 `image`、`size`、`quality` 和 `background` 字段。
- 该接口是同步响应；返回的本地合成 ID 不能交给原生 `get` 查询。

## 暂未接入

下列接口已出现在汇总文档中，但当前项目没有对应的媒体或对话领域模型：

- `POST /v1/images/edits`：multipart 图片编辑接口，后续需要单独设计文件上传和结果模型。
- `POST /v1beta/models/{model_name}:generateContent`：Gemini 官方格式。
- `POST /v1beta/models/{model_name}:streamGenerateContent`：Gemini 流式格式。
- `POST /v1/chat/completions`：OpenAI Chat Completions 格式。
- `POST /v1/api/generate` 的 `minimax-h3`：视频生成，字段包含 `audios`、`resolution`、`duration` 和 `seed`，不能直接复用当前图片历史结构。

接入上述能力时，应先增加媒体类型、结果下载校验和历史持久化契约，再改工作台 UI；不要把视频 URL 当作图片直接预览。

## 本地验证

以下命令只使用本地 Mock，不访问 Grsai，也不会产生费用：

```bash
python3 -m unittest discover -s test/python -p 'test_*.py' -v
python3 -m py_compile skills/grsai-image-generation/scripts/*.py
cd macos && swift test
```

最后核对文档源是否有字段变化，并同步更新 `skills/grsai-image-generation/`、macOS/Android 模型清单和测试。真实生图联调必须单独确认，因为提交接口可能产生费用。
