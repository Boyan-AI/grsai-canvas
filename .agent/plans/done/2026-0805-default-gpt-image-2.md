# Task: 默认切换到 gpt-image-2
Created: 2026-08-05
Status: completed
Execution Mode: solo

## 目标
将 Grsai MCP 与配套全局 Skill 的默认生图模型从 `nano-banana-2` 切换为成本更低的 `gpt-image-2`，并通过自动化和一次真实生图验证。

## 计划

### Step 1: 修改 MCP 默认模型与回归测试 [🟡 推荐默认档] [✅ 完成]
- 依赖: 无
- 可并行: 否
- 执行者: lead
- 写入范围:
  - src/server.ts
  - test/server.test.ts
- 关键决策: 只修改未显式指定模型时的默认值；继续尊重用户显式模型选择，不改变后端、模型白名单或接口契约。
- 验收:
  - 不传 `model` 时请求体使用 `gpt-image-2`
  - 显式指定其他模型时行为不变
- 执行记录: 已将 MCP schema 默认值改为 `gpt-image-2`；协议测试改为省略 `model` 并断言下游请求体实际收到 `gpt-image-2`。既有客户端测试继续覆盖显式模型传递；`npm test` 10 项通过。

### Step 2: 同步项目 Skill、全局 Skill 与文档 [🔴 必须确认档] [✅ 完成]
- 依赖: Step 1
- 可并行: 否
- 执行者: lead
- 写入范围:
  - skills/grsai-image-generation/SKILL.md
  - /Users/boyan/.agents/skills/grsai-image-generation/SKILL.md
  - README.md
- 关键决策: 默认模型改为 `gpt-image-2`；明确常规默认只使用其 1K 能力，需要 Nano Banana 或 2K/4K 时由用户显式选择其他模型；保持 Skill 简洁且不固化可能变化的积分价格。
- 验收:
  - 项目 Skill 与全局 Skill 内容一致
  - README 默认路由和示例与实现一致
  - 全局 Skill 通过 `quick_validate.py`
- 执行记录: 已将项目与用户级 Skill 的常规 1K 默认模型改为 `gpt-image-2`，保留显式模型优先，并说明 Nano Banana 用于用户明确选择或 2K/4K 场景；README 默认路由和示例已同步。两份 Skill 经 `cmp` 确认一致，并使用已有隔离虚拟环境通过 `quick_validate.py`。

### Step 3: 自动化验证 [🔵 自动档] [✅ 完成]
- 依赖: Step 2
- 可并行: 否
- 执行者: lead
- 写入范围:
  - 无
- 关键决策: 运行最相关的测试、构建、Skill 校验和差异检查，不调用线上接口。
- 验收:
  - `npm test` 通过
  - `npm run build` 通过
  - 项目与全局 Skill 校验通过
  - `git diff --check` 通过
- 执行记录: `npm test` 10 项通过，`npm run build` 独立通过；项目与用户级 Skill 均通过 `quick_validate.py` 且内容一致；`git diff --check` 通过，默认值检索只在 MCP schema 和两份 Skill 中命中 `gpt-image-2`。

### Step 4: 执行一次 gpt-image-2 真实冒烟测试 [🔴 必须确认档] [✅ 完成]
- 依赖: Step 3
- 可并行: 否
- 执行者: lead
- 写入范围:
  - generated/smoke/
- 关键决策: 用户已明确批准真实测试；仅提交一次 `gpt-image-2` 1K 任务，预计消耗 600 积分。若轮询超时，保留任务 ID 继续查询，不重复提交。
- 验收:
  - 任务成功并下载为本地图片
  - 验证文件格式、尺寸、大小和可视内容
- 执行记录: 通过 MCP `generate_image` 且不传 `model` 执行一次真实任务，调用前从 tools schema 验证默认值为 `gpt-image-2`。任务 `12-830de3c0-ac38-4385-8314-d3842c60e4a2` 成功，下载 PNG 为 1254×1254、765,700 字节；人工查看为白底中央绿色方块，与提示词一致。未重复提交任务，临时测试脚本已清理，生成目录由 Git 忽略。

### Step 5: 归档计划并提交 [🟡 推荐默认档] [✅ 完成]
- 依赖: Step 4
- 可并行: 否
- 执行者: lead
- 写入范围:
  - .agent/plans/active/2026-0805-default-gpt-image-2.md
  - .agent/plans/done/2026-0805-default-gpt-image-2.md
  - .git/
- 关键决策: 计划全部完成后仅暂存本任务文件，创建中文本地提交，不 push。
- 验收:
  - 活动计划已归档
  - 工作区干净且存在本地提交
- 执行记录: 已核对最终差异仅包含本计划文件、MCP 默认值、回归测试、项目 Skill 和 README；生成图片保持忽略。计划归档后仅暂存本任务文件并创建中文本地提交，不 push。

## 关键上下文
- 当前 MCP 工具 schema 和全局 Skill 均默认 `nano-banana-2`；前一次真实冒烟测试也显式使用该模型。
- Grsai 2026-08-05 官方模型页显示 `gpt-image-2` 为 600 积分/次、支持 1K，`nano-banana-2` 为 1200 积分/次、支持 1K/2K/4K。
- `gpt-image-2` 在当前实现中可通过原生 `/v1/api/generate` 使用；默认后端保持 `native`。
- 用户已在个人 Codex MCP `env` 中配置 API Key；密钥不得写入仓库、计划或日志。

## 已改动文件汇总
- .agent/plans/active/2026-0805-default-gpt-image-2.md（计划创建）
- src/server.ts（Step 1）
- test/server.test.ts（Step 1）
- skills/grsai-image-generation/SKILL.md（Step 2）
- README.md（Step 2）
