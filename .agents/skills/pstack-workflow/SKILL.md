---
name: pstack-workflow
description: >-
  Lauren Tan (@poteto) pstack 工程纪律流（Antigravity 适配版）。适用于代码功能开发、Bug 排查修复、重构、架构设计、代码审查（interrogate/deslop）以及复杂只读调研（how/why）。当用户提到 pstack、poteto-mode、lauren 工作流，或执行需要严格取证、最小改动与真实运行验证的工程任务时启用。简单问答或单步常规命令无需加载。
---

# pstack 工程纪律流（Antigravity 版）

源自 Lauren Tan (`@poteto`) 的 **pstack / poteto-mode** 方法论，核心信条是 **“信任优先，并发随后”（Trust Comes First, Parallel Later）**：先靠取证、最小改动、真实运行验证与自动化护栏建立可靠性，再按需用多 Agent 并行提效。

---

## 一、七条核心工程原则（Principles）

当某条原则改变了你的设计或实现决策时，在最终汇报中简明点出所依据的原则。

1. **Evidence First（证据优先于自信）**
   - 严禁凭文件名、目录结构或直觉猜测问题。动手前必须用检索工具确认真实入口、调用链和状态流转。
2. **Fix Root Causes（只治根因，不打补丁）**
   - 修复 Bug 前必须先复现问题（或构造稳定失败的测试/复现命令），定位根因后再改代码，拒绝用 `try/catch` 吞错、加延迟定时器等表面兜底掩盖问题。
3. **Laziness Protocol（最小改动，拒绝 AI Slop）**
   - 只写解决当前问题所需的最小代码量；不顺手重构无关代码，不加未要求的可配置项或过度抽象，不留解释显而易见代码的废话注释。
4. **Model the Domain First（先定边界与数据结构）**
   - 非平凡功能先明确类型、接口签名、状态转换与模块边界，再写实现逻辑。
5. **Prove It Works（无证据，不完工）**
   - **编译通过 / 类型检查通过 ≠ 任务完成**。必须运行真实测试、命令、接口调用或使用 `browser` 子代理操作真实界面，并给出可核验的输出/状态变化作为证据。
6. **Test Behavior, Not Implementation（测行为，不测实现）**
   - 测试断言关注外部可观测行为与持久化结果，而非脆弱的内部私有方法调用细节。
7. **Encode Recurring Mistakes in Code（重复错误锁进自动化检查）**
   - 若某类错误在同一仓库反复出现，不要只靠口头约定或往文档堆规则，优先补充单测、Linter 规则、类型约束或校验脚本，让机器报错拦截。

---

## 二、任务路由（Playbook Router）

收到任务后，先判断属于哪类 Playbook，**按需读取** [playbooks.md](./references/playbooks.md) 中对应章节并把步骤落实为执行清单：

| 任务类型 | 触发场景 / 快捷口令 | 对应 Playbook |
| :--- | :--- | :--- |
| **Bug 修复** | 报错、异常行为、线上/测试回归 | `Bug Fix`（复现 → 根因 → 失败测试 → 最小修复 → 回归证明） |
| **功能开发** | 新增功能、扩展接口/UI | `Feature`（域建模与边界 → 可验证小步拆分 → 行为测试 → 真实运行验证） |
| **安全重构** | 清理技术债、结构调整 | `Refactor`（先补行为基线测试 → 先减后增小步迁移 → 前后行为一致验证） |
| **只读调研** | `how` / `why` / 查链路 / 查历史 | `Investigate`（只读追踪代码路径与 git 历史，严禁改文件） |
| **架构设计** | `architect` / 跨模块方案设计 | `Architect`（先产出数据模型、接口边界与影响面分析，再编码） |
| **对抗审查 & 去水** | `interrogate` / `deslop` / 交付前自查 | `Interrogate & Deslop`（挑刺式 diff 审查 + 清理冗余与 AI 痕迹） |
| **并行探索/分片** | `arena`（多方案择优） / `swarm`（独立切片并行） | `Parallel`（结合 `invoke_subagent` 或 `swarm` 并行执行后统一验证） |

> 需要查看快捷口令细节与原则速查时，按需读取 [commands-and-principles.md](./references/commands-and-principles.md)。

---

## 三、Antigravity 工具链协同约定

- **取证与调研**：优先使用 `codegraph`（若索引可用）或 `agy-dart_fast` 的 `batch_search` / `read_slices` 定位入口与调用链，再用并行 `read_file` 精读关键区间，避免盲目全量读文件。
- **修改与验证**：多文件/多处编辑优先用 `agy-dart_fast` 的 `apply_edits`（可附带 `verify`）；多个独立检查优先用 `run_checks` 并发执行。
- **真实运行验证**：CLI/后端服务用 `run_command` 跑真实请求或回归测试；Web/前端 UI 变更按需委托 `browser` 子代理操作页面并验证真实交互与持久化结果。
- **并行与对抗审查**：需要独立视角审查或并行多方案对比时，调用 `invoke_subagent`（只读审查用 `research`）或 `swarm`（多作者并行编辑选 `workspace: "share"`）。

---

## 四、完工硬门槛（Done Gate）与精炼交付

宣称完成前必须全部满足：
1. **改动聚焦**：检查 `git diff`，确认没有误伤无关文件、没有残留调试代码、没有冗余 AI 废话注释。
2. **验证闭环**：至少完成「静态检查/构建」+「真实行为验证（测试/命令/接口/UI）」，且关键结果已亲眼核对。
3. **无水汇报（Unsloped Output）**：直接给出三项干货，不写空泛总结：
   - **改了什么**（带文件与关键行链接）
   - **如何证明可用**（实际执行的命令、通过的用例或真实行为证据；若有未覆盖项须明说）
   - **原则 / 护栏建议**（如有关键权衡或值得沉淀为 lint/test 的重复坑点）
