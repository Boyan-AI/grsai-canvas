---
name: grsai-image-generation
description: Use when the user asks to generate, create, edit, transform, or download images or videos through Grsai, including reference-media workflows or queries for an existing Grsai task, when no other provider is explicitly selected.
---

# Grsai Image Generation

通过 Skill 目录内置的 Python CLI 调用 Grsai 图片、视频、图片编辑和文本接口。脚本只依赖 Python 3.9+ 标准库，不依赖 Node、npm、MCP 注册或仓库外路径。

接口维护源为 [Grsai Apifox 接口汇总](https://qmy27nhsd9.apifox.cn/llms.txt)，项目覆盖矩阵见仓库 `docs/grsai-api.md`。

## 运行入口

先把 `GRSAI_SKILL_DIR` 设置为当前 Skill（即本文件所在目录）的绝对路径。所有命令都使用通用 `python3`：

```bash
GRSAI_SKILL_DIR="/absolute/path/to/grsai-image-generation"
python3 "$GRSAI_SKILL_DIR/scripts/grsai_image.py" doctor
python3 "$GRSAI_SKILL_DIR/scripts/grsai_image.py" --help
```

`doctor` 只检查 Python 版本和 `GRSAI_API_KEY` 是否配置，不发网络请求。首次使用前在宿主环境配置密钥：

```bash
export GRSAI_API_KEY="你的密钥"
```

不要把密钥写入 Skill、仓库、命令参数、提示词或日志，也不要在回复中回显密钥值。

## 调用流程

1. 先运行 `doctor`，只检查 Python 和密钥配置，不发网络请求。
2. 首次付费提交前获得用户明确授权。若宿主已知限制外网，同时申请范围明确的 Grsai 网络权限，不要先在已知无网环境提交付费任务。用户指定其他提供方时遵循用户选择。
3. 常规请求使用原生后端和默认 `gpt-image-2`。优先用 `generate --no-wait` 提交并立即保存 `id` 和 `request_id`，再用 `get` 等待；这样即使长等待或输出中断，仍可恢复同一任务。CLI 的等待默认值是 180 秒，但不应作为可恢复流程的默认选择。
4. 保持提交命令的 JSON 输出可观测。宿主提供 raw/proxy 模式时优先使用；创建输出目录、提交、查询和下载分开执行，不要把它们串成一条复合 shell 命令，以免丢失任务 ID 或失败阶段。
5. 需要 nano-banana 的 2K/4K 时显式传入 `--model` 和 `--image-size`；GPT Premium 的质量、透明背景和像素尺寸使用 `--quality`、`--background` 和 `--aspect-ratio`。需要参考图时重复传入 `--reference-image`，优先使用 HTTPS URL；本地文件或 data URL 会内联并受大小限制。
6. 原生任务返回 `running` 时，只用同一个任务 ID 调用 `get`。轮询超时返回 `status: running` 是正常状态；轮询不会新建生图任务，不要因进度低或等待超时重新提交。
7. 任务成功后展示 HTTPS 结果 URL。若采用 `--no-wait` 且需要本地文件，先单独创建输出目录，再下载 `get` 返回的 URL 并校验文件类型和尺寸。只有在网络与输出捕获都可靠时，才用 `generate --output-dir` 的同步下载流程。
8. 错误含 `acceptance_unknown: true` 时，上游可能已经接收或计费；保留 `request_id`，停止自动重试，明确告知重试可能产生重复费用，并重新获得用户授权。若需确认是否计费，查看 Grsai 后台任务或账单，不要从客户端错误臆测。

视频模型使用原生异步接口：`minimax-h3` 支持 `--aspect-ratio portrait|landscape`、`--resolution 480p|768p|1080p`、`--duration 1..15`（1080p 最长 10 秒）；`agnes-video-2.5` 支持 `--aspect-ratio 16:9|9:16|21:9|4:3|1:1|3:4`、`--resolution 720p|1080p|2k`、`--duration 4..12`。两者均可传 `--seed`、最多 9 张参考图和最多 3 个 `--reference-audio`。视频任务输出包含 `media_type: "video"`，下载器按响应签名保存视频文件。

典型命令（参数名称与 `--help` 一致）：

```bash
# 原生后端：提交后立即返回任务 ID（推荐）
python3 "$GRSAI_SKILL_DIR/scripts/grsai_image.py" generate \
  --prompt "水彩风格的海边灯塔" \
  --aspect-ratio 16:9 \
  --no-wait

# 用已有任务 ID 续查，最多等待 60 秒
python3 "$GRSAI_SKILL_DIR/scripts/grsai_image.py" get \
  --id "task-id" \
  --wait-timeout-seconds 60

# 同步等待并下载到本地（仅用于网络和输出捕获可靠的环境）
python3 "$GRSAI_SKILL_DIR/scripts/grsai_image.py" generate \
  --prompt "产品静物" \
  --output-dir "/absolute/output/directory"

# 提交 minimax-h3 视频任务并下载 MP4/MOV/WebM 结果
python3 "$GRSAI_SKILL_DIR/scripts/grsai_image.py" generate \
  --model minimax-h3 \
  --prompt "镜头缓慢推进的山间湖泊" \
  --aspect-ratio landscape \
  --resolution 768p \
  --duration 5 \
  --reference-audio "https://audio.example/reference.mp3" \
  --output-dir "/absolute/output/directory"

# 视频任务也可用同一个任务 ID 续查
python3 "$GRSAI_SKILL_DIR/scripts/grsai_image.py" get \
  --id "task-id" --media-type video --wait-timeout-seconds 60 \
  --output-dir "/absolute/output/directory"
```

兼容后端是同步接口，仅在确有需要时使用：

```bash
python3 "$GRSAI_SKILL_DIR/scripts/grsai_image.py" generate \
  --prompt "海边日落" \
  --backend openai-compatible \
  --aspect-ratio 1024x1024
```

`openai-compatible` 返回本地合成 ID，不能用 `get --id` 查询；需要比例或原生 `mask` 时使用原生后端。

文本和编辑接口：

```bash
# OpenAI 图片编辑，image 可为本地文件或 HTTPS URL
python3 "$GRSAI_SKILL_DIR/scripts/grsai_image.py" edit \
  --model gpt-image-2 --prompt "去掉背景并保留主体" \
  --image "/absolute/input.png" --background transparent

# OpenAI Chat；--stream 会合并 SSE 增量文本
python3 "$GRSAI_SKILL_DIR/scripts/grsai_image.py" chat \
  --model gemini-3.1-pro --message "请介绍这张图" --stream

# Gemini generateContent；--stream 对应 streamGenerateContent
python3 "$GRSAI_SKILL_DIR/scripts/grsai_image.py" gemini \
  --model gemini-3.1-pro --prompt "写一段产品文案" --stream
```

Chat、Gemini 和编辑请求会返回稳定 JSON 文本或图片结果；流式接口在 CLI 内合并响应，便于历史记录和自动化处理。macOS 与 Android 工作台也提供相同的七种接口模式，详情见 `docs/grsai-api.md`。

## 输出与错误

- 除 `--help` 外，标准输出只包含一个 UTF-8 JSON 对象；诊断摘要写入标准错误，不输出 traceback。
- 退出码 `0` 表示成功、仍在运行或 `doctor` 已完成；`2` 表示参数/配置错误；`3` 表示上游、生成或下载失败。
- 成功或运行中的结果包含 `request_id`、`id`、`status`、`urls`、`files`，运行中可能包含 `progress`。
- 结果同时包含 `media_type`：图片为 `image`，原生视频模型为 `video`，Chat/Gemini 为 `text`。
- 失败结果包含 `status: "failed"`、`urls: []`、`files: []` 以及 `error.code`、`message`、`phase`、`backend`、`retryable`、`acceptance_unknown`；可选字段用于 HTTP 状态、上游请求 ID 和超时诊断。
- 向用户展示结果 URL 和已下载的本地路径；明确说明任务仍在运行、内容安全拦截或失败阶段，并保留任务 ID 供续查。

## 安全与边界

- 只允许 HTTPS 的 Grsai 节点、参考图 URL 和结果下载 URL；测试注入的本地 mock 不代表生产配置。
- 单张本地参考图默认最多 10 MB，内联参考图解码总量默认最多 8 MB；大图应先压缩或改用 HTTPS URL。
- `--image-size` 只用于 nano-banana 系列。`gpt-image-2` 和 `gpt-image-2.5` 接受文档比例或 1K 像素值；`gpt-image-2-vip`、`gpt-image-2.5-flare` 和 `gpt-image-2.5-sunburst` 接受文档定义的像素尺寸，VIP 还接受满足约束的自定义像素值。
- `--quality` 按模型能力校验；`--background transparent` 只用于 GPT Premium；原生 `--mask` 只接受 HTTPS 地址。
- 视频模型只使用原生后端；视频参数为 `--aspect-ratio`、`--resolution`、`--duration`、`--seed`，音频参考使用 `--reference-audio`，支持 HTTPS、data URL 和本地 AAC/FLAC/M4A/MP3/OGG/OPUS/WAV 文件。
- 结果下载器支持图片和 MP4/MOV/WebM，单文件默认最多 50 MB；视频下载不绕过 HTTPS、重定向和大小校验。
- OpenAI 兼容后端使用 `size`、`quality` 和 `background` 字段。
- 生图不是精确排版或逐帧动画引擎。Sprite sheet、固定网格和严格透明补格应由本地程序确定性合成与校验。
- 如果宿主沙箱阻止外部网络，按宿主规则申请范围明确的网络授权，并提醒该操作可能产生费用；不要为了绕过限制切换到其他供应商。
