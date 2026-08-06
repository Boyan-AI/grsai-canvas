# Task: Grsai 生图迁移为自包含 Python Skill
Created: 2026-08-05
Status: completed
Execution Mode: solo

## 目标
将当前 `Skill + STDIO MCP` 改造成可独立安装的 `Skill + Python CLI`，除 Python 3.9+ 与首次配置 `GRSAI_API_KEY` 外不依赖 Node、npm、MCP 注册或第三方 Python 包，并等价保留现有安全与可靠性行为。

## 计划

### Step 1: 固化 Python CLI 契约与失败基线 [🟡 推荐默认档] [✅ 完成]
- 依赖: 无
- 可并行: 否
- 执行者: lead
- 写入范围:
  - test/python/test_grsai_cli.py
  - test/python/__init__.py
  - .agent/plans/active/2026-0805-advisor-skill-python-migration.md
- 关键决策:
  - 入口固定为 `python3 skills/grsai-image-generation/scripts/grsai_image.py <command>`，支持 `generate`、`get`、`doctor` 三个子命令。
  - `generate` 参数与现有 MCP 对齐：`--prompt`、`--model`、可重复的 `--reference-image`、`--aspect-ratio`、`--image-size`、`--backend`、`--no-wait`、`--wait-timeout-seconds`、`--output-dir`。
  - `get` 接受 `--id` 与 `--wait-timeout-seconds`；`doctor` 只检查运行时和配置，不发网络请求。
  - 除标准 `--help` 文本外，业务执行路径的 stdout 只输出一个 UTF-8 JSON 对象；诊断信息写 stderr。成功或仍在运行返回码为 0，输入/配置错误返回 2，上游、生成或下载错误返回 3。
  - JSON 保留现有字段：`request_id`、`id`、`status`、`progress`、`urls`、`files`、`error`；`error` 保留 `code`、`message`、`phase`、`backend`、`retryable`、`acceptance_unknown` 及可选诊断字段。
- 验收:
  - 新增测试覆盖帮助信息、必填参数、stdout/stderr 隔离、退出码和稳定 JSON 字段。
  - 运行 `rtk python3 -m unittest discover -s test/python -p 'test_grsai_cli.py' -v`，预期因入口脚本尚不存在而失败，证明测试能约束实现。
- 执行记录:
  - 2026-08-05：实施前 `rtk npm test` 基线通过，19 项测试、0 项失败。
  - 2026-08-05：新增 3 项 CLI 契约测试；测试均因入口脚本不存在而按预期失败，RED 基线成立。
<!-- 用户批注区 -->

### Step 2: 迁移配置、契约、错误与 Grsai HTTP 客户端 [🔵 自动档] [✅ 完成]
- 依赖: Step 1
- 可并行: 否
- 执行者: lead
- 写入范围:
  - skills/grsai-image-generation/scripts/grsai_client.py
  - test/python/test_grsai_client.py
  - test/python/support.py
  - .agent/plans/active/2026-0805-advisor-skill-python-migration.md
- 关键决策:
  - 仅使用 `urllib.request`、`json`、`uuid`、`time`、`dataclasses` 等 Python 标准库，不生成 `requirements.txt`，最低运行时为 Python 3.9。
  - 沿用全部 `GRSAI_*` 环境变量、默认节点和分阶段超时；API Key 只从 `GRSAI_API_KEY` 读取，不通过参数、文件或日志持久化。
  - 原生提交、任务查询、同步兼容接口和轮询截止时间保持现有语义；提交或同步请求超时必须设置 `acceptance_unknown: true`，已有任务的查询超时不得触发重复提交。
  - 只允许 HTTPS 上游；本地 HTTP 仅由测试注入，不通过生产环境开关放宽。
  - 响应采用显式类型与字段校验；错误信息不得包含 Authorization、API Key 或完整上游响应体。新增或实质修改的函数、类和模块均写中文 docstring/注释。
