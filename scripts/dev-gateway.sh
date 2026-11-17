#!/bin/bash
# MacFabric 调试网关 — 与安装版完全隔离（用户裁决：安装/调试分离）
#
#   隔离面        安装版（默认）            调试版（本脚本）
#   状态目录      ~/.inferfabric            ~/.inferfabric-dev
#   模型配置      macfabric_gateway/models.d  ~/.inferfabric-dev/models.d（副本）
#   端口          :8999                     :8998 (EDGE_PROXY_PORT)
#   App          /Applications/MacFabric.app  macfabric-app/build/MacFabric-dev.app
#
# 批 1 TOP1：控制面鉴权 token 由网关启动时 born（~/.inferfabric-dev/secrets.env
# 的 MACFABRIC_ADMIN_TOKEN）；curl 调试 admin 接口时先从该文件读出 token，
# 再以 -H "X-Admin-Token: <token>" 携带（无值时网关会拒绝 admin 路由）。
#
# 配置导入：首次运行把安装版配置**复制**一份到调试目录（一次性快照，之后
# 两边各改各的互不影响）。用 --fresh 丢弃调试状态重新从安装版导入。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEV_STATE="$HOME/.inferfabric-dev"

if [ "${1:-}" = "--fresh" ]; then
  rm -rf "$DEV_STATE"
  echo "调试状态已清空，将从安装版重新导入"
fi

# 一次性配置快照（只在目标缺文件时复制 — 不覆盖调试侧已有修改）
mkdir -p "$DEV_STATE/models.d"
for f in model_pools.yaml cloud_provider.yaml iff.yaml active_scenarios.yaml; do
  if [ -f "$HOME/.inferfabric/$f" ] && [ ! -f "$DEV_STATE/$f" ]; then
    cp "$HOME/.inferfabric/$f" "$DEV_STATE/$f"
    echo "导入: $f"
  fi
done
# 模型配置用仓库 models.d 的副本（调试装机不写回仓库）
if [ -z "$(ls -A "$DEV_STATE/models.d" 2>/dev/null)" ]; then
  cp "$ROOT/macfabric_gateway/models.d/"*.yaml "$DEV_STATE/models.d/" 2>/dev/null || true
  echo "导入: models.d ($(ls "$DEV_STATE/models.d" | wc -l | tr -d ' ') 个)"
fi

export MACFABRIC_STATE_DIR="$DEV_STATE"
export MACFABRIC_MODELS_DIR="$DEV_STATE/models.d"
export EDGE_PROXY_PORT="${EDGE_PROXY_PORT:-8998}"
export PYTHONPATH="$ROOT/macfabric_gateway"

echo "调试网关启动: 状态=$MACFABRIC_STATE_DIR 端口=$EDGE_PROXY_PORT"
cd "$ROOT"
exec "$ROOT/.venv/bin/python" -m inferfabric.proxy.handler
