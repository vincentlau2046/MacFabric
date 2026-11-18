# DeviceTelemetry 双平台统一设备遥测实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 Apple Silicon 与 x86+NVIDIA 的设备资源/性能采集统一为可测试的 `DeviceTelemetry` 契约，并把业务接线、功耗持久化、API、CLI 与 Dashboard 迁移到正确的设备语义。

**Architecture:** 在现有 `inferfabric.platform` 中新增只读遥测契约、Apple/NVIDIA/Null 三个后端和唯一工厂；业务层只依赖 `DeviceTelemetry`/`DeviceControl`，不再自行识别平台或调用 `nvidia-smi`、`vm_stat`、`sysctl`。`TelemetryHub` 负责装配并向 API/采样器提供同一快照源；旧 `gpu_*` API 与 `gpu_power_samples` 以兼容 shim/view 过渡一个上游发布周期。

**Tech Stack:** Python 3、stdlib `dataclasses`/`typing.Protocol`/`subprocess`，现有 SQLite migration engine，现有原生 JS Dashboard、pytest；不新增 NVML 或其他运行时依赖。

**Spec:** `docs/superpowers/specs/2026-11-18-device-telemetry-design.md`

## Global Constraints

- 设备遥测、引擎 `/metrics`、请求指标保持三类边界；引擎指标不得进入 `DeviceSnapshot`。
- `DeviceSnapshot` 的设备字段不可用时必须是 `None`，JSON 为 `null`；不得用 0、32607 或硬件型号硬编码填充。
- Apple 使用 `sysctl`/`vm_stat`/现有 `platform.probe` 原语；NVIDIA 本期只使用 `nvidia-smi`，不引入 NVML。
- NVIDIA 多 GPU 的 v1 标量字段采用跨卡聚合口径；本期不增加 `devices[]`。
- `memory_kind=unified|vram|unknown` 决定 UI 语义；Apple 不得把统一内存比例冒充 GPU 利用率。
- `DeviceCapabilities` 表达后端静态能力；本次采集不可用由字段 `None` 与 `sources` 表达。
- 观测失败 fail-open 为 `None`；准入、`wait_gpu_free`、reset 等控制/破坏性路径 fail-closed，维持现有保守语义。
- `DeviceTelemetry` 只读；`DeviceControl.reset()` 单独定义，NVIDIA 才实现，Apple 返回明确 `unsupported`。
- 本地网关默认不限速；本计划不改变 rate-limit 默认值或等待语义。
- 功耗采样保持 60 秒间隔、90 天留存；同一快照的 timestamp 由后端生成，API 不重新拼接另一份设备数据。
- 兼容字段/旧表保留至对应特性合入上游且经过一个上游发布周期；删除条件同步写入 `docs/upstream/CHERRY-PICK-MANIFEST.md`。
- 每个任务遵循 TDD：先写一个预期失败的测试，确认 RED，再写最小实现并跑专项验证。Tasks 1–5 的提交命令仅记录可摘取分组，统一在 Task 6 沙箱验证、完整回归及整体验收后按顺序执行；再 push 两个 MacFabric remote，最后进入已获准的生产合入。不得直接操作 InferFabric 上游。

## Review Focus

1. 多行/多卡 `nvidia-smi` 输出、单字段 `N/A` 或部分命令失败时，聚合字段必须可解释，其他字段仍可用；由 Task 2 的 NVIDIA parser/backend tests 固定。
2. 设备命令缺失、超时、无权限时，采样返回 `None` 不抛异常，内存准入和等待路径不得因缺数据而放行；由 Task 2 的 failure tests 与 Task 3 的 admission tests 固定。
3. `IFF_FORCE_PLATFORM`/`MACFABRIC_FORCE_PLATFORM` 切换或未知平台时，统一层不得在 import/装配时执行错误平台命令；由 Task 1 的 factory/import tests 固定。
4. 既有 v007 数据库升级后历史功耗行不能丢，重复初始化和重复采样必须幂等；由 Task 4 的 migration/DB tests 固定。
5. Dashboard 收到 `null`、`memory_kind=unified` 或未知 capability 时必须显示不可用/隐藏不适用卡片，而不是显示 0 或 NVIDIA 文案；由 Task 5 的 API/静态契约 tests 固定。

---

### Task 1: 冻结遥测契约与唯一装配入口

