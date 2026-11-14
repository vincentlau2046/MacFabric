#!/bin/bash
# MacFabric 网关启动包装 — launchd / 手动共用的唯一入口
# 环境要求: uv 管理的 .venv（.venv/bin/python），macfabric_gateway/ 分叉包
set -euo pipefail
MACFABRIC_HOME="$(cd "$(dirname "$0")/.." && pwd)"
export PYTHONPATH="$MACFABRIC_HOME/macfabric_gateway"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
exec "$MACFABRIC_HOME/.venv/bin/python" -m inferfabric.proxy.handler
