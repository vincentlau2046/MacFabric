#!/bin/bash
# MacFabric 安装版网关守护 — launchd LaunchAgent（用户裁决：网关不能一杀就永久离线）
#
# 根因：安装版网关此前靠手工 nohup 拉起，进程被杀/崩溃后无人恢复；
# App 只显示"网关未响应"不负责拉起。macOS 标准解法 = LaunchAgent
# KeepAlive=true：进程退出 10s 内自动拉起，开机自启，崩溃循环由
# ThrottleInterval 自然限速。
#
# 用法：
#   scripts/gateway-launchd.sh install    # 安装并立即启动守护
#   scripts/gateway-launchd.sh uninstall  # 停止并移除守护（网关随之停止）
#   scripts/gateway-launchd.sh status     # 查看守护与网关状态
#
# 范围：只管安装版 :8999（默认状态目录 ~/.inferfabric）。
# 调试版 :8998 仍由 scripts/dev-gateway.sh 手工管理 — 双档隔离不被守护越界。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="com.macfabric.gateway"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/.inferfabric/logs"
PY="$ROOT/.venv/bin/python"

if [ ! -x "$PY" ]; then
  echo "错误: 找不到解释器 $PY（安装版网关依赖仓库 .venv）" >&2
  exit 1
fi

case "${1:-}" in
install)
  mkdir -p "$LOG_DIR"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$PY</string>
        <string>-m</string>
        <string>inferfabric.proxy.handler</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$ROOT</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/gateway.launchd.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/gateway.launchd.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PYTHONPATH</key>
        <string>$ROOT/macfabric_gateway</string>
        <key>PATH</key>
        <string>/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin</string>
    </dict>
</dict>
</plist>
EOF
  # 换防误杀语义：本守护接管安装版网关，先卸掉可能的旧实例
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  pkill -f "$PY -m inferfabric.proxy.handler" 2>/dev/null || true
  sleep 1
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  echo "已安装守护: ${LABEL}（KeepAlive=true，日志 $LOG_DIR/gateway.launchd.log）"
  echo "注意: 调试/安装网关命令行相同 — 以后重启调试网关请勿 pkill 全局匹配，"
  echo "      用 'launchctl kickstart -k gui/$(id -u)/$LABEL' 重启安装版。"
  ;;
uninstall)
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  echo "已移除守护: $LABEL"
  ;;
status)
  echo "── launchd ──"
  launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | grep -E "state|pid|last exit" || echo "未安装"
  echo "── 网关 ──"
  curl -s -o /dev/null -w ":8999 -> %{http_code}\n" --max-time 3 http://127.0.0.1:8999/ || echo ":8999 无响应"
  ;;
*)
  echo "用法: $0 {install|uninstall|status}" >&2
  exit 1
  ;;
esac