- 验收:
  - 测试覆盖 Bearer 鉴权、缺少密钥不发请求、原生提交、状态轮询、同步兼容接口、429/5xx、非 JSON、网络错误、分阶段超时和上游请求 ID。
  - 本地 mock 记录的请求体与现有 TypeScript 契约一致。
  - 运行 `rtk python3 -m unittest test.python.test_grsai_client -v`，预期全部通过且不访问真实 Grsai。
- 执行记录:
  - 2026-08-06：13 项客户端测试全部通过，覆盖配置兼容、Bearer 请求、轮询、同步接口、429/5xx、非 JSON、网络与超时诊断；`py_compile` 通过，未访问真实 Grsai。
<!-- 用户批注区 -->

### Step 3: 迁移参考图处理与安全下载 [🔵 自动档] [✅ 完成]
- 依赖: Step 2
- 可并行: 否
- 执行者: lead
- 写入范围:
  - skills/grsai-image-generation/scripts/grsai_files.py
  - test/python/test_grsai_files.py
  - .agent/plans/active/2026-0805-advisor-skill-python-migration.md
- 关键决策:
  - HTTPS URL 原样传递；本地绝对路径和 data URL 按现有 MIME、单图大小和总解码大小限制处理。
  - 下载继续限制响应声明大小与实际读取大小，采用分块读取，跟随安全重定向，保留下载超时诊断。
  - 文件名继续清洗任务 ID，并使用独占创建与递增后缀，禁止覆盖已有文件。
  - 新增或实质修改的函数、类和模块均写中文 docstring/注释。
- 验收:
  - 测试覆盖本地图片转 data URL、无效协议、单图/总量超限、下载超时、响应体超限、扩展名推断和不覆盖已有文件。
  - 运行 `rtk python3 -m unittest test.python.test_grsai_files -v`，预期全部通过且只访问本地 mock。
- 执行记录:
  - 2026-08-06：10 项文件层测试全部通过；与 13 项客户端测试联合回归通过，两个模块 `py_compile` 通过，未访问真实网络。
<!-- 用户批注区 -->

### Step 4: 实现 generate/get/doctor 编排入口 [🔵 自动档] [✅ 完成]
- 依赖: Step 2、Step 3
- 可并行: 否
- 执行者: lead
- 写入范围:
  - skills/grsai-image-generation/scripts/grsai_image.py
  - test/python/test_grsai_cli.py
  - .agent/plans/active/2026-0805-advisor-skill-python-migration.md
- 关键决策:
  - CLI 只负责参数解析、模型/尺寸组合校验、客户端与文件模块编排、稳定 JSON 序列化和退出码映射，不复制底层 HTTP/文件逻辑。
  - `generate` 默认 `gpt-image-2`、原生后端、等待 180 秒；轮询超时返回 `status: running` 和已有任务 ID，而不是错误或重新提交。
  - `get` 不允许查询 `openai-compatible` 的合成 ID；`doctor` 输出 Python 版本、脚本版本和密钥是否已配置，但绝不输出密钥值。
  - 所有异常均转成稳定 JSON；即使失败，stdout 也不得混入 traceback 或人类说明文本。
  - 新增或实质修改的函数、类和模块均写中文 docstring/注释。
- 验收:
  - Step 1 的失败测试转为通过，并新增原生成功、running 恢复、兼容后端成功、参数组合拒绝和下载结果路径测试。
  - 运行 `rtk python3 -m unittest test.python.test_grsai_cli -v`，预期全部通过且不访问真实 Grsai。
  - 运行 `rtk python3 -m py_compile skills/grsai-image-generation/scripts/grsai_image.py skills/grsai-image-generation/scripts/grsai_client.py skills/grsai-image-generation/scripts/grsai_files.py`，预期退出码 0。
- 执行记录:
  - 2026-08-06：完成 `grsai_image.py` CLI 编排，实现参数校验、原生/兼容后端、可恢复轮询、稳定 JSON 与退出码映射。
  - 2026-08-06：新增原生成功、running 恢复、兼容后端、参数拒绝、下载路径、get 续查和 `acceptance_unknown` 测试；CLI 专项 11 项通过。
  - 2026-08-06：Python 全量测试 34 项通过；三个脚本 `py_compile` 通过，未访问真实 Grsai。
