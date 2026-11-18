# M0+M1：回归基线 + 平台抽象层落地 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (用户已指定：本 session 原生实施). Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 冻结回归基线（M0），把 Mac 特有部分收敛进 `inferfabric/platform/` 抽象层（M1），旧模块名留 shim，全部既有测试经 shim 通过，并产出 D20 diff 审计结论 + CHERRY-PICK-MANIFEST 首批条目。

**Architecture:** 新建 `platform/` 包（唯一感知 OS 的层）：`ResourceLedger` 接口 + 统一内存/VRAM 两后端 + 平台探测 + 进程守护 + 引擎矩阵；上游核心（manager/gpu_state/health 等）改为从 platform 导入，行为零变化；`memory_ledger.py`/`mac_platform.py` 降级为带 DeprecationWarning 的 shim。

**Tech Stack:** Python 3.12（上游 aiohttp 网关）、pytest、launchd（无新依赖）。

**Spec:** docs/superpowers/specs/2026-11-18-python-gateway-refocus-design.md + docs/superpowers/specs/2026-11-18-mac-feature-lockdown.md（F2/F3/F8 域）

## Global Constraints

- 开发流程（锁定 §0）：修改 → 沙箱验证（`MACFABRIC_STATE_DIR=$(mktemp -d)` + `:8998` 手工起网关）→ 回归测试（`python3 -m pytest tests/ -q` 全绿）→ 提交 & push（gitcode+github）→ 生产合入（`launchctl kickstart -k gui/$(id -u)/com.macfabric.gateway` 后 `:8999` 冒烟 200）。
- 三规则语义零变化（C3）：准入文案、resident/on_demand、压力卸载行为不得改变。
- platform 包禁止反向 import manager/gpu_state/model_pool（防循环依赖）；gpu_state 仅被 resource_vram 后端以延迟导入方式引用。
- 旧导入路径 `inferfabric.memory_ledger` / `inferfabric.mac_platform` 一个版本周期内必须可用（上游 2000 测试兼容）。
- 注释/日志英文；文档中文（仓库惯例）。
- 生产操作仅限最后一个任务，且必须先看到全量回归绿。

## Review Focus

1. **非 Mac 平台导入安全**（上游 pick 落在 CUDA 机器上）：platform 在 linux 上 detect() 必须返回 vram 后端且不触发任何 darwin 探测调用 → Task 2 测试 `test_detect_linux_uses_vram_backend`（monkeypatch `sys.platform`）。
2. **旧导入路径兼容**：`from inferfabric.memory_ledger import Mode`（manager.py:34 模块级！）必须继续可用 → Task 3 测试 `test_shim_reexport_and_warning`。
3. **B 公式优先级**：`MACFABRIC_RESERVE_MB` env > policy > 8192，迁移后不得回归 → Task 4 测试 `test_budget_precedence_survives_move`。
4. **probe 不可用语义**：`probe_available_mb=None` 时 R1 仅按账面记账，不得抛异常 → 既有 test_memory_ledger 回归覆盖，Task 5 全量验证。
5. **循环依赖**：`import inferfabric.platform` 不得连带拉起 manager/model_pool → Task 2 测试 `test_platform_import_isolation`（sys.modules 断言）。

---

### Task 1: M0 基线冻结与现场提交

**Files:**
- Create: `docs/qa/2026-11-18-m0-baseline.md`
- Commit: 已暂存的 macfabric-app 删除 + 3 份 spec 文档 + 本计划

**Interfaces:**
- Produces: 基线记录（测试全量结果、双协议冒烟结果），供后续所有任务作回归对照。

- [ ] **Step 1: 跑全量单测**：`cd macfabric_gateway && python3 -m pytest tests/ -q`，结果记录入 qa 文档
- [ ] **Step 2: 沙箱双协议冒烟**：临时 state dir 起 :8998，curl OpenAI 与 Anthropic 各一发（非流式），记录结果
- [ ] **Step 3: 提交现场**：`git add -A && git commit`（App 删除 + 文档 + 计划，一次 chore/docs 提交）
- [ ] **Step 4: push 双远端**（网络失败按 memory 记录遗留，不阻塞）

