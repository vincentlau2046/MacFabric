#!/bin/bash
# MacFabric App 构建 — swiftc 直编（无 Xcode，CLT SDK）
#   build.sh            → 正式版 build/MacFabric.app（晋升 /Applications 用）
#   build.sh --debug    → 调试版 build/MacFabric-dev.app（bundle id/名称/网关端口 8998 独立）
set -euo pipefail
cd "$(dirname "$0")"
DEBUG=0
[ "${1:-}" = "--debug" ] && DEBUG=1
if [ "$DEBUG" = "1" ]; then
  APP=build/MacFabric-dev.app
  BUNDLE_ID=io.macfabric.app.dev
  BUNDLE_NAME="MacFabric Dev"
else
  APP=build/MacFabric.app
  BUNDLE_ID=io.macfabric.app
  BUNDLE_NAME="MacFabric"
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > build/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>MacFabric</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleName</key><string>${BUNDLE_NAME}</string>
  <key>CFBundleDisplayName</key><string>${BUNDLE_NAME}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
</dict>
</plist>
EOF
# 调试标记：App 启动时检测 → 网关指向 :8998（调试网关，状态 ~/.inferfabric-dev）
rm -f "$APP/Contents/Resources/DEV_PROFILE"
[ "$DEBUG" = "1" ] && printf 'dev' > "$APP/Contents/Resources/DEV_PROFILE"

SOURCES="Sources/ProductModels.swift Sources/AuthState.swift Sources/GatewayKeychain.swift Sources/DesignSystem.swift Sources/ModelTable.swift Sources/ModelDetails.swift Sources/main.swift"
swiftc -O \
  -framework SwiftUI -framework AppKit -framework Security \
  $SOURCES -o "$APP/Contents/MacOS/MacFabric"

cp build/Info.plist "$APP/Contents/Info.plist"
# 防止构建产物被 Spotlight 索引 → 启动台出现第二个“正式版”（用户裁决 2026-11-16：
# 正式版全机仅 /Applications 一份，更新走 promote-install.sh 覆盖）
touch build/.metadata_never_index
# 图标（scripts/make-icon.swift 生成 build/AppIcon.icns；缺失时跳过不阻塞构建）
[ -f build/AppIcon.icns ] && cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
if [ "$DEBUG" = "1" ]; then
  echo "构建完成(调试版): ${APP} — 先跑 scripts/dev-gateway.sh 再 open ${APP}"
else
  echo "构建完成: ${APP}  (open ${APP} 启动；成熟后 scripts/promote-install.sh 晋升)"
fi