**Files:**
- Create: `macfabric_gateway/inferfabric/platform/telemetry.py`
- Modify: `macfabric_gateway/inferfabric/platform/__init__.py`
- Modify: `macfabric_gateway/inferfabric/telemetry.py`
- Test: `macfabric_gateway/tests/unit/test_platform_telemetry_contract.py`

**Interfaces:**
- Consumes: `PlatformProfile` and `platform.probe` from the existing platform layer.
- Produces: `DeviceCapabilities`, `DeviceSnapshot`, `OperationResult`, `DeviceTelemetry`, `DeviceControl`, `NullTelemetry`, `NullDeviceControl`, `snapshot_to_dict(snapshot)`, `capabilities_to_dict(capabilities)`, `telemetry_for_profile(profile)`, and `device_control_for_profile(profile)`.

- [ ] **Step 1: Write the failing contract and factory tests**

  Add tests for:
  - `DeviceSnapshot` fields and JSON-ready `None` values, with `sources` keyed by field name and a single numeric `timestamp`.
  - `DeviceCapabilities` static capability shape and `OperationResult(status="unsupported")`.
  - `NullTelemetry.snapshot()` returning `platform="other"`, `accelerator="unknown"`, `memory_kind="unknown"`, all measurements `None`, without executing a platform command.
  - `telemetry_for_profile(PlatformProfile("other", "vram", "none"))` returning `NullTelemetry`.
  - `test_contract_import_does_not_probe`: importing the contract does not invoke a subprocess. Exercise concrete forced-profile selection in Task 2, after those backends exist.

- [ ] **Step 2: Run the contract tests to verify RED**

  Run: `cd macfabric_gateway && ../.venv/bin/python -m pytest tests/unit/test_platform_telemetry_contract.py -q`

  Expected: FAIL because the contract module and factory symbols do not exist.

- [ ] **Step 3: Implement the platform-neutral contract**

  In `platform/telemetry.py` define:
  - `DeviceCapabilities(frozen=True)` with `memory`, `utilization`, `power`, `temperature`, `clock`, `pressure`, `reset: bool`.
  - `DeviceSnapshot(frozen=True)` with the exact spec fields: `platform`, `accelerator`, `memory_kind`, `memory_used_mb`, `memory_total_mb`, `memory_budget_mb`, `utilization_pct`, `power_w`, `temperature_c`, `clock_mhz`, `pressure_level`, `timestamp`, `sources`.
  - `OperationResult(ok, status, message, details)` where status is `ok|unsupported|error`.
  - `DeviceTelemetry.snapshot() -> DeviceSnapshot` and `.capabilities() -> DeviceCapabilities` protocols, plus `DeviceControl.reset() -> OperationResult`. The protocol is side-effect free except for the concrete `reset()` operation; reset has no arguments in this phase and returns an explicit result.
  - Null implementations whose measurements are `None` and whose reset result is explicit `unsupported`.
  - `telemetry_for_profile()` and `device_control_for_profile()` as the only backend assembly functions. Import concrete backends lazily to keep platform-neutral imports free of subprocess execution and avoid cycles.

  Update `platform/__init__.py` exports only as needed; do not import NVIDIA/Apple command implementations at package import time.

- [ ] **Step 4: Inject the assembled device telemetry into `TelemetryHub`**

  Extend `TelemetryHub.__init__(data_dir, if_yaml_config=None, *, device_telemetry: DeviceTelemetry | None = None)` with optional injection. Task 1's factories return Null for all profiles until Task 2 wires concrete branches; Task 1 must not change any live caller behavior. `TelemetryHub.device_telemetry` exposes the raw provider. Keep device control out of the hub; only the manager/process composition needs it. Leave request/engine collectors unchanged.

- [ ] **Step 5: Run contract and existing telemetry tests**

  Run: `cd macfabric_gateway && ../.venv/bin/python -m pytest tests/unit/test_platform_telemetry_contract.py tests/unit/test_monitor_contract.py -q`

  Expected: PASS, with no import-time platform command execution and no existing monitor contract regressions.

- [ ] **Step 6: Commit the contract boundary**

  ```bash
  git add macfabric_gateway/inferfabric/platform/telemetry.py macfabric_gateway/inferfabric/platform/__init__.py macfabric_gateway/inferfabric/telemetry.py macfabric_gateway/tests/unit/test_platform_telemetry_contract.py
  git commit -m "feat: define unified device telemetry contract\n\nCo-Authored-By: Claude Code <noreply@anthropic.com>"
  ```

### Task 2: Implement Apple, NVIDIA, and Null telemetry backends

