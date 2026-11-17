#!/bin/bash
# MacFabric — launchd 服务安装/卸载/状态（免 sudo；模板与 release-install.sh §4 真源一致）
# 用法: install-launchd.sh install|uninstall|status
set -euo pipefail
LABEL="com.macfabric.gateway"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
PROD="$HOME/Library/MacFabric/prod"
MODELS_D="$HOME/.inferfabric/models.d"
LOG="$HOME/.inferfabric/logs/gateway.launchd.log"

case "${1:-install}" in
  install)
    # 与 App 设置页 Toggle 相同的前置校验：生产安装缺失则诚实报错（不写半成品 plist）
    if [ ! -x "$PROD/.venv/bin/python" ]; then
      echo "❌ 未找到生产安装（$PROD/.venv/bin/python 不存在）— 请先执行 scripts/release-install.sh" >&2
      exit 1
    fi
    if [ ! -d "$MODELS_D" ]; then
      echo "❌ 未找到模型配置目录（$MODELS_D）— 请先执行 scripts/release-install.sh" >&2
      exit 1
    fi
    mkdir -p "$HOME/Library/LaunchAgents" "$HOME/.inferfabric/logs"
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${PROD}/.venv/bin/python</string>
    <string>-m</string>
    <string>inferfabric.proxy.handler</string>
  </array>
  <key>WorkingDirectory</key><string>${PROD}</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>${LOG}</string>
  <key>StandardErrorPath</key><string>${LOG}</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PYTHONPATH</key><string>${PROD}/macfabric_gateway</string>
    <key>MACFABRIC_MODELS_DIR</key><string>${MODELS_D}</string>
    <key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin</string>
  </dict>
</dict>
</plist>
EOF
    launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    echo "✅ 已安装并启动 ${LABEL}（RunAtLoad + KeepAlive：登录自启、崩溃自愈）"
    echo "   日志: ${LOG}"
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
