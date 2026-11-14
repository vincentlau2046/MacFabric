#!/bin/bash
# MacFabric 成熟版晋升 — push 后更新本地安装板（用户裁决流程：
# 调试版验证成熟 → push → 本脚本晋升安装版）
#
# 动作：构建正式版（无调试标记）→ 替换 /Applications/MacFabric.app → 重启
# 注意：安装版网关用默认状态目录 ~/.inferfabric，配置不受晋升影响。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "── 构建正式版 ──"
bash "$ROOT/macfabric-app/build.sh"

echo "── 停止运行中的安装版 ──"
osascript -e 'tell application "MacFabric" to quit' 2>/dev/null || true
sleep 1
pkill -f "/Applications/MacFabric.app/Contents/MacOS/MacFabric" 2>/dev/null || true
sleep 1

echo "── 安装到 /Applications ──"
rm -rf /Applications/MacFabric.app
cp -R "$ROOT/macfabric-app/build/MacFabric.app" /Applications/MacFabric.app

echo "── 启动安装版 ──"
open /Applications/MacFabric.app
echo "完成: /Applications/MacFabric.app 已更新并启动"