**Files:**
- Create: `macfabric_gateway/inferfabric/platform/apple_telemetry.py`
- Create: `macfabric_gateway/inferfabric/platform/nvidia_telemetry.py`
- Modify: `macfabric_gateway/inferfabric/platform/telemetry.py`
- Test: `macfabric_gateway/tests/unit/test_platform_telemetry_backends.py`

**Interfaces:**
- Consumes: Task 1 `DeviceSnapshot`, `DeviceCapabilities`, `OperationResult`, `DeviceTelemetry`, `DeviceControl`; existing `platform.probe` functions; injected subprocess runner for NVIDIA.
- Produces: `AppleSiliconTelemetry`, `NvidiaTelemetry`, `NvidiaDeviceControl`, and parsers/helpers testable without hardware.

- [ ] **Step 1: Write failing backend tests**

  Add tests for:
  - Apple mock probes yielding `memory_kind="unified"`, `memory_used_mb` from `mem_used_mb()`, physical `memory_total_mb` from `mem_total_mb()`, `memory_budget_mb` from `budget_mb()`, and `sources` values matching the probe names.
  - Apple unavailable optional probes yielding `None` for power/temperature/clock/utilization rather than zero or an exception; static capabilities mark those unsupported when appropriate.
  - NVIDIA multi-line output aggregating memory used/total and power across all cards, averaging utilization/temperature/clock only where the contract requires a scalar, and preserving `accelerator="nvidia"`, `memory_kind="vram"`.
  - NVIDIA `N/A`/malformed rows, missing executable, non-zero exit, and timeout isolating failed fields; no backend call raises to its caller.
  - NVIDIA reset control returning `unsupported` on non-NVIDIA/Null and a structured `error`/`ok` result for mocked reset commands; no reset command is issued by `snapshot()`.

- [ ] **Step 2: Run backend tests to verify RED**

  Run: `cd macfabric_gateway && ../.venv/bin/python -m pytest tests/unit/test_platform_telemetry_backends.py -q`

  Expected: FAIL because backend modules and parsers do not exist.

- [ ] **Step 3: Implement `AppleSiliconTelemetry`**

  Implement `AppleSiliconTelemetry(*, clock=time.time)` using `platform.probe` for memory and budget. Extract a probe helper that accepts the sampled physical total so `vm_stat` usage and `_budget_core` can share one `sysctl` read while the existing no-arg probe/shim behavior stays unchanged; when total is absent the observation budget is `None`, not the ledger's internal fallback `0`. Run a bounded, unprivileged Apple memory-pressure probe in `platform/probe.py`; parse only recognized pressure levels and return `None` on failure. Leave power, temperature, clock and utilization unsupported until there is a verified unprivileged source. Add `test_apple_missing_physical_memory_does_not_publish_zero_budget` and `test_apple_used_total_budget_share_physical_read`; use fake command output and test the factory's selected profile without reloading probe modules. Add `platform/probe.py` to this task's diff and regression.

- [ ] **Step 4: Implement `NvidiaTelemetry`**

  Implement `NvidiaTelemetry(*, run=None, clock=time.time)` and `parse_nvidia_snapshot(stdout: str, *, timestamp: float) -> DeviceSnapshot`. Query `memory.used,memory.total,utilization.gpu,power.draw,temperature.gpu,clocks.sm` with CSV `noheader,nounits` and a bounded timeout. Per field, require complete valid readings across the returned cards; otherwise that field alone is `None` (never expose a partial sum as the fleet total). Sum memory and power, average utilization/temperature/clock (round clock to the nearest integer), and derive `memory_budget_mb = int(memory_total_mb * .97)` from the existing VRAM guard. Reject nonfinite, out-of-range or malformed cells. Command errors yield a Linux snapshot with unavailable observations. In `test_nvidia_aggregates_complete_columns_only`, rows `100,1000,10,100,40,1500` and `200,2000,30,N/A,60,1700` produce `(300, 3000, 2910, 20.0, None, 50.0, 1600)` in field order. `test_forced_profile_selection_is_lazy` covers both env aliases, precedence, and no subprocess on assembly.

