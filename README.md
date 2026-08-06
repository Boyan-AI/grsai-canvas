# Grsai Canvas

面向 Codex 的可迁移 Grsai 生图 Skill。运行链路是 Skill 目录内置的 Python CLI：支持原生异步生图、任务续查、参考图处理、结果下载和 OpenAI 兼容同步接口。

## 当前能力

- `generate`：按提示词生成或编辑图片，支持 nano-banana 与 gpt-image-2 系列。
- `get`：按原生任务 ID 查询进度和结果，不创建新任务。
- `doctor`：检查 Python 运行时和密钥配置，不发网络请求。
- 参考图支持 HTTPS URL、data URL 和本地图片文件。
- 结果 URL 可按需下载到绝对路径，并限制响应大小、遵循安全重定向、避免覆盖已有文件。
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

- `--image-size` 只用于 nano-banana 系列；gpt-image-2 使用标准像素值 `1024x1024`、`1536x1024`、`1024x1536`，或原生后端的比例值。
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
