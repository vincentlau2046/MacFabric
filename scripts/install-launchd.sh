#!/bin/bash
# MacFabric P1 — launchd 服务安装/卸载/状态（免 sudo，重启自愈验收）
# 用法: install-launchd.sh install|uninstall|status
set -euo pipefail
LABEL="com.macfabric.gateway"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
HOME_DIR="$(cd "$(dirname "$0")/.." && pwd)"

case "${1:-install}" in
  install)
    mkdir -p "$HOME/Library/LaunchAgents" "$HOME/.inferfabric"
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${HOME_DIR}/scripts/macfabric-gateway.sh</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>${HOME}/.inferfabric/gateway.log</string>
  <key>StandardErrorPath</key><string>${HOME}/.inferfabric/gateway.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>EDGE_AUTO_SWITCH</key><string>1</string>
  </dict>
</dict>
</plist>
EOF
    launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    echo "✅ 已安装并启动 ${LABEL}（RunAtLoad + KeepAlive：开机自启、崩溃自愈）"
    echo "   日志: ~/.inferfabric/gateway.log"
    ;;
  uninstall)
    launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
    rm -f "$PLIST"
    echo "✅ 已卸载 ${LABEL}"
    ;;
  status)
    launchctl print "gui/$(id -u)/${LABEL}" 2>/dev/null | grep -E "state|pid" | head -4 \
      || echo "未安装或未运行"
    ;;
  *)
    echo "用法: $0 install|uninstall|status"; exit 2;;
esac