### Task 2: platform 包骨架与探测装配

**Files:**
- Create: `inferfabric/platform/__init__.py`
- Test: `macfabric_gateway/tests/unit/test_platform_detect.py`

**Interfaces:**
- Produces: `PlatformProfile(os: str, resource_backend: str, procguard: str)` dataclass；`detect() -> PlatformProfile`；`MACFABRIC_FORCE_PLATFORM` env 可强制 `darwin|linux`（测试钩子）。
- darwin → `("darwin","umem","launchd")`；linux → `("linux","vram","systemd")`；其他 → `("other","vram","none")`。

- [ ] **Step 1: 写失败测试**（三平台断言 + 循环依赖隔离断言：detect 后 `sys.modules` 无 `inferfabric.manager`/`inferfabric.model_pool`）
- [ ] **Step 2: 跑测试确认失败**：`python3 -m pytest tests/unit/test_platform_detect.py -q` → ModuleNotFoundError
- [ ] **Step 3: 实现 `platform/__init__.py`**（仅 stdlib：dataclasses、os、sys）
- [ ] **Step 4: 测试通过**；提交 `feat(platform): profile detect skeleton`

### Task 3: ResourceLedger 接口 + 统一内存后端迁移

**Files:**
- Create: `inferfabric/platform/resource.py`（接口 + Mode/Lifecycle/AdmitDecision 类型定义）
- Create: `inferfabric/platform/resource_umem.py`（`UnifiedMemoryLedger(ResourceLedger)`，实现体自 `memory_ledger.py` 平移）
- Modify: `inferfabric/memory_ledger.py` → shim（re-export + DeprecationWarning）
- Test: `macfabric_gateway/tests/unit/test_platform_resource.py`（新增）；既有 `test_memory_ledger.py` 原样保留作 shim 回归

**Interfaces:**
- Produces: `ResourceLedger`（方法集 = 现 MemoryLedger 公有方法签名不变：register/admit/mark_ready/mark_sleeping/mark_stopped/touch/idle_sleep_candidates/pressure_eviction_plan/resident_total_mb/registered/entries）；`memory_ledger` shim 导出 `MemoryLedger = UnifiedMemoryLedger` 及全部枚举。

- [ ] **Step 1: 写失败测试**：从 `platform.resource_umem` 导入并复跑既有 test_memory_ledger 的三个核心场景（R1 拒绝、R2 休眠候选、R3 压力卸载计划）+ Review Focus 1 的 linux detect 断言
- [ ] **Step 2: 确认失败** → **Step 3: 实现**（实现体平移，不改行为）→ **Step 4: 通过**
- [ ] **Step 5: shim 回归**：`pytest tests/unit/test_memory_ledger.py tests/unit/test_platform_resource.py -q` 全绿（含 DeprecationWarning 断言）→ 提交 `feat(platform): ResourceLedger interface + umem backend`

### Task 4: 平台探测实现迁移（mac_platform → platform/probe.py）

**Files:**
- Create: `inferfabric/platform/probe.py`（`IS_MACOS/pid_on_port/mem_total_mb/mem_used_mb/budget_mb` 实现体平移）
- Modify: `inferfabric/mac_platform.py` → shim
- Test: 新增 `test_platform_probe.py`（budget 优先级三例）+ 既有 `test_mac_platform.py` 原样保留

**Interfaces:**
- Produces: 与 mac_platform 现签名逐字一致（manager.py 依赖 `budget_mb()/mem_used_mb()/IS_MACOS`；gpu_state.py 依赖 `pid_on_port`）。
- 迁移后 `budget_mb()` 读 `platform.detect()` 的 profile 而非直接 `sys.platform`。