- [ ] **Step 5: Implement `NvidiaDeviceControl` and connect the factory**

  Implement `NvidiaDeviceControl(*, gpu_index: int = 0, run=None)` with no-argument `reset() -> OperationResult`; `device_control_for_profile(profile: PlatformProfile, *, gpu_index: int = 0) -> DeviceControl` binds the existing CLI target. Relocate the existing NVIDIA reset operation without adding triggers, privileges, or fallback commands; a scoped request must never fall through to an unscoped action unless all affected cards are verified idle. `test_reset_unknown_occupancy_issues_no_write` and `test_indexed_reset_never_widens_scope_when_other_card_busy` use mocked commands only. Apple/Null return `unsupported` with no command and no polling. Keep managed service stop/reset separate from hardware reset. Wire lazy factories for Darwin/Apple Silicon, Linux/NVIDIA and unknown/Null.

- [ ] **Step 6: Run backend tests and platform regression tests**

  Run: `cd macfabric_gateway && ../.venv/bin/python -m pytest tests/unit/test_platform_telemetry_backends.py tests/unit/test_platform_detect.py tests/unit/test_platform_probe.py tests/unit/test_platform_vram_procguard_engines.py -q`

  Expected: PASS; existing platform suite remains green and no NVML import is present.

- [ ] **Step 7: Commit the platform backends**

  ```bash
  git add macfabric_gateway/inferfabric/platform/apple_telemetry.py macfabric_gateway/inferfabric/platform/nvidia_telemetry.py macfabric_gateway/inferfabric/platform/telemetry.py macfabric_gateway/tests/unit/test_platform_telemetry_backends.py
  git commit -m "feat: add Apple and NVIDIA telemetry backends\n\nCo-Authored-By: Claude Code <noreply@anthropic.com>"
  ```

### Task 3: Migrate health, admission, lifecycle, control, and CLI wiring

**Files:**
- Modify: `macfabric_gateway/inferfabric/health.py`
- Modify: `macfabric_gateway/inferfabric/health_checker.py`
- Modify: `macfabric_gateway/inferfabric/manager.py`
- Modify: `macfabric_gateway/inferfabric/gpu_state.py`
- Modify: `macfabric_gateway/inferfabric/model_lifecycle.py`
- Modify: `macfabric_gateway/inferfabric/process_manager/base.py`
- Modify: `macfabric_gateway/inferfabric/cli.py`
- Test: `macfabric_gateway/tests/unit/test_device_telemetry_wiring.py`

**Interfaces:**
- Consumes: Task 1/2 `DeviceTelemetry`, `DeviceControl`, `DeviceSnapshot`, `OperationResult`.
- Produces: deprecated `gpu_used_mb()`/`gpu_total_mb()` shims delegating to the device snapshot; fail-closed admission/wait behavior; manager status legacy fields derived from one snapshot; reset command delegation through `DeviceControl`.

- [ ] **Step 1: Write failing wiring and fail-closed tests**

  Use a fake telemetry object to assert:
  - `health.gpu_used_mb()` and `health.gpu_total_mb()` delegate to one snapshot and return `None` when unavailable; Apple `gpu_total_mb()` uses `memory_budget_mb`, not physical `memory_total_mb`.
  - `wait_gpu_free()` returns `False` when used memory is unavailable, never treating `None` as zero.
  - Manager status emits `device` plus legacy `gpu_used_mb`, `gpu_total_mb`, and `gpu_util_pct`; Apple legacy utilization is `None`, not a used/total percentage.
  - Peak/pct admission rejects with a visible telemetry-unavailable message when required memory fields are `None`; existing healthy values preserve current admission behavior.
  - `DeviceControl.reset()` is the only reset path called by the reset operation; Apple returns unsupported and NVIDIA results are surfaced.

- [ ] **Step 2: Run wiring tests to verify RED**

  Run: `cd macfabric_gateway && ../.venv/bin/python -m pytest tests/unit/test_device_telemetry_wiring.py -q`

  Expected: FAIL because current helpers call platform-specific commands, return numeric sentinels, and manager/lifecycle do not accept a telemetry dependency.

- [ ] **Step 3: Add dependency injection and compatibility helpers**

  Add optional `device_telemetry: DeviceTelemetry | None = None` and `device_control: DeviceControl | None = None` parameters to `ModelManager.__init__`, then pass them to `GpuStateMachine` and `ModelLifecycle` through appended optional parameters. Refactor health helpers to `gpu_used_mb(telemetry: DeviceTelemetry | None = None) -> int | None`, `gpu_total_mb(telemetry: DeviceTelemetry | None = None) -> int | None`, and `wait_gpu_free(..., telemetry: DeviceTelemetry | None = None) -> bool`; mark them deprecated in docstrings. Add `snapshot_for_status(telemetry: DeviceTelemetry | None = None) -> DeviceSnapshot` so manager status derives all legacy fields from one snapshot.

