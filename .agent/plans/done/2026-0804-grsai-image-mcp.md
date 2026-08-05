# Task: Grsai 生图 MCP 工具
Created: 2026-08-04
Status: complete
Execution Mode: solo

## 目标
构建一个可由 Codex 直接调用的本地 Grsai 生图 MCP 服务，安全封装生成、异步查询与结果下载流程。

## 计划

### Step 1: 初始化项目与接口契约 [🟡 推荐默认档] [✅ 完成]
- 依赖: 无
- 可并行: 否
- 执行者: lead
- 写入范围:
  - package.json
  - package-lock.json
  - tsconfig.json
  - .gitignore
  - src/config.ts
  - src/contracts.ts
- 关键决策: 使用 Node.js + TypeScript + 官方 MCP SDK；API Key 仅从 `GRSAI_API_KEY` 环境变量读取，不写入仓库或日志；默认使用国内节点并允许通过 `GRSAI_BASE_URL` 覆盖。
- 验收:
  - TypeScript 配置可编译
  - 输入模型、尺寸、比例、超时与路径均有显式约束
- 执行记录: 已固定官方 MCP SDK 1.30.0、Zod 4.4.3、TypeScript 7.0.2；`npm run build` 通过。

### Step 2: 实现 Grsai 客户端与文件处理 [🟡 推荐默认档] [✅ 完成]
- 依赖: Step 1
- 可并行: 否
- 执行者: lead
- 写入范围:
  - src/grsai-client.ts
  - src/image-input.ts
  - src/download.ts
  - src/errors.ts
- 关键决策: 主流程封装 `/v1/api/generate` 与 `/v1/api/result`；保留 `/v1/images/generations` 兼容调用；本地参考图转换为 data URL；下载文件使用安全文件名、大小限制和超时，不覆盖已有文件。
- 验收:
  - 同步、异步、失败、违规、超时和异常响应均转为稳定错误
  - 不泄露 Authorization 或完整敏感响应
- 执行记录: 已实现原生/兼容接口、轮询、本地参考图 data URL 化、安全错误和不覆盖下载；严格类型编译通过。

### Step 3: 暴露 MCP 工具与工作流 Skill [🟡 推荐默认档] [✅ 完成]
- 依赖: Step 2
- 可并行: 否
- 执行者: lead
- 写入范围:
  - src/server.ts
  - src/index.ts
  - skills/grsai-image-generation/SKILL.md
  - skills/grsai-image-generation/agents/openai.yaml
- 关键决策: 暴露 `generate_image` 和 `get_generation` 两个目标导向工具；生成属于可能计费的外部动作并标记为需要确认，查询标记为只读；Skill 只描述模型选择、轮询和结果交付，不复制详细 API 文档。
- 验收:
  - MCP 初始化、tools/list 和工具 schema 正常
  - Skill 通过 `quick_validate.py`
- 执行记录: 已完成两个 MCP 工具、服务级 instructions 与配套 Skill；协议测试可列出并调用工具，Skill 校验通过。

### Step 4: 自动化验证与文档同步 [🔵 自动档] [✅ 完成]
- 依赖: Step 3
- 可并行: 否
- 执行者: lead
- 写入范围:
  - test/
  - README.md
  - .env.example
- 关键决策: 使用 Node 内置测试运行器和本地 mock HTTP 服务覆盖主链路，不调用可能计费的真实 Grsai 接口；README 记录安装、环境变量、Codex 配置和示例提示词。
- 验收:
  - `npm test` 通过
  - `npm run build` 通过
  - 无真实密钥、生成物或下载图片进入版本库
- 执行记录: 8 项 mock/协议/文件测试通过；生产依赖审计 0 漏洞；README 与环境变量示例已同步，未调用真实接口。

### Step 5: 初始化版本库并提交 [🟡 推荐默认档] [✅ 完成]
- 依赖: Step 4
- 可并行: 否
- 执行者: lead
- 写入范围:
  - .git/
- 关键决策: 当前目录不是 Git 仓库；按持久化任务规则初始化仓库，只暂存本计划涉及文件并以中文提交说明提交，不 push。
- 验收:
  - `git diff --name-only` 与改动汇总一致
  - 存在本地任务提交且工作区干净
- 执行记录: 已初始化 main 分支；真实冒烟测试完成后校验任务改动清单，仅暂存本任务文件并按计划自动创建中文本地提交，不 push。

