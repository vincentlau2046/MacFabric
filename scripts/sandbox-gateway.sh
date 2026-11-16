#!/bin/bash
# MacFabric 沙箱网关 — 开发/验证专用，与生产隔离（用户纪律 2026-11-16）。
#
#   用法: scripts/sandbox-gateway.sh [--reset]
#   端口: 8998（生产 8999 不受影响，launchd com.macfabric.gateway 不动）
#
# 隔离设计：
#   - MACFABRIC_STATE_DIR=~/.inferfabric-sandbox — security.db / state.db /
#     request_log.db / logs 全部沙箱自有，与生产零共享
#   - packs / model_pools.yaml / cloud_provider.yaml 软链生产真实件
#     （真实包、真实池拓扑、真实云 key）——沙箱只做【只读功能验证】，
#     严禁在沙箱里执行卸载/写池等会穿透软链的破坏性操作
#   - 沙箱自有 security.db（policy=all）+ 冒烟 key，明文存沙箱目录 600 权限
#
# 停止: kill $(cat ~/.inferfabric-sandbox/gateway.pid)
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SB="$HOME/.inferfabric-sandbox"
PROD="$HOME/.inferfabric"
PORT=8998

mkdir -p "$SB"
for item in packs model_pools.yaml cloud_provider.yaml; do
  [ -e "$SB/$item" ] || ln -s "$PROD/$item" "$SB/$item"
done

if [ ! -f "$SB/security.db" ]; then
  cd "$REPO"
  PYTHONPATH=macfabric_gateway .venv/bin/python - "$SB" <<'PYEOF'
import sys
from pathlib import Path
from inferfabric.security.key_store import KeyStore
sb = Path(sys.argv[1])
ks = KeyStore(sb / "security.db", provision=True)
ks.set_policy("all")
_, token = ks.create_key("sandbox-smoke", None, None)
(sb / "smoke_key.txt").write_text(token)
(sb / "smoke_key.txt").chmod(0o600)
print("sandbox security store initialized; key → ~/.inferfabric-sandbox/smoke_key.txt")
PYEOF
fi

if [ "${1:-}" = "--reset" ]; then
  echo "--reset 会删除沙箱隔离件（软链保留）——如需重建请先删 $SB/security.db"
  exit 1
fi

cd "$REPO"
KEY=$(cat "$SB/smoke_key.txt")
MACFABRIC_STATE_DIR="$SB" EDGE_PROXY_PORT=$PORT \
  PYTHONPATH=macfabric_gateway \
  .venv/bin/python -m inferfabric.proxy.handler \
  > "$SB/gateway.log" 2>&1 &
echo $! > "$SB/gateway.pid"
echo "sandbox gateway pid=$(cat "$SB/gateway.pid") port=$PORT log=$SB/gateway.log"
echo "smoke: curl -s -H 'Authorization: Bearer <smoke_key.txt 内容>' http://127.0.0.1:$PORT/v1/chat/completions ..."