- [ ] **Step 4: Make memory wait and admission fail closed**

  Use the fresh provider (never the API cache) for control observations. Update `wait_gpu_free`, `_get_current_vram_pct() -> float | None`, and both lifecycle VRAM guards: if the existing new-allocation check requires VRAM and the reading is absent, return an explicit unavailable error; retain existing GPU-none and already-running bypasses. Apple uses the existing ResourceLedger budget/rules: unknown budget keeps its conservative fallback, unknown live usage falls back to the ledger's accounting, and the UI cache never feeds admission. Do not apply CUDA idle polling to Apple. Update `interfaces.py:IHealthChecker`, `process_manager/sglang.py`, and `process_manager/facade.py` as corresponding wiring sites; the SGLang cleanup wait must not report the device free if its measurement is absent. Pin these paths in `test_device_telemetry_wiring.py` and include the files in the scoped commit.

- [ ] **Step 5: Move reset and CLI output to device semantics**

  Route manager/process reset through `DeviceControl.reset()`, retaining the existing safety checks and explicit unsupported/error messages. Update `iff status`/`iff reset` to show `memory_kind` and unavailable values as `—`; keep GPU wording only for `memory_kind="vram"`. Keep `gpu-clear` compatibility behavior only where the control backend supports it.

- [ ] **Step 6: Run wiring, lifecycle, and complete unit regression**

  Run: `cd macfabric_gateway && ../.venv/bin/python -m pytest tests/unit/test_device_telemetry_wiring.py tests/unit/test_memory_ledger.py tests/unit/test_mac_platform.py tests/unit/test_platform_*.py -q`

  Expected: PASS; all existing resource-ledger and platform tests remain green, including Mac shim patch compatibility.

- [ ] **Step 7: Commit business-layer wiring**

  ```bash
  git add macfabric_gateway/inferfabric/health.py macfabric_gateway/inferfabric/health_checker.py macfabric_gateway/inferfabric/manager.py macfabric_gateway/inferfabric/gpu_state.py macfabric_gateway/inferfabric/model_lifecycle.py macfabric_gateway/inferfabric/process_manager/base.py macfabric_gateway/inferfabric/cli.py macfabric_gateway/tests/unit/test_device_telemetry_wiring.py
  git commit -m "refactor: route admission and control through device telemetry\n\nCo-Authored-By: Claude Code <noreply@anthropic.com>"
  ```

### Task 4: Migrate power persistence and sampling with legacy compatibility

**Files:**
- Create: `macfabric_gateway/inferfabric/migrations/v011_device_power_samples.py`
- Modify: `macfabric_gateway/inferfabric/migrations/__init__.py`
- Modify: `macfabric_gateway/inferfabric/db.py`
- Modify: `macfabric_gateway/inferfabric/power_stats.py`
- Modify: `macfabric_gateway/inferfabric/telemetry.py`
- Test: `macfabric_gateway/tests/unit/test_device_power_persistence.py`

**Interfaces:**
- Consumes: Task 1/2 `DeviceTelemetry.snapshot()` and `TelemetryHub.device_telemetry`.
- Produces: `device_power_samples(ts, accelerator, device_id, watts, source)`, `insert_device_power_samples`, `query_device_power_samples`, `prune_device_power_samples`, and a compatibility read path for `query_gpu_power_samples`/old rows.

- [ ] **Step 1: Write failing migration, idempotence, and sampler tests**

  Add tests for:
  - v011 upgrading a database containing v007 `gpu_power_samples` while retaining all old rows and making the compatibility view/query return `accelerator=unknown`, `device_id=unknown`, and the legacy source marker.
  - repeated migration initialization being idempotent.
  - `PowerSampler` recording a successful snapshot power with accelerator/device/source metadata and skipping `None` without inserting a fake zero.
  - 60-second sampling and 90-day pruning behavior remaining unchanged.

- [ ] **Step 2: Run persistence tests to verify RED**

  Run: `cd macfabric_gateway && ../.venv/bin/python -m pytest tests/unit/test_device_power_persistence.py -q`

  Expected: FAIL because v011 and device-scoped DB methods do not exist.