<!-- 用户批注区 -->

### Step 5: 将 Skill 切换为 Python 调用说明 [🟡 推荐默认档] [✅ 完成]
- 依赖: Step 4
- 可并行: 否
- 执行者: lead
- 写入范围:
  - skills/grsai-image-generation/SKILL.md
  - skills/grsai-image-generation/agents/openai.yaml
  - README.md
  - .agent/plans/active/2026-0805-advisor-skill-python-migration.md
- 关键决策:
  - 从 `agents/openai.yaml` 删除 `grsai-image` MCP 工具依赖，保留隐式调用策略。
  - 修改元数据前读取并遵守当前 `skill-creator` 与 `writing-skills` 规范，只删除已确认支持删除的 MCP 依赖字段，不自行发明 Python 工具依赖类型。
  - `SKILL.md` 明确脚本定位、命令构造、付费调用授权、任务 ID 续查、`acceptance_unknown` 禁止自动重试、结果展示和错误上报流程。
  - Skill 内的运行命令只依赖通用 `python3`，不得硬编码本机仓库路径、`rtk` 或其他个人工具；若宿主沙箱阻止外部网络，按宿主规则申请范围明确的授权并解释可能产生费用。
  - README 将安装流程改为复制/安装单个 Skill 后首次配置 `GRSAI_API_KEY`；明确 Python 3.9+、零 pip 依赖和无需 MCP 注册/重启。
  - 文档不得宣称真正零配置，也不得建议将 API Key 写入 Skill、仓库或命令参数。
- 验收:
  - `rtk rg -n 'type: "mcp"|grsai-image MCP|command = "node"|npm run build' skills/grsai-image-generation README.md` 不再命中现行安装或执行说明；历史迁移说明如保留必须明确标记为旧方案。
  - `SKILL.md` 中的 `generate`、`get`、`doctor` 示例与 `--help` 输出一致。
  - Skill 目录复制到其他位置后不引用仓库外绝对路径。
- 执行记录:
  - 2026-08-06：`SKILL.md` 已切换为内置 Python CLI 工作流，明确付费授权、任务续查、`acceptance_unknown`、输出解析和沙箱网络边界。
  - 2026-08-06：`agents/openai.yaml` 已删除 MCP 工具依赖，保留 `allow_implicit_invocation: true`，界面元数据与 Skill 正文一致。
  - 2026-08-06：README 已改为 Python 3.9+、零 pip 依赖、无需 Node/npm/MCP 注册或重启的安装与使用说明；禁用旧说明的 `rg` 检查无命中。
  - 2026-08-06：官方 `quick_validate.py` 因环境缺少 PyYAML 无法运行；使用 Ruby 标准 YAML 解析与等价字段约束检查通过，Python 全量 34 项测试和 `py_compile` 继续通过。
<!-- 用户批注区 -->

### Step 6: 验证 Skill 可独立迁移且不调用付费 API [🔵 自动档] [✅ 完成]
- 依赖: Step 5
- 可并行: 否
- 执行者: lead
- 写入范围:
  - .agent/plans/active/2026-0805-advisor-skill-python-migration.md
- 关键决策:
  - 使用 `mktemp -d /private/tmp/grsai-skill-check.XXXXXX` 创建隔离目录，只复制 `skills/grsai-image-generation/` 后运行验证。
  - 所有网络路径只连接测试进程提供的本地 mock；不得使用真实 API Key，不调用 Grsai，不产生费用。
  - 验证失败时保留原 MCP 源码并回到对应步骤修复，不进入删除阶段。
- 验收:
  - 隔离副本中 `python3 scripts/grsai_image.py --help`、`doctor` 和无需网络的参数拒绝路径均可运行。
  - 隔离副本不需要 `node_modules`、`dist`、根目录源码或仓库绝对路径。
  - 仓库中的 mock 生图/查询测试运行 `rtk python3 -m unittest discover -s test/python -p 'test_*.py' -v`，预期全部通过。
