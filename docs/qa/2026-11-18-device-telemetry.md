# QA — DeviceTelemetry 双平台设备遥测（2026-11-18）

Plan: `docs/superpowers/plans/2026-11-18-device-telemetry.md` ·
Spec: `docs/superpowers/specs/2026-11-18-device-telemetry-design.md` ·
Branch: `feat/device-telemetry`（基线 `2a346e1`，范围 `2a346e1..773a750`，7 commits（含终审修复 `773a750`））

## 1. 自动化回归（全部本轮实跑）

| 门 | 命令 | 结果 |
|---|---|---|
| 仓库全量 | `make test`（repo root） | **426 passed，exit 0，`ALL_GREEN`**（修复后复跑） |
| 平台后端契约 | `pytest tests/unit/test_platform_telemetry_contract.py tests/unit/test_platform_telemetry_backends.py` | 29 passed（含 import 零探针投毒用例、v007 钉定聚合用例） |
| 业务接线 | `pytest tests/unit/test_device_telemetry_wiring.py` | 15 passed（fail-closed 准入/等待/reset 路由） |
| 持久化迁移 | `pytest tests/unit/test_device_power_persistence.py` | 12 passed（v011 拷贝/幂等/回滚/兼容视图/流隔离） |
| API/前端契约 | `pytest tests/unit/test_device_api_contract.py tests/unit/test_dashboard_device_contract.py` | 9+5 passed（单探针单时间戳、ETag 易变位、null 语义、源级 5090D/32607 清除） |
| 强制 Linux/NVIDIA mock | `IFF_FORCE_PLATFORM=linux pytest tests/unit/test_platform_telemetry_backends.py tests/unit/test_device_api_contract.py` | **28 passed**（mock 路径，非物理 CUDA 验收） |
| JS 语法 | `node --check store.js overview.js monitor.js` | 全过 |

## 2. Darwin 原生沙箱（:8998，隔离状态目录）

启动：`MACFABRIC_STATE_DIR/MACFABRIC_MODELS_DIR/IFF_DATA_DIR` 均指向临时私有目录，
`EDGE_PROXY_HOST=127.0.0.1 EDGE_PROXY_PORT=8998 python -m inferfabric.proxy.handler`；
空模型目录（无生产 pack/密钥/状态）；只跟踪本 PID 与日志；**从未执行真实硬件 reset**。

| 检查 | 证据 |
|---|---|
| `/health` | `{"status": "ok", "gpu_mode": "idle"}` |
| `/api/device_metrics` | `platform=darwin, accelerator=apple_silicon, memory_kind=unified`；used=20384 / total=36864 / **budget=28672**（物理总量与预算分离 ✓）；utilization/power/temp/clock = **null**（不伪造）；`pressure_level=1`；`sources` 逐字段标注 sysctl/vm_stat/probe |
| `/status` | `gpu_used_mb=20327, gpu_total_mb=28672`（Apple→预算 §14.2 映射 ✓），`gpu_util_pct=null`；`device` 信封在位 |
| `/api/snapshot` | `device.snapshot.timestamp` ≡ `system.device.snapshot.timestamp`（同一缓存读数 ✓）；`status.gpu_*` 由同一读数推导；caps.memory=true |
| `/api/device_metrics` ≡ `snapshot.device` | 两次请求信封逐字段相等（15s 缓存窗口内）✓ |
| `/system` | `gpu_util_pct/gpu_power_w/gpu_temp_c = null`；**无 nvidia-smi 子进程**（单测钉定 subprocess.run 投毒） |
| `/api/power` vs `/api/device_power` | 双端点 shape 一致，`available=false`（全新库无样本），互不污染缓存（单测 + 独立 TTL dict） |
| Dashboard | `GET / → 200`（1.46MB）；所下 HTML 内联 JS 含 `memory_kind`×4、`统一内存`、`/api/device_power`×6，`32607` 哨兵 0 处 |
| 协议基线 | `/v1/models` → `{"error": "no upstream available"}`；未知模型 chat → 404 `Unknown model`（空模型目录下预期形态） |
| ETag | 单测钉定：设备采样时间戳为易变位（仅时间戳变化 → etag 不变）；实际值/sources/caps 变化 → etag 变 |