- [ ] **Step 3: Add v011 schema and migration registration**

  Create `device_power_samples` with `ts`, `platform`, `accelerator`, `device_id`, `watts`, and `source`, keyed by `(ts, accelerator, device_id)`. In a single SQLite transaction create the replacement, copy all v007 rows with `platform=accelerator=device_id="unknown"` and `source="legacy_gpu_power_samples"`, drop the replaced table, and create the required read-only compat view `gpu_power_samples(ts, watts)`. The view includes historical and NVIDIA aggregate samples only, preferring legacy on timestamp collision. Set request DB `user_version=11` in the same transaction. All writes go to the new table; preserve the legacy Python read shape and redirect legacy write/prune methods rather than writing to the view. Test failed-copy rollback and preserve the `[since, until)` and ascending timestamp contracts. Do not attribute old rows to a fabricated GPU or device.

- [ ] **Step 4: Add DB facade methods and migrate power sampler**

  Implement `IFFDB.insert_device_power_samples(samples)`, `query_device_power_samples(since, until=None, limit=300000)`, and `prune_device_power_samples(before)`. Change `PowerSampler.__init__(db, interval=60.0, telemetry=None)` to consume `TelemetryHub.device_telemetry` (or the factory default), write one aggregate device sample per successful snapshot, and keep `probe_gpu_power_w()` as a deprecated shim delegating to `snapshot().power_w` for callers outside the sampler.

- [ ] **Step 5: Keep power-series API behavior while reading new rows**

  Keep `/api/power` as the legacy view and add `/api/device_power` with the same `{gran, buckets, totals, available}` shape. Keep legacy (`unknown/unknown`) and current (`accelerator/aggregate`) streams separate before energy integration so a v007 first-card sample is never interpolated against a v011 all-card sample. Expose history in the compatibility API; the new API returns the current aggregate stream, and the monitor pulls the new API. Use `ts=int(snapshot.timestamp)` and `device_id="aggregate"` for new samples. Verify `test_power_series_does_not_interpolate_across_streams`, `test_sampler_keeps_real_zero_and_skips_none` and compatibility view shape separately from the new metadata query.

- [ ] **Step 6: Run persistence and full Python regression**

  Run: `cd macfabric_gateway && ../.venv/bin/python -m pytest tests/unit/test_device_power_persistence.py tests/unit/test_monitor_contract.py -q` and then `../.venv/bin/python -m pytest tests/ -q`

  Expected: both PASS; migration registry and all existing tests remain green.

- [ ] **Step 7: Commit persistence changes**

  ```bash
  git add macfabric_gateway/inferfabric/migrations/v011_device_power_samples.py macfabric_gateway/inferfabric/migrations/__init__.py macfabric_gateway/inferfabric/db.py macfabric_gateway/inferfabric/power_stats.py macfabric_gateway/inferfabric/telemetry.py macfabric_gateway/tests/unit/test_device_power_persistence.py
  git commit -m "feat: persist platform-neutral device power samples\n\nCo-Authored-By: Claude Code <noreply@anthropic.com>"
  ```

### Task 5: Normalize API snapshot/system output and Dashboard null semantics

**Files:**
- Modify: `macfabric_gateway/inferfabric/proxy/handler.py`
- Modify: `macfabric_gateway/inferfabric/dashboard/js/store.js`
- Modify: `macfabric_gateway/inferfabric/dashboard/js/overview.js`
- Modify: `macfabric_gateway/inferfabric/dashboard/js/monitor.js`
- Test: `macfabric_gateway/tests/unit/test_device_api_contract.py`
- Test: `macfabric_gateway/tests/unit/test_dashboard_device_contract.py`

**Interfaces:**
- Consumes: Task 1/2 `TelemetryHub.device_telemetry`, `DeviceSnapshot`, `DeviceCapabilities`; Task 4 power series.
- Produces: `/api/device_metrics`, `snapshot.device`, a platform-neutral `/system` device section, and frontend state/rendering that preserves `null` and uses `memory_kind`/capabilities.

- [ ] **Step 1: Write failing API and frontend contract tests**

  Add Python tests asserting:
  - `/api/snapshot` contains `device.snapshot`, `device.capabilities`, and one timestamp shared by device fields; legacy `gpu_*` fields follow the approved Apple mapping.
  - `/api/device_metrics` returns snapshot, capabilities, timestamp, and sources with JSON `null` for unavailable fields.
  - `/system` no longer directly executes `nvidia-smi`; its device values come from the same telemetry snapshot and unavailable values remain `None`.
  - `/api/device_power` calls the current aggregate query and `/api/power` calls the legacy query; neither route contaminates the other's per-granularity 5-minute cache.

  Add static JS contract tests (following the project’s existing source-level test style) asserting `store.js`, `overview.js`, and `monitor.js` do not contain `|| 32607`, `|| 0` sentinel fallback for device metrics, or 5090D/TDP hard-coded device limits; they handle `memory_kind="unified"` and null power/utilization as unavailable.