- [ ] **Step 1: 写失败测试**（Review Focus 3 的三例优先级）→ **Step 2: 确认失败** → **Step 3: 平移实现** → **Step 4: 通过**
- [ ] **Step 5: shim 回归**：两个新旧测试文件全绿 → 提交 `feat(platform): probe layer move + mac_platform shim`

### Task 5: 核心装配点切换（行为零变化）

**Files:**
- Modify: `inferfabric/manager.py:34,288-289`、`inferfabric/gpu_state.py:55`、`inferfabric/health.py:20`、`inferfabric/model_lifecycle.py:117`、`inferfabric/model_discovery.py:212`
- Test: 全量回归（无新测试；本任务是纯导线更换）

**Interfaces:**
- Consumes: Task 3/4 的 platform 符号。manager 模块级 `from inferfabric.memory_ledger import Mode` 改为 `from inferfabric.platform.resource import Mode`（模块级，避开 shim 的 DeprecationWarning 噪音）。

- [ ] **Step 1: 逐文件换导入**（5 处，每处一行级 diff）→ **Step 2: `pytest tests/ -q` 全量绿**（Review Focus 4 由既有账本测试覆盖）
- [ ] **Step 3: 沙箱冒烟**（:8998 双协议 + switch qwen3-4b 一次）→ 提交 `refactor(platform): rewire core imports to platform layer`

### Task 6: VRAM 后端 + procguard + 引擎矩阵（上游化单元）

**Files:**
- Create: `inferfabric/platform/resource_vram.py`（`VramThreeStateLedger(ResourceLedger)`：延迟 import 上游 gpu_state 三态机做适配；预算语义=显存）
- Create: `inferfabric/platform/procguard.py`（`ProcGuard` 协议 + `LaunchdProcGuard/SystemdProcGuard/NullProcGuard`；plist 生成纯函数化）
- Create: `inferfabric/platform/engines.py`（平台默认引擎矩阵纯数据：darwin=llama_cpp metal/kokoro/whisper/ocr-helper；linux=vllm/sglang/ollama）
- Test: `test_platform_vram_procguard_engines.py`

**Interfaces:**
- Produces: `VramThreeStateLedger(budget_mb, gpu_state)` 构造注入 gpu_state 模块（不硬 import）；`ProcGuard.install() -> bool / uninstall() -> bool / status() -> str`；`ENGINES: dict[str, list[str]]`。

- [ ] **Step 1: 写失败测试**（vram 后端用 fake gpu_state 验证三态转换转发；launchd plist 生成含 KeepAlive 与 Label；engines 数据断言）→ **Step 2: 失败** → **Step 3: 实现** → **Step 4: 通过**（Review Focus 1 的 linux 用例在本任务收口）
- [ ] **Step 5: 提交** `feat(platform): vram backend + procguard + engine matrix (upstreamable units)`

### Task 7: D20 diff 审计 + CHERRY-PICK-MANIFEST 首批

**Files:**
- Create: `docs/upstream/CHERRY-PICK-MANIFEST.md`

**Interfaces:**
- Produces: 34 个演进文件的三级归类（通用修复→pick 分支计划 / 平台相关→platform 层 / Mac 专属→留 fork）+ F1–F10 首批摘取条目（字段：特性名、pick 分支名、commit 范围、新增文件、触碰上游文件、验收测试、状态=待摘取）。

- [ ] **Step 1: 逐文件 diff 审计**（`git diff vendor` 逐文件读，归类写入 manifest）
- [ ] **Step 2: 通知 inferfabric-pr**「manifest 首批就绪」（含 PR 目标确认回执）
- [ ] **Step 3: 提交** `docs(upstream): cherry-pick manifest batch 1 (F1-F10)`

### Task 8: 生产合入（M1 收口）

- [ ] **Step 1: 全量回归绿** → **Step 2: push 双远端** → **Step 3: 重启生产网关**（launchctl kickstart）→ **Step 4: `:8999` 双协议冒烟 200** → **Step 5: qa 记录 + 更新 STATUS.md**
