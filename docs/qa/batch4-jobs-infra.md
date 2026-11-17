# 批 4 QA — TOP3b 任务化 + 次级 1 测试基建（2026-11-17）

## 范围

- 次级 1（commit 9e43f5a）：Makefile 一键全链、外网防回归 guard、GitHub Actions CI；
- TOP3b（本批）：云端发现 / GPU 切换任务化 — 202 + 轮询 + 协作式取消 + 进度呈现。

## 网关侧

- [jobs.py](/Users/Apple/Documents/MacFabric/macfabric_gateway/inferfabric/jobs.py)：
  JobRegistry 状态机（queued/running/done/failed/cancelled），竞态保护
  「完成态优先于取消标记」，完结记录裁剪上限 50；14 个单测钉住。
- [handler.py](/Users/Apple/Documents/MacFabric/macfabric_gateway/inferfabric/proxy/handler.py)：
  GET /admin/jobs/{id}、POST /admin/jobs/{id}/cancel（动态段均过 _admin 门禁 —
  P0 缺口修复有回归单测）；/admin/cloud/discover 与 /switch 默认 202 + job_id，
  body sync=true 保留旧同步语义（CLI/scripts 兼容）；/switch 的 409 switching
  gate 保留同步立即返回。
- [cloud_discovery.py](/Users/Apple/Documents/MacFabric/macfabric_gateway/inferfabric/cloud_discovery.py)：
  discover_all(should_cancel=) 每 provider 协作式取消检查点；取消 → 早退且
  不发布（注册表保持取消前状态，floor 7.9.1 语义不动）；既有轮询调用方
  不传参，行为零变化。

## App 侧

- [GatewayClient.swift](/Users/Apple/Documents/MacFabric/macfabric-app/Sources/GatewayClient.swift)：
  JobCompletion.evaluate 纯函数（keepPolling/succeeded/failed/cancelled/timedOut），
  契约测试 8 断言（现共 110 PASS）。
- [main.swift](/Users/Apple/Documents/MacFabric/macfabric-app/Sources/main.swift)：
  cloudDiscover/switchModel 改发起 job + Task 轮询（700ms 间隔）+ 横幅进度 +
  取消按钮；409 memory_insufficient 同步分支原样弹窗（onMemoryInsufficient
  链路保持）；job.result 的 memory_insufficient 也接弹窗；取消文案诚实
  （检查点粒度 = 每 provider / switch 不可中断仅停止等待）。

## 验证

- make test 全链 ALL_GREEN（契约 110 + pytest 305 + 双档构建）；
- dev e2e（:8998）：
  - 动态段无 token → 401 ×3（discover/jobs/{id}/cancel 全部过门禁）；
  - discover POST {} → 202 {job_id} → 轮询 done {cloud_models: 5}；
  - /switch sync=true → 200 already_active（CLI 合同不变）；
  - /switch 默认 → 202 → done already_active；
  - cancel 已完结 job → 受理；取消后 provider 注册表未被缩减（floor 不动）；
  - 取消竞态（完成态优先）由单测覆盖。

## 语义红线核验

- 生产 :8999 零接触（验证全部走 dev :8998）；
- memory_insufficient 弹窗链路两条路径都保持（同步 409 + job.result）；
- discover 取消不缩减 floor（e2e + 单测）。

## 遗留

- TOP4 第二步 dark 走查：TCC 屏幕录制权限阻塞中，待权限路径裁决；
  批 2 已完成 token 自适应地基，走查个例修正在解除后进行。