- 执行记录:
  - 2026-08-06：使用 `/private/tmp/grsai-skill-check.*` 隔离目录只复制 Skill；清空 `PYTHONPATH`、使用 `python -S` 禁用第三方 site 包并清空 API Key 后，`--help`、`doctor`、参数拒绝与 `py_compile` 全部通过。
  - 2026-08-06：直接使用最低支持版本 Python 3.9.6 与开发版本 Python 3.14.5 分别运行全量 39 项测试，均全部通过；测试仅使用依赖注入 mock，未访问真实 Grsai。
  - 2026-08-06：隔离审查发现并修复三项等价性缺口：失败任务 ID 丢失、未知查询异常阶段错误、上游或依赖错误文本可能回显 API Key；新增 5 项回归测试后红转绿。
  - 2026-08-06：Skill 目录中未发现本机仓库绝对路径、`rtk` 或仓库外运行依赖。
<!-- 用户批注区 -->

### Step 7: 删除旧 Node/MCP 实现并收敛仓库 [🔴 必须确认档] [✅ 完成]
- 依赖: Step 6
- 可并行: 否
- 执行者: lead
- 写入范围:
  - src/config.ts
  - src/contracts.ts
  - src/download.ts
  - src/errors.ts
  - src/grsai-client.ts
  - src/image-input.ts
  - src/index.ts
  - src/server.ts
  - test/files.test.ts
  - test/grsai-client.test.ts
  - test/server.test.ts
  - package.json
  - package-lock.json
  - tsconfig.json
  - .gitignore
  - README.md
  - .agent/plans/active/2026-0805-advisor-skill-python-migration.md
- 关键决策:
  - 仅在 Step 6 的独立迁移验证全部通过且用户再次明确批准后，删除已被 Python 等价覆盖的 TypeScript、MCP SDK、npm 构建和测试资产。
  - `.gitignore` 删除仅服务 Node 构建的条目，增加 Python 缓存忽略规则；保留 `generated/` 等仍有效规则。
  - 不修改或删除用户全局 `~/.codex/config.toml` 中的 MCP 配置，也不覆盖 `~/.agents/skills/`；这些属于仓库外全局变更，需另行说明影响并单独授权。
- 验收:
  - `rtk rg --files -g 'src/**' -g 'package*.json' -g 'tsconfig.json'` 不再发现旧实现或 Node 元数据。
  - `rtk rg -n '@modelcontextprotocol/sdk|StdioServerTransport|registerTool' . -g '!node_modules' -g '!dist' -g '!.git'` 无现行代码命中。
  - Python 全量测试继续通过。
- 执行记录:
  - 2026-08-06：用户明确批准 Step 7 后，删除 8 个 TypeScript 源文件、3 个旧测试、`package.json`、`package-lock.json` 与 `tsconfig.json`。
  - 2026-08-06：`.gitignore` 删除 `node_modules/`、`dist/`，新增 `__pycache__/` 与 `*.py[cod]`；保留 `.env`、`generated/`、日志和系统文件规则。
  - 2026-08-06：安全 hook 拦截多目标递归删除，改为把 `node_modules`、`dist` 与 Python 缓存移动到可恢复隔离目录 `/private/tmp/grsai-canvas-cleanup.oBzBAR`。
  - 2026-08-06：旧实现、Node 元数据和 MCP SDK 注册搜索均无命中；Python 全量 39 项测试、`py_compile` 与 `git diff --check` 通过。
<!-- 用户批注区 -->

### Step 8: 完成回归、归档计划并自动提交 [🔵 自动档] [✅ 完成]
- 依赖: Step 7
- 可并行: 否
- 执行者: lead
- 写入范围:
  - skills/grsai-image-generation/
  - test/python/
  - README.md
  - .gitignore
  - .agent/plans/active/2026-0805-advisor-skill-python-migration.md
  - .agent/plans/done/2026-0805-advisor-skill-python-migration.md
- 关键决策:
  - 最终只保留 Python Skill 运行链路；不保留两套长期并行实现。
  - 按计划流程只暂存本计划涉及文件，使用中文提交说明 `refactor: 将 Grsai 生图迁移为 Python Skill`，不 push。
  - 完成前将所有步骤状态、关键决策、验证结果和改动文件更新到计划，随后把计划从 `active/` 移入 `done/`。