### Step 6: 注册到 Codex 并执行真实生图冒烟测试 [🔴 必须确认档] [✅ 完成]
- 依赖: Step 5
- 可并行: 否
- 执行者: lead
- 写入范围:
  - /Users/boyan/.codex/config.toml
  - README.md
  - 用户明确指定的图片输出目录
- 关键决策: 注册为全局 STDIO MCP；经用户确认，桌面端直接在个人 `~/.codex/config.toml` 的 MCP `env` 表中明文保存 `GRSAI_API_KEY`，不写入项目仓库；真实生图可能产生费用，因此只有在用户明确批准且凭据可用后才调用。
- 验收:
  - `codex mcp list` 显示 Grsai 服务已启用
  - 重启 Codex 后可看到两个工具
  - 获批后完成一次真实生成并验证本地图片可打开
- 执行记录: 钥匙串方案在 STDIO 握手时无法读取条目，且用户认为配置成本过高。2026-08-05 用户确认改用个人 `config.toml` 明文配置；已撤销钥匙串包装脚本并恢复 Node 直接启动方式。用户已亲自填写 key；在不回显密钥的前提下验证配置值非空且 MCP 子进程可成功读取，`codex mcp get grsai-image` 验证 Node 命令、入口路径、超时和审批模式正确。用户明确批准后，使用 `nano-banana-2`、1:1、1K 提交一次真实任务 `2-b98d0f60-6491-4b39-8929-fe9e22a7474c`，成功生成并下载 PNG；文件为 1024×1024、85,456 字节，人工查看内容与提示词一致。输出位于被 Git 忽略的 `generated/smoke/`，未重复提交任务，密钥未写入仓库或日志。

### Step 7: 配置全局默认生图路由 [🔴 必须确认档] [✅ 完成]
- 依赖: Step 3、Step 6 的 MCP 注册
- 可并行: 否
- 执行者: lead
- 写入范围:
  - skills/grsai-image-generation/SKILL.md
  - skills/grsai-image-generation/agents/openai.yaml
  - /Users/boyan/.agents/skills/grsai-image-generation/
  - /Users/boyan/.codex/AGENTS.md
  - /Users/boyan/.codex/config.toml
- 关键决策: 将 Grsai Skill 安装到官方当前推荐的用户级 `~/.agents/skills`；禁用与其冲突的系统 `imagegen` Skill；未指定提供方时默认 Grsai，用户明确指定其他提供方时尊重用户选择。
- 验收:
  - 全局 Skill 通过 `quick_validate.py`
  - `config.toml` 显示系统 imagegen Skill 已禁用
  - 全局 AGENTS 规则与 Skill 描述均覆盖“生成图片”等普通触发词
  - 重启 Codex 后新会话列出 Grsai Skill，且不再列出系统 imagegen Skill
- 执行记录: 已安装到 `~/.agents/skills/grsai-image-generation` 并通过校验；全局默认规则、隐式触发、MCP 依赖和系统 imagegen 禁用项均已写入且配置可解析。运行时激活按官方要求在 Codex 重启后生效。

## 关键上下文
- 当前目录为空，且不是 Git 仓库。
- 官方 Codex 手册确认本地 Codex 支持 STDIO MCP，并由 ChatGPT 桌面端、Codex CLI 与 IDE 扩展共享 MCP 配置。
- Grsai 文档给出的节点为 `https://grsaiapi.com`（全球）与 `https://grsai.dakka.com.cn`（国内）；鉴权为 `Authorization: Bearer <API_KEY>`。
- 生图主接口支持 nano-banana 与 gpt-image-2 系列、URL/base64 参考图、同步/流式/异步返回；本项目优先实现 JSON/异步流程，不实现流式响应。
- `/v1/chat/completions` 不属于当前生图目标，不暴露为 MCP 工具；若以后需要通用 Grsai 模型代理，应单独立项。
- Step 6 同时包含全局配置变更和可能计费操作，必须分别获得明确授权；缺少密钥不阻塞 Step 1-5 的 mock 验证。
- 用户已明确批准全局默认路由；官方 Codex 手册确认可通过 `[[skills.config]]` 按 SKILL.md 路径禁用特定 Skill。

## 已改动文件汇总
- .agent/plans/active/2026-0804-grsai-image-mcp.md（计划创建）
