# 生产网关守护 — 设置页"开机时启动网关"使能（方案 B，用户裁决 2026-11-17）

> 用户裁决：生产环境重点保证 proxy 正常运行；设置中的网关随机启动守护进程需要可在 App 内使能。
> 现状核实（2026-11-17）：`com.macfabric.gateway` 已 RunAtLoad+KeepAlive 自启+自愈（pid 10978，:8999=200）；
> **生产守护已实质使能**，本方案补齐 App 内可见可控入口。plist 真源 = `scripts/release-install.sh` §4
> （与现网逐键一致）；`scripts/install-launchd.sh` 为遗留分叉，本版对齐。

## 设计

1. **纯逻辑 `GatewayDaemon`**（ProductModels.swift，进契约测试）：
   - `plistXML(prodDir:modelsDir:logPath:label:)` — 生成与 release-install.sh 模板逐键一致的 plist
   - `state(plistExists:launchctlPrint:)` → `notInstalled / stopped / running(pid)`；
     Toggle 使能语义 = **plist 存在**（登录自启注册即"已使能"，进程瞬时波动不影响开关呈现）
   - `bootstrapArgs / bootoutArgs`（uid、label 可注入，便于测试与沙箱 QA）
2. **App 接线**（main.swift）：Settings 页该行从禁用改为交互 Toggle；
   - 开：校验 prod venv 存在 → 写 plist → `launchctl bootstrap gui/<uid>`（已加载则跳过）
   - 关：确认对话框（停生产网关影响推理）→ `bootout` → 删 plist
   - 状态：Settings onAppear 刷新（plist 存在性 + `launchctl print` 的 state/pid），Busy 禁点
   - QA 注入：label/program 支持 env 覆盖（仅沙箱 e2e 用；生产默认值不变）
3. **脚本对齐**：`install-launchd.sh` plist 模板改为与 release-install.sh 真源一致（prod venv 直启），
   保留 install/uninstall/status 用法。

## 语义红线

- 严禁全局 pkill proxy.handler（记忆：两档命令行相同）；只按精确 label bootout/bootstrap
- 关闭 = 停生产推理网关，必须走确认对话框；enable 前校验 prod 安装存在，缺失则诚实报错
- 默认 label/program/路径与现网逐键一致；env 覆盖仅 QA，生产进程不带该环境变量

## 验收（TDD，契约测试组 23）

- plistXML 含 label/prod python/`-m inferfabric.proxy.handler`/RunAtLoad/KeepAlive/WorkingDirectory/
  PYTHONPATH/MACFABRIC_MODELS_DIR/日志路径
- state 三态判定（nil+无plist→notInstalled；有plist无pid→stopped；print 含 pid→running）
- bootstrap/bootout 命令组装正确
- 沙箱 e2e：test-label + /bin/sleep 程序走完 写plist→bootstrap→print(running)→bootout→删plist，
  生产 8999 前后 200 不受影响
- 调试/正式档构建 exit=0

## 范围外

- "仅本机监听"等其余 v1.5 设置项
- 开机自启（RunAtLoad 为登录自启；boot 级守护需 sudo，明确不做）
