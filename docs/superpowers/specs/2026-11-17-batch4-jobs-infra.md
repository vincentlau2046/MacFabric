# 批 4：TOP3b 任务化 + TOP4 第二步 + 次级 1（测试基建）

日期：2026-11-17 · 状态：按 memory 裁决（audit-2026-11-17-rulings）实施

## 范围（三块，按序实施）

### 次级 1：测试基建（小，先做）

- Makefile：`make test` 一键跑全链（契约 + pytest + 双档构建）；
- CI（GitHub Actions）：push/PR 跑 pytest + 契约；构建验证 macOS runner（可选后续）；
- 环境依赖测试显式化：现状摸底 = 全部单测走本机回环假服务/monkeypatch，
  无外网/真模型依赖，无静默 skip —— 本批补显式 guard：
  `tests/unit/test_no_network_dependency.py` 扫描测试源码禁外网字面量（防回归）。

### TOP3b：云端发现/switch 任务化（大，核心）

网关侧（复用 packs 202+Thread+轮询模式）：
1. `jobs.py`：JobRegistry 纯逻辑状态机（queued/running/done/failed/cancelled），
   单测钉住状态迁移与取消语义；
2. `/admin/cloud/discover` POST → 202 {job_id}；discover_all 加 cancel_check 回调
  （provider 循环间协作式检查，网络抓取保持锁外）；
3. `GET /admin/jobs/{id}` 轮询；`POST /admin/jobs/{id}/cancel` 取消；
4. `/switch` → 202 + job（switch 本体同步执行线程化；409 switching gate 保留）；
   取消 = 放弃等待 + 结果仍如实落 state（模型加载无法安全中断，诚实呈现）。

App 侧：
5. cloudDiscover/switchModel 改发起 job + 轮询 + 进度卡 + 取消按钮；
6. 快操作（/stop /sleep /wake）保持同步，不任务化。

### TOP4 第二步：dark 走查

- 织物条/监控柱状图/9 能力线深色对比度走查 —— 依赖原生截图矩阵，
  TCC 屏幕录制权限阻塞中（待权限路径裁决）；批 2 已完成 token 自适应地基，
  走查发现的个例修正在该解除后进行。

## 红线

- 生产 :8999 零接触；dev :8998 验证；
- /switch 任务化必须保留 409 内存不足弹窗语义（App onMemoryInsufficient 链路）；
- discover 取消绝不静默缩减 floor（7.9.1 语义不动）。

## 验收

1. make test 全绿；CI 配置入库；
2. JobRegistry 单测全过；dev e2e：discover 202→轮询→done；取消路径 honest；
3. App 试聊外第二处长操作（发现/切换）有进度可取消；
4. QA 落 docs/qa/batch4-jobs-infra.md。
