# 画境

原生 macOS 图片/视频/文本客户端、Android 客户端与面向 Codex 的可迁移 Grsai Skill。画境参考 `image.grsai.ai` 的双栏工作台，提供本地历史画廊、参考图、模型参数、异步任务恢复、文本结果和结果保存；Python CLI 继续用于自动化与 Skill 调用。

仓库按客户端分层：`macos/` 为 macOS 客户端，`android/` 为 Android 客户端；`skills/` 与 `test/` 为跨平台 Skill 和 Python 验证。

## Android 客户端（开发中）

Android 版本位于 `android/`，使用 Kotlin、Jetpack Compose 和 Android SDK 36，复用 macOS 版本的 Grsai 任务契约与费用边界。当前已包含 API Key 的 Keystore 加密保存、原生图片、OpenAI 图片生成、图片编辑、`minimax-h3` 视频、OpenAI Chat、Gemini 普通/流式接口、参考图、历史任务持久化、任务轮询、后台 WorkManager 续查、结果媒体本地缓存和按媒体类型预览。

Android 构建依赖 Android Studio 或已配置的 Gradle/JDK；当前环境已完成 Debug APK 构建。开发阶段请使用 Mock 或测试 Key，点击生成会产生真实 Grsai 费用。

## macOS 客户端

运行环境：macOS 14 或更高版本、Swift 6.1 或更高版本。客户端只使用 SwiftUI、Foundation 和系统框架，不依赖第三方包，也不会嵌入 Python 运行时。

一键构建并安装到当前用户桌面：

```bash
./install-macos.sh
```

安装结果为桌面上的 `画境.app`。如果桌面存在旧的 `Grsai Canvas.app` 或同名 App，脚本会关闭并直接覆盖，安装完成后自动启动新版本。

一键构建并安装 Android Debug APK：

```bash
./install-android.sh
```

Android 脚本会调用 `android/gradlew` 或系统 Gradle 构建 Debug APK；检测到 adb 设备时会自动安装，否则只保留 APK。

macOS 构建可直接启动的本地 App：

```bash
cd macos
scripts/build-app.sh
open ".build/app/画境.app"
```

调试构建可传入 `debug`：

```bash
cd macos
scripts/build-app.sh debug
```

主要能力：

- 左侧历史与结果画廊，右侧为生成控制台。
- 支持文生图，以及 `minimax-h3` 文生视频；图片最多 8 张、视频最多 9 张 JPG、JPEG、PNG、WEBP 参考图。
- 工作台支持原生图片、原生视频、OpenAI 图片、图片编辑、OpenAI Chat、Gemini 和 Gemini 流式七种接口模式；文本响应会以文本卡片进入历史。
- 支持 gpt-image-2、gpt-image-2.5 系列与 nano-banana 系列，并按模型限制比例、像素尺寸、质量和透明背景组合。
- OpenAI 图片生成与编辑支持服务模型、质量和背景字段；Chat 支持文本/参考图与流式开关；Gemini 支持参考图和 generationConfig JSON。
- 提交成功后立即保存任务 ID，后续只查询同一 ID；应用重启后可恢复未完成任务。
- 成功图片或视频下载到 `~/Library/Application Support/Grsai Canvas/Images/`，支持 Finder 定位、另存为和按媒体类型预览。
- 历史元数据保存在 `~/Library/Application Support/Grsai Canvas/history.json`。

### 密钥与费用边界

当前 MVP 的 API Key 保存在应用自身的 UserDefaults 数据区，关闭应用后仍可读取；不会写入仓库、历史文件或日志。用户可在设置中主动清除。按产品取舍，这不是钥匙串加密存储，同一 macOS 用户可以读取本机应用数据。

点击“生成图像 · 可能产生费用”会提交真实 Grsai 任务。普通构建、启动和自动化测试不会访问 Grsai，也不会产生生图费用。提交超时且上游接收状态未知时，客户端会明确提示，不会自动重复提交；拿到任务 ID 后的轮询不会创建新任务。

客户端固定使用 HTTPS Grsai 节点和 HTTPS 结果地址。单张参考图最多 10 MB，内联参考图总计最多 8 MB，下载结果最多 50 MB。

### macOS 本地验证

```bash
cd macos
swift test
swift build
scripts/build-app.sh
```

测试使用内存 Stub 和临时目录，覆盖鉴权请求、异步提交、任务续查、提交超时语义、HTTPS 边界、模型参数、参考图、历史持久化和工作台编排。

## Codex Skill

