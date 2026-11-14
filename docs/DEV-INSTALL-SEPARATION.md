# MacFabric — 安装版/调试版分离（2026-11-14）

> 用户裁决：调试版在沙箱（build 目录）运行测试，可**复制**安装版配置做验证；
> 两者必须彻底分离；成熟 push 后再更新安装版。

## 一、双档位总览

| 隔离面 | 安装版（正式档） | 调试版（开发档） |
|---|---|---|
| App 位置 | `/Applications/MacFabric.app` | `macfabric-app/build/MacFabric-dev.app` |
| Bundle ID | `io.macfabric.app` | `io.macfabric.app.dev` |
| 显示名 | MacFabric | MacFabric Dev |
| 网关端口 | `:8999` | `:8998`（`EDGE_PROXY_PORT`） |
| 状态目录 | `~/.inferfabric` | `~/.inferfabric-dev`（`MACFABRIC_STATE_DIR`） |
| 模型配置 | `macfabric_gateway/models.d`（仓库） | `~/.inferfabric-dev/models.d`（副本，`MACFABRIC_MODELS_DIR`） |
| 配置关系 | 源 | **一次性快照复制**自安装版，之后互不影响 |

## 二、工作流

```bash
# 1. 调试：起调试网关（首次自动从安装版导入配置快照；--fresh 重置）
scripts/dev-gateway.sh            # 前台；nohup 自行包装
bash macfabric-app/build.sh --debug
open macfabric-app/build/MacFabric-dev.app     # 自动连 :8998

# 2. 验证成熟后：push → 晋升安装版
git push ... && git push gitcode ...
scripts/promote-install.sh        # 构建正式版 → 替换 /Applications → 重启
```

## 三、实现机制

- **网关**：`config.py` 新增 `MACFABRIC_STATE_DIR` / `MACFABRIC_MODELS_DIR`
  环境变量覆盖（默认值不变 = 安装版行为零变化）；端口用既有 `EDGE_PROXY_PORT`
- **App**：`build.sh --debug` 写入 `Contents/Resources/DEV_PROFILE` 标记；
  App 启动时检测 → 全局 `GW_PORT/GW_BASE`（21 处调用面统一：API 请求、
  复制配置、文案、菜单栏、向导）
- **隔离保证**：两档 App 可同时运行；调试装机（install_yaml/引擎拆除）
  只碰 `~/.inferfabric-dev` 与副本 models.d，安装版状态零污染
- **模型文件共享说明**：模型 GGUF/ONNX 文件在项目 `models/` 与 `engines/`
  是共享资产（只读使用）；调试版装新模型会下载到同一 `models/` 目录 —
  文件本体无状态冲突，注册隔离靠 models.d 副本实现

## 四、边界与注意

1. 同时跑两个网关时，同一本地模型只在一侧启动（端口/账本各自独立，
   但 Metal/GPU 是物理共享的 — 大模型双开仍会争抢）
2. 调试版配置改满意后，如需回写安装版：手动复制对应 yaml 到
   `~/.inferfabric/`（不做自动回写，防止调试垃圾进安装版）
3. `promote-install.sh` 只替换 App 本体，永不触碰 `~/.inferfabric`
