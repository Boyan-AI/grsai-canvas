# Task: 提升 Grsai MCP 生图链路可靠性与可诊断性
Created: 2026-08-05
Status: completed
Execution Mode: solo

## 目标
在保持现有 MCP 工具名称与主流程兼容的前提下，修复超时语义割裂、失败不可诊断、大参考图请求失控和尺寸能力声明过宽的问题，并用自动化测试验证。

## 计划

<!--
Step 标题必须带两个标签：档位标签在前，状态标签在后。
- 档位：🔵 自动档 / 🟡 推荐默认档 / 🔴 必须确认档
- 状态：⬜ 待办 / 🔄 进行中 / ✅ 完成
- 可并行：`是` 表示依赖满足且写入范围不冲突时可与其他 Step 同时执行；`否` 表示独占执行
- 执行者：`lead` 表示主 session 负责；`parallel` 表示当前环境具备并行能力且用户已批准时可派发给独立子任务
- 写入范围：必须具体到目标 repo 内文件或目录，供调度器阻止并发覆盖；不要写“相关文件”
- `Execution Mode` 默认 `solo`；其他模式必须由主 session 先说明当前 Codex 环境的可用执行能力和兼容方式
审批时重点审 🔴 Step。
-->

### Step 1: 固化失败场景与接口契约测试 [🔵 自动档] [✅ 完成]
- 依赖: 无
- 可并行: 否
- 执行者: lead
- 写入范围:
  - test/grsai-client.test.ts
  - test/server.test.ts
  - test/files.test.ts
- 关键决策: 先用失败测试锁定提交超时、同步后端超时、阶段化错误、参考图总量和模型尺寸组合，避免只修表象。
- 验收:
  - 新增测试在旧实现上能准确暴露问题，且不调用真实计费接口。
- 验证结果: 新增 5 个本地 mock 回归测试；旧实现分别暴露聚合体积未限制、提交/同步超时无阶段信息、错误无 structuredContent、非标准尺寸未拦截。首次尺寸用例因旧实现进入默认轮询而中断，已改为 `wait: false`，确保测试快速失败且不悬挂。
<!-- 用户批注区：用户会在此下方加 `// BY ...` 行。创建/更新 plan 时此区留空，不得预填 // BY 标记或示例。 -->

### Step 2: 拆分 HTTP 阶段超时并返回可诊断错误 [🟡 推荐默认档] [✅ 完成]
- 依赖: Step 1
- 可并行: 否
- 执行者: lead
- 写入范围:
  - src/config.ts
  - src/errors.ts
  - src/grsai-client.ts
  - src/server.ts
  - src/download.ts
- 关键决策: 区分异步提交、状态查询、同步生成和结果下载的超时预算；`wait_timeout_seconds` 只表示拿到任务 ID 后的轮询预算。失败结果携带本地 correlation ID、阶段、耗时、超时值、backend、是否可能已被上游接收等安全字段，不记录密钥或完整响应体。
- 验收:
  - `wait: false`、原生轮询和兼容后端的超时语义可区分。
  - 超时响应能判断发生在输入处理、提交、轮询或下载阶段。
  - 总默认预算不超过 Codex 当前 360 秒 MCP 工具超时。
- 验证结果: 默认预算拆分为提交 120 秒、状态查询 30 秒、同步生成 300 秒、下载 45 秒；轮询单次查询受剩余总预算约束。错误响应新增本地 request ID、阶段、backend、耗时、超时、HTTP/upstream request ID 与 acceptance_unknown；已有任务的可重试查询故障返回 `running`。6 个相关 mock 测试通过。
<!-- 用户批注区：用户会在此下方加 `// BY ...` 行。创建/更新 plan 时此区留空，不得预填 // BY 标记或示例。 -->

### Step 3: 限制高风险输入与不可靠尺寸承诺 [🟡 推荐默认档] [✅ 完成]
- 依赖: Step 2
- 可并行: 否
- 执行者: lead
- 写入范围:
  - src/config.ts
  - src/contracts.ts
  - src/image-input.ts
  - src/server.ts
- 关键决策: 增加参考图聚合大小限制并给出可执行报错；保留 HTTPS URL 低开销路径；gpt-image-2 自定义像素值仅接受服务明确支持的标准尺寸，比例仍按 best-effort 语义传递，避免把生成模型包装成精确排版引擎。不新增图片处理依赖，以免引入原生构建和跨平台成本。
- 验收:
  - 超大聚合请求在计费调用前失败。
  - `1536x208`、`1536x1872` 等非标准像素值不再被静默接受。
  - 已有受支持调用保持兼容。
