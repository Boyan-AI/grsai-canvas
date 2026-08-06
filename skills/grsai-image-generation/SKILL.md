---
name: grsai-image-generation
description: Use when the user asks to generate, create, edit, transform, or download raster images through Grsai, including reference-image workflows or queries for an existing Grsai task, when no other provider is explicitly selected.
---

# Grsai Image Generation

通过 Skill 目录内置的 Python CLI 调用 Grsai 生图接口。脚本只依赖 Python 3.9+ 标准库，不依赖 Node、npm、MCP 注册或仓库外路径。

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

1. 用户明确要求生成或编辑图片时，可直接执行生成；如果请求没有明确授权付费生图，先确认。用户指定其他提供方时遵循用户选择。
2. 常规请求使用原生后端和默认 `gpt-image-2`，默认等待 180 秒。需要 nano-banana 或 2K/4K 时显式传入 `--model` 和 `--image-size`。
3. 需要参考图时重复传入 `--reference-image`，优先使用 HTTPS URL；本地文件或 data URL 会内联并受大小限制。
4. 需要本地文件时传入绝对路径 `--output-dir`；否则直接返回结果 URL。
5. 原生任务返回 `running` 且需要继续等待时使用同一个任务 ID 查询。轮询超时返回 `status: running`，之后使用 `get`，绝不重新提交同一请求。
6. 错误含 `acceptance_unknown: true` 时，上游可能已经接收或计费；保留 `request_id`，不要自动重试，除非用户明确授权。

典型命令（参数名称与 `--help` 一致）：

```bash
# 原生后端，等待完成并只返回 URL
python3 "$GRSAI_SKILL_DIR/scripts/grsai_image.py" generate \
  --prompt "未来城市夜景" \
  --aspect-ratio 16:9

# 提交后立即返回任务 ID
python3 "$GRSAI_SKILL_DIR/scripts/grsai_image.py" generate \
  --prompt "水彩风格的海边灯塔" \
  --no-wait

# 用已有任务 ID 续查，最多等待 60 秒
python3 "$GRSAI_SKILL_DIR/scripts/grsai_image.py" get \
  --id "task-id" \
  --wait-timeout-seconds 60

# 下载到本地（目录必须是绝对路径）
python3 "$GRSAI_SKILL_DIR/scripts/grsai_image.py" generate \
  --prompt "产品静物" \
  --output-dir "/absolute/output/directory"
```

兼容后端是同步接口，仅在确有需要时使用：

```bash
python3 "$GRSAI_SKILL_DIR/scripts/grsai_image.py" generate \
  --prompt "海边日落" \
  --backend openai-compatible \
  --aspect-ratio 1024x1024
```

`openai-compatible` 返回本地合成 ID，不能用 `get --id` 查询；比例值应改用原生后端。

## 输出与错误

- 除 `--help` 外，标准输出只包含一个 UTF-8 JSON 对象；诊断摘要写入标准错误，不输出 traceback。
- 退出码 `0` 表示成功、仍在运行或 `doctor` 已完成；`2` 表示参数/配置错误；`3` 表示上游、生成或下载失败。
- 成功或运行中的结果包含 `request_id`、`id`、`status`、`urls`、`files`，运行中可能包含 `progress`。
- 失败结果包含 `status: "failed"`、`urls: []`、`files: []` 以及 `error.code`、`message`、`phase`、`backend`、`retryable`、`acceptance_unknown`；可选字段用于 HTTP 状态、上游请求 ID 和超时诊断。
- 向用户展示结果 URL 和已下载的本地路径；明确说明任务仍在运行、内容安全拦截或失败阶段，并保留任务 ID 供续查。

## 安全与边界

- 只允许 HTTPS 的 Grsai 节点、参考图 URL 和结果下载 URL；测试注入的本地 mock 不代表生产配置。
- 单张本地参考图默认最多 10 MB，内联参考图解码总量默认最多 8 MB；大图应先压缩或改用 HTTPS URL。
- `--image-size` 只用于 nano-banana；gpt-image-2 使用 `--aspect-ratio` 的标准像素值 `1024x1024`、`1536x1024` 或 `1024x1536`。
- 生图不是精确排版或逐帧动画引擎。Sprite sheet、固定网格和严格透明补格应由本地程序确定性合成与校验。
- 如果宿主沙箱阻止外部网络，按宿主规则申请范围明确的网络授权，并提醒该操作可能产生费用；不要为了绕过限制切换到其他供应商。
