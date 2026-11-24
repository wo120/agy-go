# AGENTS.md — AGY Go (`agy-remote` + Android Client)

## 1. 工程纪律（默认启用 Lauren / pstack 工作流）

本仓库默认采用 Lauren Tan (`@poteto`) **pstack 工程纪律流**（`.agents/skills/pstack-workflow/SKILL.md`）：**信任优先，并发随后（Trust Comes First, Parallel Later）**。

- **简单问答或单步常规命令**：直接回答，无需走完整 Playbook。
- **Bug 修复 / 功能开发 / 重构 / 架构设计 / 审查（`interrogate` / `deslop`） / 只读调研（`how` / `why`）**：按 `.agents/skills/pstack-workflow/SKILL.md` 及 `references/playbooks.md` 执行。
- **七条铁律**：
  1. **Evidence First**：动手前先读真实调用链与运行证据，禁止猜路径/猜字段。
  2. **Fix Root Causes**：Bug 先复现再修根因，拒绝空 `catch` 吞错或加定时器掩盖。
  3. **Laziness Protocol**：最小正确改动，不顺手重构无关代码，不留废话注释。
  4. **Model the Domain First**：先定类型、契约与边界再写实现。
  5. **Prove It Works**：编译/分析通过 ≠ 完成，必须跑通真实测试或真实运行证据。
  6. **Test Behavior**：测试外部可观测行为与持久化结果，不绑定内部实现细节。
  7. **Encode in Code**：重复踩坑优先沉淀进 `scripts/verify.sh`、单测或 lint 规则。

## 2. 仓库边界与绝对禁区

- **`bridge/`（Go 插件核心）**：单二进制 `agy-remote` 承载 `sidecar / mcp / hook / serve / pair / status`。
  - **绝不写入** Antigravity 原生 `~/.gemini/antigravity/conversation_summaries.db`（必须严格 `mode=ro` 只读）。
  - 所有本机回环 HTTP 请求（调用 `LanguageServerService`、`/internal/hook`）必须显式禁用系统代理（`Proxy: nil`）。
  - 任何文件读取必须经过 `internal/filesandbox` 白名单与 `EvalSymlinks` 校验。
  - 修改 `bridge/` 或 `plugin/` 后，必须执行 `./scripts/install-plugin.sh` 重新部署并平滑重启 Sidecar，禁止只改代码不重启旧进程。
- **`plugin/`（Antigravity 原生插件清单）**：
  - `plugin.json` 严禁添加官方 Schema 以外的未知顶层字段。
  - `hooks.json` 必须放在插件根目录，且 Hook 命令必须快速退出并输出 `{}`，绝不阻塞 Agent 主循环。
  - MCP 工具名必须统一 `agy_remote_` 前缀。
- **`app/packages/agy_client/`（纯 Dart 协议层）**：零 Flutter 依赖，保证可独立执行 `dart test`。
- **`app/`（Flutter + Android Kotlin 原生层）**：
  - 状态统一由 `lib/state/` 下的 Riverpod 手写 `Notifier` 托管（单一 Owner，不引入 codegen）。
  - 前端严禁硬编码订阅等级（如 `Google AI Ultra`）作为展示数据。

## 3. Done Gate（交付前必跑门禁）

宣称任何代码改动完成前，必须真实运行并全绿通过：

```bash
./scripts/verify.sh
./scripts/smoke-live.sh   # 涉及运行态/接口/插件改动时追加实机冒烟
```

若改动涉及运行态行为（如 Sidecar、MCP、Hook、配额接口），还须执行实机/本机冒烟验证，并在汇报中给出：
1. **改了什么**（文件与行号链接）
2. **如何证明可用**（真实命令输出 / 测试结果；未覆盖项须明说）
3. **护栏建议**（如有值得锁进检查的坑点）
