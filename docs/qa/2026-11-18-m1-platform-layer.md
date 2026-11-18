# M1 平台抽象层 收口记录 — 2026-11-18

## 回归

- 全量：`macfabric_gateway` tests **345 passed, 4 warnings**（基线 316 + platform 新增 29；4 warnings = 基线 2 + 两个 shim 的 DeprecationWarning，预期）
- 沙箱冒烟（temp state dir + :8998）：三协议入口（chat/messages/responses）结构化响应，0 traceback

## 生产合入

- push：gitcode + github 双远端至 `d090b6b`
- 生产网关重启（launchctl kickstart com.macfabric.gateway）→ `:8999/v1/models` 200
- 真实双协议冒烟（glm-5，云端）：OpenAI `/v1/chat/completions` → "ok"；Anthropic `/v1/messages` → "ok"
- 鉴权链路：security policy=all enforced，临时冒烟 key `m1-smoke` 已创建→使用→撤销（终态核对 revoked）

## 本里程碑交付

- `inferfabric/platform/`：detect/profile、ResourceLedger 接口、umem/vram 双后端、probe（端口/水位/预算）、procguard（launchd/systemd/null）、engines 矩阵
- `memory_ledger.py`/`mac_platform.py` 降级为兼容 shim（一个版本周期，DeprecationWarning）
- 核心装配点 5 处切换至 platform 层，行为零变化
- D20 diff 审计：34 演进文件三级归类（A/P/M）+ CHERRY-PICK-MANIFEST 首批 10 条目（docs/upstream/CHERRY-PICK-MANIFEST.md），已通知 peer session inferfabric-pr

## M1 验收对照（上游设计 §10）

| 验收项 | 结果 |
|---|---|
| 既有单测经 shim 全部通过 | ✅ 345 passed |
| platform 单测（两后端 + mock 探测 + 导入隔离） | ✅ test_platform_* 4 套 |
| diff 审计结论入 manifest | ✅ A/P/M 三级 + 首批条目 |
| 沙箱验证 → 回归 → 提交 push → 生产合入 全链 | ✅ |