接口维护以 [Grsai 接口维护契约](docs/grsai-api.md) 和 [Apifox 接口汇总](https://qmy27nhsd9.apifox.cn/llms.txt) 为准。

## 当前能力

- `generate`：按提示词生成或编辑图片，或使用 `minimax-h3` 生成异步视频；视频支持比例、480p/768p/1080p、1–15 秒时长、seed 和参考音频。
- `edit`：调用 multipart 图片编辑接口。
- `chat`：调用 OpenAI Chat，支持普通和 SSE 流式响应。
- `gemini`：调用 Gemini `generateContent`，支持普通和 SSE 流式响应。
- `get`：按原生任务 ID 查询进度和结果，不创建新任务。
- `doctor`：检查 Python 运行时和密钥配置，不发网络请求。
- 参考图支持 HTTPS URL、data URL 和本地图片文件。
- 结果 URL 可按需下载到绝对路径，并限制响应大小、遵循安全重定向、避免覆盖已有文件。
- 结果包含 `media_type`，视频下载器支持 MP4、MOV 和 WebM，视频预览不会进入图片组件。
- 错误保留请求 ID、阶段、重试性、超时和上游请求 ID 等安全诊断；不会返回 API Key 或完整上游响应体。

## 安装

只需把 `skills/grsai-image-generation/` 目录复制到宿主的 Skill 目录，并保留其中的 `SKILL.md`、`agents/openai.yaml` 和 `scripts/`。Skill 目录可以被复制到任意位置，脚本通过同目录导入，不依赖仓库根目录。

运行时要求：

- Python 3.9 或更高版本。
- 仅使用 Python 标准库，无需 pip、Node 或 npm 依赖。
- 不需要注册 MCP 服务，也不需要为安装重启 Codex。

这是“首次配置密钥后即可使用”，不是把密钥写入 Skill 的零配置方案。

## 首次配置

在实际运行 CLI 的宿主环境中配置 `GRSAI_API_KEY`，不要把真实值写入仓库、Skill 文件、命令参数或日志：

```bash
export GRSAI_API_KEY="你的密钥"
```

默认节点为 `https://grsai.dakka.com.cn`。如确有需要，可配置其他 HTTPS 节点：

```bash
export GRSAI_BASE_URL="https://grsaiapi.com"
```

可选的分阶段预算和安全上限：

```bash
export GRSAI_SUBMIT_TIMEOUT_MS="120000"
export GRSAI_STATUS_TIMEOUT_MS="30000"
export GRSAI_SYNC_GENERATION_TIMEOUT_MS="300000"
export GRSAI_DOWNLOAD_TIMEOUT_MS="45000"
export GRSAI_POLL_INTERVAL_MS="2000"
export GRSAI_MAX_REFERENCE_BYTES="10485760"
export GRSAI_MAX_REFERENCE_TOTAL_BYTES="8388608"
export GRSAI_MAX_DOWNLOAD_BYTES="52428800"
```

旧版 `GRSAI_REQUEST_TIMEOUT_MS` 仍可作为提交、查询和同步生成的统一回退值。密钥只从环境变量读取，不支持参数、配置文件或持久化注入。

## CLI 用法

将 `GRSAI_SKILL_DIR` 设置为已安装的 `grsai-image-generation` 目录：

```bash
GRSAI_SKILL_DIR="/absolute/path/to/grsai-image-generation"
python3 "$GRSAI_SKILL_DIR/scripts/grsai_image.py" doctor
python3 "$GRSAI_SKILL_DIR/scripts/grsai_image.py" --help
```

常用示例：

```bash
# 默认 gpt-image-2，原生后端等待 180 秒
python3 "$GRSAI_SKILL_DIR/scripts/grsai_image.py" generate \
  --prompt "1:1 的未来城市夜景" \
  --aspect-ratio 1:1

# nano-banana 2K，并传入两张参考图
python3 "$GRSAI_SKILL_DIR/scripts/grsai_image.py" generate \
  --model nano-banana-2 \
  --image-size 2K \
  --prompt "把主体改成水彩风格" \
  --reference-image https://images.example/a.png \
  --reference-image /absolute/path/reference.png

# 提交后稍后续查
python3 "$GRSAI_SKILL_DIR/scripts/grsai_image.py" generate \
  --prompt "海边灯塔" \
  --no-wait
python3 "$GRSAI_SKILL_DIR/scripts/grsai_image.py" get \
  --id "task-id" \
  --wait-timeout-seconds 60

# 生成并下载到本地绝对目录
python3 "$GRSAI_SKILL_DIR/scripts/grsai_image.py" generate \
  --prompt "产品静物" \
  --output-dir "/absolute/output/directory"
```

完整参数和允许值以 `python3 "$GRSAI_SKILL_DIR/scripts/grsai_image.py" --help` 及各子命令帮助为准。`--wait-timeout-seconds` 只控制拿到原生任务 ID 后的轮询预算：`generate` 允许 5–300 秒，`get` 允许 0–300 秒；`--output-dir` 必须是绝对路径。

## 输出、费用与恢复

- 除帮助文本外，标准输出只包含一个 JSON 对象；诊断摘要写标准错误。
- 退出码 `0`：成功、任务仍在运行或 `doctor` 完成；`2`：输入/配置错误；`3`：上游、生成或下载错误。
- `generate` 默认等待；轮询超时会返回 `status: "running"` 和已有任务 ID。使用 `get` 续查，不要重新提交同一请求。
- 提交或同步接口超时若返回 `acceptance_unknown: true`，上游可能已接收或计费。保留 `request_id`，未经明确授权不得自动重试。
- `openai-compatible` 是同步接口，返回的 `openai-*` ID 只是本地合成元数据，不能交给 `get`。
- 生图可能产生费用。用户明确要求时可执行；意图不明确时先确认。网络授权也不能视为付费授权。

## 模型、参考图与安全边界

- `--image-size` 只用于 nano-banana 系列；gpt-image-2/gpt-image-2.5 使用文档比例或像素值，VIP/Flare/Sunburst 支持文档定义的 1K–4K 像素尺寸。
- OpenAI 兼容后端只接受 `auto` 或上述标准像素值；需要比例时使用原生后端。
- 本地参考图和 data URL 会内联进请求。单张默认最多 10 MB，内联总量默认最多 8 MB；大图优先使用 HTTPS URL。
- 只允许 HTTPS 上游和结果地址；本地 HTTP 仅可由测试注入，不作为生产开关。
- 生图模型不保证精确排版或逐帧动画。Sprite sheet、固定网格和严格透明补格应由本地程序确定性合成、裁切和校验。

## 本地验证

测试只使用本地 mock，不访问真实 Grsai，也不会产生费用：

```bash
python3 -m unittest discover -s test/python -p 'test_*.py' -v
python3 -m py_compile skills/grsai-image-generation/scripts/*.py
```

隔离验证时只复制 `skills/grsai-image-generation/`，在副本中运行 `doctor`、`--help` 和参数拒绝路径即可确认 Skill 不依赖仓库外绝对路径。