**沙箱期间抓到并修复的缺陷**：`/api/snapshot` 500 —— `_handle_snapshot` 把已转换的
capabilities dict 传入 `_system_info` 二次转换（`'dict' has no .memory`）。
修复 `ca3aae8`，回归测试 `test_snapshot_handler_uses_real_system_info` RED→GREEN。

**终审修复（773a750，fresh opus 全分支评审后单次修复通道，全部 RED→GREEN）**：
① Critical——`test_force_reset_gpu_free_handles_none` 经真实 ProcessManager 触发
宿主级 pkill/fuser/nvidia-smi，改为 stub 进程门面；② `force_reset` 的 `gpu_free`
改用等待结果（不再用过期采样）；③ `force_kill_all` 清理走占用闸路径；④ 设备读数
缓存单飞（并发一探）；⑤ v011 legacy 表检查移入写事务（并发初始化竞态）+ 兼容视图
排除 per-device 行。Important 中 2 项降级 Minor 落账（驱动层自拒、跨机库迁移场景），
5 项 Minor 延后——详见 SDD 台账 rulings。

**清理**：sandbox PID kill → `lsof tcp:8998` 空；生产 :8999 全程未被触碰（`/health` 前后均 ok）。

**限制**：本机无 Chrome，浏览器视觉冒烟以所下资产断言替代（逻辑由源级契约测试钉定）；
Task 6 计划中的真实浏览器空态/零值渲染检查留待有浏览器环境时补。

## 3. 明确不在本门内

- **物理 CUDA 验收**：x86+NVIDIA 真机（多卡聚合、nvidia-smi 完整列规则、`--gpu-reset` 占用闸）为上游独立验收门，本门仅覆盖 mock 路径。
- **D24 限流**：本工作无任何 ratelimit 变更。
- **NVML**：未引入，nvidia-smi-only 维持。

## 4. 兼容退役条件

legacy `gpu_used_mb`/`gpu_total_mb` shim、`gpu_power_samples` 兼容视图、`/api/power`
legacy 流：**上游合入 + 一个发布周期**后移除；回滚 v011 需迁移前 SQLite 备份
（`sqlite3 .backup`，禁止拷贝活 WAL 文件）或单独验证过的降级脚本。

## 5. 生产合入（gateway-v7.11.0，用户授权 2026-11-18）

| 步骤 | 证据 |
|---|---|
| 部署前备份 | `~/.inferfabric/backups/request_log-pre-v011-20261118-215116.db`（SQLite backup API，user_version=10，legacy 表 0 行） |
| 主线合版 | feat/device-telemetry FF-merge → main `2574b3b`，tag `gateway-v7.11.0`（双远端已推） |
| 安装 | `scripts/release-install.sh gateway-v7.11.0`（codeload 取包 → 原子换板 → 冒烟 import OK）；旧版保留 `prod.old`，plist 备份 `.bak-20261118-215216` |
| 迁移生效 | 生产 request_log.db `user_version=11`；`device_power_samples` 表 + `gpu_power_samples` 兼容视图在位 |
| /health | ok, gpu_mode=idle |
| /api/device_metrics | darwin/apple_silicon/unified：20095/36864 MiB，budget 28672，util/power/temp=null |
| /status | gpu_used_mb=20047, gpu_total_mb=28672（预算映射），device 信封在位 |
| /api/snapshot | device 与 system.device 同一时间戳 |
| 协议 | /v1/models 200；/v1/messages 无 key 401（正确拒绝） |
| 功耗端点 | /api/power 与 /api/device_power 均 available=false（新流无样本，预期） |
| Dashboard | 200（1.47MB），内含 memory_kind/统一内存/device_power 新逻辑 |

**回滚程序**：`mv prod prod.broken && mv prod.old prod` + `cp plist.bak-20261118-215216 plist` +
`launchctl kickstart -k gui/$(id -u)/com.macfabric.gateway`；数据库回滚用迁移前备份恢复 request_log.db。
