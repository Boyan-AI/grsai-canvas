# Task: 项目目录更名为 grsai-canvas
Created: 2026-08-05
Status: completed
Execution Mode: solo

## 目标
将项目目录从 `/Users/boyan/Desktop/Tools/image-gen` 更名为 `/Users/boyan/Desktop/Tools/grsai-canvas`，并同步项目文档与本机 Codex 配置中的绝对路径。

## 计划

### Step 1: 更新仓库内路径文档 🟡 推荐默认档 ✅ 完成
- 依赖: 无
- 可并行: 否
- 执行者: lead
- 写入范围:
  - README.md
- 关键决策: 仅将两处 MCP 启动参数中的旧绝对路径替换为新目录路径，不改动现有 `grsai-image` 配置键和 Skill 名称。
- 验收:
  - README 不再包含 `/Users/boyan/Desktop/Tools/image-gen`
  - README 中示例入口指向 `/Users/boyan/Desktop/Tools/grsai-canvas/dist/src/index.js`
- 执行记录: README 中两处 MCP 启动入口已替换为新目录路径，检索确认不再包含旧目录路径。

### Step 2: 迁移目录并更新全局配置 🔴 必须确认档 ✅ 完成
- 依赖: Step 1
- 可并行: 否
- 执行者: lead
- 写入范围:
  - /Users/boyan/Desktop/Tools/image-gen/
  - /Users/boyan/Desktop/Tools/grsai-canvas/
  - /Users/boyan/.codex/config.toml
- 关键决策: 在确认目标目录不存在后执行原子目录移动；同步更新 Codex 项目信任路径和 MCP 启动入口，不修改或回显 API Key 等敏感配置。
- 验收:
  - 旧目录不存在，新目录存在且 Git 仓库完整
  - 全局配置不再包含旧目录路径，并包含两处新路径
  - 全局配置可被 Codex 正常解析
- 执行记录: 已将目录原子移动到 `/Users/boyan/Desktop/Tools/grsai-canvas`；旧路径已消失。全局配置中的项目段键和 MCP 入口已精确替换，新路径计数为 2、旧路径计数为 0，TOML 解析成功，未输出敏感配置。

### Step 3: 验证、归档并提交 🔵 自动档 ✅ 完成
- 依赖: Step 2
- 可并行: 否
- 执行者: lead
- 写入范围:
  - dist/
  - .agent/plans/active/2026-0805-project-directory-rename.md
  - .agent/plans/done/2026-0805-project-directory-rename.md
- 关键决策: 在新目录运行构建与完整测试；仅提交仓库内 README 和计划文件，全局配置与目录名不属于 Git 提交；不 push。
- 验收:
  - `npm run build` 和 `npm test` 通过
  - `git diff --name-only` 与仓库内改动汇总一致
  - 计划归档并生成符合规范的本地 commit
- 执行记录: 新目录中 `npm run build` 成功；`npm test` 成功，10 项测试全部通过。Git 核对确认仓库内仅 README 和本计划有改动；计划已归档并按批准流程创建本地提交，不执行 push。

## 关键上下文
- 用户指出项目目录名尚未随项目名称更新。
- 目标目录 `/Users/boyan/Desktop/Tools/grsai-canvas` 当前不存在。
- `/Users/boyan/.codex/config.toml` 中有两处旧路径：项目配置段键和 MCP `args` 入口。
- 当前 MCP 子进程不会因目录移动立即中断，但 Codex 需要重启后才会从新路径重新加载服务。

## 已改动文件汇总
- .agent/plans/done/2026-0805-project-directory-rename.md（计划创建并归档，Step 3）
- README.md（Step 1）
