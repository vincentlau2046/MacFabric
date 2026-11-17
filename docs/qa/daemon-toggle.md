# 网关守护设置页 Toggle — QA 证据（2026-11-17）

> 范围：spec docs/superpowers/specs/2026-11-17-gateway-daemon-toggle.md（方案 B，用户裁决）。
> 声明：本记录只证明列出的检查；生产守护进程本身未做任何 bootout/bootstrap。

## 验收结果

| 检查 | 命令/方式 | 结果 |
|---|---|---|
| 契约测试（23 组，含守护新增 8 断言） | `bash scripts/test-app-contracts.sh` | CONTRACT_TESTS_OK，exit=0 |
| 调试档构建（:8998） | `bash macfabric-app/build.sh --debug` | exit=0 |
| 正式档构建 | `bash macfabric-app/build.sh` | exit=0 |
| install-launchd.sh 语法 | `bash -n scripts/install-launchd.sh` | 通过 |
| 脚本模板对齐真源 | 与 release-install.sh §4 逐键比对 | Label/ProgramArguments( prod venv 直启)/WorkingDirectory/RunAtLoad/KeepAlive/ThrottleInterval/日志/PYTHONPATH/MACFABRIC_MODELS_DIR/PATH 一致；install 增加与 App 相同的生产前置校验 |
| 沙箱 e2e 全链路 | 测试 label com.macfabric.gateway.qa-e2e + /bin/sleep 程序 | 写 plist → bootstrap → print state=running (pid 96955) → bootout → plist 已删、无残留；生产 :8999 前后均 200 |
| 生产守护 | 未触碰 | ${'com.macfabric.gateway'} 未做任何操作，运行状态不受影响 |

## 实施内容

- `ProductModels.GatewayDaemon`：三态判定（notInstalled/stopped/running(pid)，使能语义 = plist 存在）、
  plist 模板（与 release-install.sh §4 真源逐键一致；programArgs 仅沙箱 e2e 注入）、
  bootstrap/bootout/print 命令组装（uid 可注入）。
- AppStore：refreshDaemonState（plist 存在性 + launchctl print）/enableDaemon（校验 prod venv 与
  models.d → 写 plist → 已加载跳过 bootstrap）/disableDaemon（bootout 精确 label → 删 plist）。
  QA 注入走 MACFABRIC_DAEMON_LABEL / MACFABRIC_DAEMON_PROGRAM_ARGS（\u{1f} 分隔）等 env，生产进程不带。
- 设置页：Toggle 接线（三态诚实文案含 pid），关闭走确认对话框（停生产网关警示），Busy 禁点，
  Settings onAppear 刷新。
- 红线保持：只按精确 label bootout/bootstrap；未做全局 pkill；env 覆盖仅 QA。