- 验证结果: 默认参考图解码后聚合上限为 8 MB，HTTPS URL 不计入内联体积；超限错误会建议减少、压缩或改用 URL。gpt-image-2 像素值收紧为 1024x1024、1536x1024、1024x1536；兼容后端拒绝比例值和会被忽略的 image_size。聚合体积与尺寸组合测试通过。
<!-- 用户批注区：用户会在此下方加 `// BY ...` 行。创建/更新 plan 时此区留空，不得预填 // BY 标记或示例。 -->

### Step 4: 同步使用说明与任务选型边界 [🔵 自动档] [✅ 完成]
- 依赖: Step 3
- 可并行: 否
- 执行者: lead
- 写入范围:
  - README.md
  - skills/grsai-image-generation/SKILL.md
- 关键决策: 明确三层超时、异步恢复方式、参考图体积建议、尺寸 best-effort 语义，以及精确 Sprite Sheet 应采用“生成素材 + 本地确定性合成”的流程。
- 验收:
  - 文档参数、默认值和代码一致。
  - Skill 不再引导模型盲目重试可能计费的未知状态请求。
- 验证结果: README 已记录分阶段超时、错误字段、参考图聚合限制、标准尺寸和精确图集替代流程；仓库 Skill 已同步 acceptance_unknown、轮询恢复和任务选型规则。全局已安装 Skill 位于项目外，按安全边界未在本计划中覆盖。
<!-- 用户批注区：用户会在此下方加 `// BY ...` 行。创建/更新 plan 时此区留空，不得预填 // BY 标记或示例。 -->

### Step 5: 全量验证、审查改动并自动提交 [🔵 自动档] [✅ 完成]
- 依赖: Step 4
- 可并行: 否
- 执行者: lead
- 写入范围:
  - .agent/plans/active/2026-0805-grsai-mcp-reliability.md
  - .agent/plans/done/2026-0805-grsai-mcp-reliability.md
- 关键决策: 不执行真实 Grsai 请求，避免产生费用；使用 mock 测试验证协议与慢链路行为。完成后仅暂存本计划汇总中列出的文件，按计划流程自动提交但不 push。
- 验收:
  - `npm test` 通过。
  - `npm run build` 通过。
  - `git diff --check` 通过。
  - `git diff --name-only` 与计划改动汇总一致。
  - 计划归档到 `.agent/plans/done/` 并生成中文规范 commit。
- 验证结果: `npm test` 通过 19/19；`npm run build` 通过；`git diff --check` 无输出；`git diff --name-only` 与业务改动汇总一致。审查时补充修复了响应头返回后响应体读取仍可能无限等待的问题，并增加对应测试。计划完成后归档并仅提交下列相关文件，不执行 push。
<!-- 用户批注区：用户会在此下方加 `// BY ...` 行。创建/更新 plan 时此区留空，不得预填 // BY 标记或示例。 -->

## 关键上下文
- 诊断报告记录 5 次调用中 1 次成功、4 次 `REQUEST_TIMEOUT`；`wait: false` 也在返回任务 ID 前失败。
- 改动前 Codex MCP `tool_timeout_sec` 为 360 秒；项目未配置 `GRSAI_REQUEST_TIMEOUT_MS`，因此每次 HTTP 请求使用 60 秒默认值。
- 三张问题参考图原始体积合计约 11.6 MB，Base64 内联后请求体约 15.5 MB；改动前仅限制单张大小，不限制聚合大小。
- Grsai 官方当前文档确认原生 `/v1/api/generate`、结果查询 `/v1/api/result` 和同步 `/v1/images/generations` 是不同调用语义；当前模型页将 gpt-image-2 标为 1K。
- 不假设上游支持未文档化的幂等键。没有上游任务 ID 时，只能明确提示“可能已接收、不要盲目重试”，不能伪造可恢复能力。
- 执行前必须检查本文件各 Step 下方是否新增 `// BY` 用户批注并逐条遵守。

## 已改动文件汇总
- test/grsai-client.test.ts (Step 1)
- test/server.test.ts (Step 1)
- test/files.test.ts (Step 1)
- src/config.ts (Step 2)
- src/errors.ts (Step 2)
- src/grsai-client.ts (Step 2)
- src/server.ts (Step 2)
- src/download.ts (Step 2)
- src/contracts.ts (Step 3)
- src/image-input.ts (Step 3)
- README.md (Step 4)
- skills/grsai-image-generation/SKILL.md (Step 4)
- .agent/plans/done/2026-0805-grsai-mcp-reliability.md (Step 5，归档后路径)
