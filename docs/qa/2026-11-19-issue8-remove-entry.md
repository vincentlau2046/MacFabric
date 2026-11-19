# QA — dashboard iff remove 入口（上游 issue #8 item 1）

日期：2026-11-19 · 分支：feat/uninstall-parity · commit 52263c2（handler+UI）
依赖移植：b8dd4b8（uninstaller/image_manager 逐字，peer）

## 范围

- `POST /admin/models/remove {name, confirmed?, purge_pools?}` 薄封装
  （`_handle_models_remove`，接线镜像 cli cmd_remove；find_model 预解析）。
- deploy 页模型表「移除」入口 + `depRemoveModal` 三段式确认
  （预览 → blocked 给 purge 选项+强制「重新预览」→ confirmed 执行）。
- 四点对齐文案：running 三值（运行中/未运行/状态未知）、
  weights_kept「工具永不删权重」、scenario_refs「移除后遗留的场景侧车条目
  （加载时被忽略）」。

## 证据

### 单元（TDD RED→GREEN 全程）

- `tests/unit/test_admin_models_remove.py` — 12：路由注册、缺 name 400、
  预览恒 200（unknown/error 由 body 区分）、执行映射 removed→200+reload /
  blocked→409 无副作用 / unknown→404 / PoolsConfigError→400（monkeypatch
  抛出）/ stop 失败→500 带报告 / served-name 解析到 config 名 /
  purge_pools 透传 / 池门不可用预览 200。
- `tests/unit/test_dashboard_model_remove.py` — 8：组装（model-remove 入口
  内联进页面）、端点+401 守卫、三段式（purge/重新预览/depRemoveModal）、
  running 三值文案、权重/场景文案、错误态走状态重渲染（st.error）、
  无 inline onclick。
- 全量：573 passed（基线 572 + 1 净增；含 peer 移植侧 83）。

### 浏览器验收（隔离沙箱，全程文本断言，33/33）

沙箱：MACFABRIC_STATE_DIR/MACFABRIC_MODELS_DIR 重定向 + EDGE_PROXY_PORT=8998；
种子 qa-remove-a（vllm，权重 /Users/Apple/models/Qwen3）+
qa-remove-b（llama_cpp，被 qa-pool 候选引用）。脚本
`m1-browser-remove.js`（job tmp），预览/执行走真实后端；409/500/401/
预览失败四路径用 route 注入保证确定性。

- A 预览（未运行）：标题/「未运行」/权重块（工具永不删权重 +
  具体路径）/确认键可用；无场景引用时不显示场景块。
- B 执行（真实）：toast 已移除（权重保留）、快照消失、YAML 删除、
  权重文件仍在盘。
- C blocked 三段式（真实 409 后端 fail-closed，见「上游缺口」）：
  引用池候选展示 → 确认禁用 → 勾 purge 解锁「重新预览」（确认仍禁用）→
  二次预览文案出现 → 确认 → 内联「移除失败」、弹窗不关、YAML/池文件不动。
- D 409 竞态（注入）：toast「已回到预览」、blocked 视图重渲染、确认禁用、
  YAML 不动。
- E 500（注入）：内联报错含原因、弹窗不关、YAML 不动。
- F 预览网络失败（注入）：toast 报错、无弹窗。
- G 401（注入）：专用提示、无弹窗、无通用覆盖。

## 上游缺口（发现于验收，fork 保持逐字，待上游化 triage）

1. `purge_pool_candidates` 发 `PUT /admin/model-pools`，但同步 server 仅路由
   GET/POST（handler 注释：「更新用 POST（同步 server 仅路由 GET/POST；body
   携带 expected_revision）」）→ 活 registry 下 purge 501 → handler 500
   fail-closed（验收 C9-C12 钉住此行为）。上游 HEAD 2fe7128 同样存在。
2. `weight_paths` 不覆盖 llama_cpp `model_path`（fork 包引擎）→ 包模型
   预览不显示权重条目。
3. models.d 新增 YAML 不自动加载（需 /reload-config）——验收脚本已适配，
   行为本属 config_reloader 语义，仅记录。

## Rulings

- uninstaller/image_manager 保持上游逐字（envs_root 跟随 issue #3 安全裁决；
  ledger 路径经 config.IFF_DATA_DIR 已保证沙箱隔离）——与 peer 对齐。
- 池 CAS 写端点缺失不私改逐字文件：UI fail-closed 可见即可，
  PUT→POST 修正随上游化推进。
- handler 404 判定用 find_model 预解析，不依赖 message 措辞
  （peer 交叉评审 nit，已采纳并加 served-name 测试）。
