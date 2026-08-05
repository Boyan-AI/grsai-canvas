# Task: 项目更名为 Grsai Canvas
Created: 2026-08-05
Status: completed
Execution Mode: solo

## 目标
将项目展示名称与 npm 包标识统一更名为 Grsai Canvas，同时保持现有 MCP 配置、Skill 路由和目录路径兼容。

## 计划

### Step 1: 更新项目名称与包标识 🟡 推荐默认档 ✅ 完成
- 依赖: 无
- 可并行: 否
- 执行者: lead
- 写入范围:
  - package.json
  - package-lock.json
  - README.md
  - src/server.ts
- 关键决策: 展示名称改为 `Grsai Canvas`，npm 包名和命令名改为 `grsai-canvas-mcp`，MCP 服务内部名称改为 `grsai-canvas`；暂不改动现有 `grsai-image` 配置键、Skill 名称及项目目录，避免破坏本机已安装集成和绝对路径配置。
- 验收:
  - 项目元数据和 README 标题使用新名称
  - 旧包名 `grsai-image-mcp` 不再出现在活动项目文件中
- 执行记录: 已更新展示名、npm 包名与命令名、MCP 内部服务名；保留 `grsai-image` 配置键、Skill 名称和项目目录不变。字面检索确认旧包名不再存在于活动源码、测试、Skill 与项目文档中。

### Step 2: 验证构建与测试 🔵 自动档 ✅ 完成
- 依赖: Step 1
- 可并行: 否
- 执行者: lead
- 写入范围:
  - dist/
- 关键决策: 使用项目现有 npm 脚本，不新增依赖或测试框架。
- 验收:
  - `npm run build` 通过
  - `npm test` 通过
- 执行记录: `npm run build` 成功；`npm test` 成功，10 项测试全部通过，无失败、跳过或取消。

### Step 3: 汇总、归档并提交 🔵 自动档 ✅ 完成
- 依赖: Step 2
- 可并行: 否
- 执行者: lead
- 写入范围:
  - .agent/plans/active/2026-0805-grsai-canvas-rename.md
  - .agent/plans/done/2026-0805-grsai-canvas-rename.md
- 关键决策: 仅暂存本计划涉及的文件，提交信息使用中文；不 push。
- 验收:
  - 计划状态与验证结果记录完整并归档
  - `git diff --name-only` 与改动汇总一致
  - 生成一个符合规范的本地 commit
- 执行记录: 已核对 Git 改动范围，仅包含 README、包元数据、MCP 服务元数据和本计划；计划已完成并归档，按批准流程随即创建本地提交，不执行 push。

## 关键上下文
- 用户已认可项目名 `Grsai Canvas` 与包名 `grsai-canvas-mcp`。
- 当前全局 MCP 配置使用 `grsai-image` 键和项目目录绝对路径；本次不修改全局配置或目录名。
- 历史归档计划保留原名称，作为历史记录不回写。

## 已改动文件汇总
- .agent/plans/done/2026-0805-grsai-canvas-rename.md（计划创建并归档，Step 3）
- package.json（Step 1）
- package-lock.json（Step 1）
- README.md（Step 1）
- src/server.ts（Step 1）