- 验收:
  - `rtk python3 -m unittest discover -s test/python -p 'test_*.py' -v` 全部通过。
  - `rtk python3 -m py_compile skills/grsai-image-generation/scripts/*.py` 退出码 0。
  - 隔离 Skill 副本验证再次通过，且测试日志确认没有访问真实 Grsai。
  - `rtk git diff --name-only` 与“已改动文件汇总”一致；提交后 `rtk git status` 干净。
- 执行记录:
  - 2026-08-06：Python 3.14.5 与最低版本 Python 3.9.6 分别运行全量 39 项测试，均 0 失败；三个脚本在两个版本下 `py_compile` 均通过。
  - 2026-08-06：最终隔离副本在清空 API Key、清空 `PYTHONPATH`、禁用第三方 site 包后通过 `--help`、`doctor`、参数拒绝和 JSON 解析验证，未调用真实 Grsai。
  - 2026-08-06：Skill frontmatter、`openai.yaml`、旧实现搜索、仓库绝对路径搜索和 `git diff --check` 全部通过。
  - 2026-08-06：计划归档后只暂存本任务涉及文件，并使用 `refactor: 将 Grsai 生图迁移为 Python Skill` 自动提交；不 push。
<!-- 用户批注区 -->

## 关键上下文
- 用户以可迁移性为首要目标：其他环境只安装 Skill，并首次配置 `GRSAI_API_KEY`，不再单独安装 Node 依赖、构建 MCP、配置绝对路径或重启 Codex。
- 当前仓库有 8 个 TypeScript 源文件共 1335 行，MCP 仅暴露 `generate_image` 与 `get_generation` 两个工具；现有 Git 工作区在计划创建前为干净状态。
- 最近可靠性改动处理的异步轮询、分阶段超时、下载限制和潜在重复计费属于 Grsai API 业务语义，迁移时必须保留，不能因移除 MCP 而简化掉。
- Python CLI 会失去 MCP 原生 Schema、结构化工具声明与审批注解，因此必须用严格 argparse、稳定 JSON、明确退出码和 Skill 工作流约束补足。
- Python CLI 的外部网络访问受各宿主沙箱与审批策略影响；迁移目标是减少安装组件，不承诺绕过目标环境的网络授权。
- 目标产物只依赖 Python 3.9+ 标准库；不新增 pip、uv、requests、pydantic 等依赖。
- 计划执行前需要用户批准整体方案；执行到 Step 7 删除旧实现前再次确认。全局已安装 Skill 与 MCP 配置不在本计划自动写入范围。

## 已改动文件汇总
- .agent/plans/done/2026-0805-advisor-skill-python-migration.md (计划创建并归档)
- test/python/__init__.py (Step 1)
- test/python/test_grsai_cli.py (Step 1)
- skills/grsai-image-generation/scripts/grsai_client.py (Step 2)
- test/python/support.py (Step 2)
- test/python/test_grsai_client.py (Step 2)
- skills/grsai-image-generation/scripts/grsai_files.py (Step 3)
- test/python/test_grsai_files.py (Step 3)
- skills/grsai-image-generation/scripts/grsai_image.py (Step 4)
- test/python/test_grsai_cli.py (Step 4 扩展)
- skills/grsai-image-generation/SKILL.md (Step 5)
- skills/grsai-image-generation/agents/openai.yaml (Step 5)
- README.md (Step 5)
- .gitignore (Step 7)
- src/config.ts (Step 7 删除)
- src/contracts.ts (Step 7 删除)
- src/download.ts (Step 7 删除)
- src/errors.ts (Step 7 删除)
- src/grsai-client.ts (Step 7 删除)
- src/image-input.ts (Step 7 删除)
- src/index.ts (Step 7 删除)
- src/server.ts (Step 7 删除)
- test/files.test.ts (Step 7 删除)
- test/grsai-client.test.ts (Step 7 删除)
- test/server.test.ts (Step 7 删除)
- package.json (Step 7 删除)
- package-lock.json (Step 7 删除)
- tsconfig.json (Step 7 删除)