- [ ] **Step 2: Run API/frontend tests to verify RED**

  Run: `cd macfabric_gateway && ../.venv/bin/python -m pytest tests/unit/test_device_api_contract.py tests/unit/test_dashboard_device_contract.py -q`

  Expected: FAIL because current snapshot lacks `device`, `/api/device_metrics` is absent, `/system` calls `nvidia-smi`, and Dashboard normalizes missing values to fake numbers.

- [ ] **Step 3: Add API routes and same-snapshot serialization**

  Add `/api/device_metrics` and `TelemetryHub.get_device_snapshot() -> DeviceSnapshot`: per-hub observation cache with monotonic 15s TTL and one refresh per expiry (including cold start); controls and persisted samples use the raw provider. `/api/device_metrics` returns `{snapshot, capabilities}` with `timestamp` and `sources` inside `snapshot`; `/api/snapshot.device` is the very same envelope. Make `/status` and `/system` project this cached reading too; `_system_info(snapshot)` no longer runs a GPU subprocess. In `_handle_snapshot`, cache service health separately via `ModelManager.status(*, include_device=False)`, then derive `status.gpu_*` from the exact reading used for `device` and `system`. Keep NVIDIA `status.gpu_util_pct` as legacy VRAM occupancy and `system.gpu_util_pct` as device utilization; Apple returns null for both. Preserve ETag change detection for actual values, sources and capabilities; treat sampling timestamp as volatile only in the hash. Add `test_device_routes_share_one_probe_and_timestamp`, `test_snapshot_etag_changes_when_device_value_changes`, and a TTL-expiry test with fake clock and counted provider calls.

- [ ] **Step 4: Migrate Dashboard state and cards**

  In `store.js`, retain nulls instead of `|| 0`/`|| 32607` and expose `device`, `memory_kind`, and capability state. In `overview.js`, render unified memory labels/budget correctly and hide unsupported utilization/power cards rather than drawing zero. In `monitor.js`, render unavailable totals/average power as `—`, keep power chart empty-state behavior, and remove fixed 600W/5090D assumptions in favor of available data or an explicit no-scale empty state.

- [ ] **Step 5: Run API, source contracts, and frontend build/checks**

  Run: `(cd macfabric_gateway && ../.venv/bin/python -m pytest tests/unit/test_device_api_contract.py tests/unit/test_dashboard_device_contract.py tests/unit/test_monitor_contract.py -q)` and, from the MacFabric root, `for f in store overview monitor; do node --check "macfabric_gateway/inferfabric/dashboard/js/$f.js" || exit; done`.

  Expected: PASS. The Dashboard is served as native JS by the Python gateway; it has no separate SPA build. Exercise actual null, real zero and unsupported states in the Task 6 browser smoke.

- [ ] **Step 6: Commit API and Dashboard migration**

  ```bash
  git add macfabric_gateway/inferfabric/proxy/handler.py macfabric_gateway/inferfabric/dashboard/js/store.js macfabric_gateway/inferfabric/dashboard/js/overview.js macfabric_gateway/inferfabric/dashboard/js/monitor.js macfabric_gateway/tests/unit/test_device_api_contract.py macfabric_gateway/tests/unit/test_dashboard_device_contract.py
  git commit -m "feat: expose platform-neutral device metrics\n\nCo-Authored-By: Claude Code <noreply@anthropic.com>"
  ```

### Task 6: T4 双平台验收、兼容清单与交付证据

**Files:**
- Modify: `docs/upstream/CHERRY-PICK-MANIFEST.md`
- Create: `docs/qa/2026-11-18-device-telemetry.md`
- Modify: `docs/superpowers/specs/2026-11-18-device-telemetry-design.md` only if implementation clarifies a contract without changing the approved decisions

**Interfaces:**
- Consumes: Tasks 1–5 complete contract, backend, wiring, DB, API, and Dashboard behavior.
- Produces: Darwin sandbox evidence, forced-Linux/NVIDIA mock evidence, compatibility retirement condition, and manifest entry for the cherry-pickable feature.

