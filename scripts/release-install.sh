#!/bin/bash
# MacFabric 网关发布安装 — 生产只吃发布产物（用户纪律 2026-11-16 固化）。
#
# 用法:
#   scripts/release-install.sh            # 安装最新 gateway-v* tag
#   scripts/release-install.sh gateway-v7.10.5   # 安装/回滚到指定 tag
#
# 动作序列:
#   1. 定位 tag（默认 git 中最新 gateway-v*）
#   2. 取发布源码包: codeload.github.com tar.gz 优先, 失败回退本地 git archive
#      （同一 tag 同一内容; GitHub 不可达时的降级路径, 仍非"源码直通"）
#   3. 原子换目录安装到 ~/Library/MacFabric/prod（旧版留 prod.old 一份作回滚）
#   4. uv 新建生产 .venv（按发布包内 requirements.txt, 不复用开发树依赖）
#   5. 模型配置迁移: ~/.inferfabric/models.d 不存在时从开发树 models.d
#      复制一次（配置不丢失）; 已存在则永不覆盖（后续发布不动用户配置）
#   6. 重写 launchd plist 指向 prod（备份原 plist）, bootout+bootstrap 重启
#   7. 只读活性冒烟: catalog 200 + 端口监听
#
# 回滚: scripts/release-install.sh <上一个 gateway-v* tag>
set -euo pipefail

REPO=/Users/Apple/Projects/MacFabric
PROD="$HOME/Library/MacFabric/prod"
MODELS_D="$HOME/.inferfabric/models.d"
PLIST="$HOME/Library/LaunchAgents/com.macfabric.gateway.plist"
LABEL=com.macfabric.gateway
LOG="$HOME/.inferfabric/logs/gateway.launchd.log"
UID_N=$(id -u)

TAG="${1:-}"
if [ -z "$TAG" ]; then
    TAG=$(git -C "$REPO" tag -l 'gateway-v*' | sort -V | tail -1)
    [ -n "$TAG" ] || { echo "FATAL: 仓库中无 gateway-v* tag"; exit 1; }
fi
echo "== release-install: $TAG =="

WORK=$(mktemp -d /tmp/macfabric-release.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# ── 1. 取发布源码包 ──
TARBALL="$WORK/release.tar.gz"
URL="https://codeload.github.com/vincentlau2046/MacFabric/tar.gz/refs/tags/$TAG"
if curl -fsSL --connect-timeout 15 --max-time 300 -o "$TARBALL" "$URL"; then
    echo "source: GitHub codeload ($TAG)"
else
    echo "source: codeload 失败, 回退本地 git archive ($TAG)"
    git -C "$REPO" archive --format=tar.gz -o "$TARBALL" "$TAG"
fi
mkdir "$WORK/src"
tar -xzf "$TARBALL" -C "$WORK/src"
SRC=$(echo "$WORK/src"/*)   # 归档单层顶层目录（tar.gz/<name>/…）
[ -f "$SRC/requirements.txt" ] || { echo "FATAL: 发布包缺 requirements.txt"; exit 1; }
[ -f "$SRC/macfabric_gateway/inferfabric/proxy/handler.py" ] || {
    echo "FATAL: 发布包缺网关代码"; exit 1; }

# ── 2. 原子换目录 ──
STAMP=$(date +%Y%m%d-%H%M%S)
rm -rf "$PROD.new"
mkdir -p "$PROD.new"
cp -R "$SRC/." "$PROD.new/"
mkdir -p "$PROD.new/.venv"
uv venv "$PROD.new/.venv" --python 3.12 --quiet
uv pip install -r "$PROD.new/requirements.txt" \
    --python "$PROD.new/.venv/bin/python" --quiet
PYTHONPATH="$PROD.new/macfabric_gateway" "$PROD.new/.venv/bin/python" -c \
    "import inferfabric.proxy.handler" \
    || { echo "FATAL: 生产 venv 冒烟 import 失败"; exit 1; }
if [ -d "$PROD" ]; then
    rm -rf "$PROD.old"
    mv "$PROD" "$PROD.old"
fi
mv "$PROD.new" "$PROD"
echo "installed: $PROD (旧版保留于 $PROD.old)"

# ── 3. 模型配置迁移（首次; 后续发布不碰） ──
if [ ! -d "$MODELS_D" ]; then
    mkdir -p "$(dirname "$MODELS_D")"
    cp -R "$REPO/macfabric_gateway/models.d" "$MODELS_D"
    echo "models.d 迁移: $MODELS_D ($(ls "$MODELS_D" | wc -l | tr -d ' ') 个文件)"
else
    echo "models.d 已存在, 保持不动: $MODELS_D"
fi

# ── 4. 重写 launchd plist ──
if [ -f "$PLIST" ]; then
    cp "$PLIST" "$PLIST.bak-$STAMP"
    echo "plist 备份: $PLIST.bak-$STAMP"
fi
mkdir -p "$(dirname "$PLIST")" "$HOME/.inferfabric/logs"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$PROD/.venv/bin/python</string>
        <string>-m</string>
        <string>inferfabric.proxy.handler</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$PROD</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>StandardOutPath</key>
    <string>$LOG</string>
    <key>StandardErrorPath</key>
    <string>$LOG</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PYTHONPATH</key>
        <string>$PROD/macfabric_gateway</string>
        <key>MACFABRIC_MODELS_DIR</key>
        <string>$MODELS_D</string>
        <key>PATH</key>
        <string>/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin</string>
    </dict>
</dict>
</plist>
EOF
echo "plist 重写 → prod"

# ── 5. 重启（按精确 label, 严禁全局 pkill proxy.handler） ──
launchctl bootout "gui/$UID_N/$LABEL" 2>/dev/null || true
sleep 1
launchctl bootstrap "gui/$UID_N" "$PLIST"

# ── 6. 活性冒烟（只读） ──
sleep 3
PID=$(launchctl print "gui/$UID_N/$LABEL" 2>/dev/null | awk '/pid =/{print $3; exit}')
echo "gateway pid: ${PID:-<未拉起>}"
# 批 1 TOP1 born-token：admin 冒烟从 secrets.env 读 token 注 X-Admin-Token
# （网关启动即写回该文件；首轮未就绪由重试循环覆盖）
ADMIN_TOKEN=""
if [ -f "$HOME/.inferfabric/secrets.env" ]; then
    ADMIN_TOKEN=$(awk -F= '$1=="MACFABRIC_ADMIN_TOKEN"{print $2; exit}' "$HOME/.inferfabric/secrets.env" | tr -d '"' || true)
fi
for i in $(seq 1 20); do
    CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 \
        -H "X-Admin-Token: $ADMIN_TOKEN" \
        http://127.0.0.1:8999/admin/packs/catalog || true)
    [ "$CODE" = "200" ] && break
    sleep 1
done
if [ "$CODE" = "200" ]; then
    echo "SMOKE OK: catalog 200, tag=$TAG"
else
    echo "SMOKE FAIL: catalog=$CODE — 查日志: tail -50 $LOG"
    echo "回滚: scripts/release-install.sh <旧tag>（或恢复 $PLIST.bak-$STAMP 后 bootout+bootstrap）"
    exit 1
fi