- [ ] **Step 1: Preflight and run the native Apple sandbox**

  Verify the MacFabric checkout, `.venv/bin/python`, `node`, idle `127.0.0.1:8998`, and reachable production `/health` without touching its process. Under a private temp directory set `MACFABRIC_STATE_DIR` and `IFF_DATA_DIR` to its isolated state, and `MACFABRIC_MODELS_DIR` to its isolated model directory. Start `(cd macfabric_gateway && EDGE_PROXY_HOST=127.0.0.1 EDGE_PROXY_PORT=8998 ../.venv/bin/python -m inferfabric.proxy.handler)` with those exports and track only its PID/log. Use empty local model config and a synthetic upstream fixture for protocol or migration smokes; do not link production packs, secrets or state. Verify `/health`, `/api/device_metrics`, `/api/snapshot`, `/status`, `/system`, `/api/power`, the Dashboard, and OpenAI/Anthropic protocol baselines. `/api/snapshot.device` matches `/api/device_metrics` inside the cache window. Dashboard shows unified memory, physical total distinct from budget, and no fake watts or utilization. Never perform real hardware reset during QA.

- [ ] **Step 2: Run regressions and capture the terminal result**

  Run `make test` at repo root (expect exit 0 and `ALL_GREEN`), and `(cd macfabric_gateway && IFF_FORCE_PLATFORM=linux ../.venv/bin/python -m pytest tests/unit/test_platform_telemetry_backends.py tests/unit/test_device_api_contract.py -q)` (expect mocked Linux/VRAM paths to pass, not physical CUDA acceptance). Poll sandbox readiness and regression terminal outputs with deadlines; stop and report if the gateway exits early, a deadline expires, or any gate fails. Terminate the sandbox PID only and verify its port is free. Record outputs + browser result + cleanup in the QA file. Physical CUDA acceptance remains a separate upstream gate, not inferred from the mock.

- [ ] **Step 3: Review and commit the validated work**

  Run a fresh whole-change review on the isolated change set. Resolve blockers with RED→GREEN tests and rerun affected gates before committing. Commit Tasks 1–5 in logical groups as listed, using scoped staging (including the follow-on files identified per task). Use `git commit -m '<subject>' -m 'Co-Authored-By: Claude Code <noreply@anthropic.com>'`, not literal `\n` sequences inside `-m`. Record `pick/device-telemetry`, the actual validated commit range, platform-layer dependency, separate CUDA gate, and “upstream merge + one release cycle” retirement condition in the manifest. Preserve edits owned by other sessions; record no NVML or default rate-limit change. Commit the plan and QA/manifest changes separately.

- [ ] **Step 4: Push both MacFabric remotes and hand off**

  Push only the validated MacFabric branch at the authorized integration point, verify both remotes resolve to the intended commit, and hand the pick range, compatibility rules and CUDA acceptance instructions to `inferfabric-pr`. Do not open or merge the InferFabric PR from this session.

- [ ] **Step 5: Production rollout only after the deployment gate**

  Before any restart, record the active revision, launchd target and rollback procedure; take a consistent SQLite backup of `request_log.db` using SQLite backup (not a copy of the live WAL db file). A v011 rollback needs the pre-migration database or a separately verified downgrade, not just old code against a read-only view. Once authorized, restart the existing production gateway (do not reinstall), then verify :8999 health, both protocols and Dashboard. Capture pass/fail separately from sandbox evidence; on failure stop rollout and follow the authorized rollback procedure.

## Plan self-review

- **Spec coverage:** §5 ownership is Task 1/3/5; §6 contract is Task 1; §7 backends are Task 2; §8 business/API/DB/Dashboard wiring is Tasks 3–5; §9 compatibility is Tasks 4–6; §10 tests are every task; §11 T0–T4 map to Tasks 1–6; §14 decisions are encoded in Global Constraints and task assertions.
- **Type consistency:** Task 1 owns all contract names; Tasks 2–5 consume those exact names. `TelemetryHub.device_telemetry` is the single injected source used by power, API, and manager-facing adapters.
- **Legacy mapping:** `gpu_total_mb()` maps to budget B on Apple only, and to physical VRAM total on NVIDIA. `DeviceSnapshot.memory_total_mb` always means physical total.
- **Review Focus coverage:** backend failure/aggregation, fail-closed controls, lazy selection, old-schema migration, and presentation of missing data are covered in Tasks 1–5; Task 6 specifies HTTP and browser verification.
- **Proportion:** six tasks follow the approved T0–T4 sequence, with persistence and UI separated because each has an independent schema/contract test cycle.
