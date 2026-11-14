#!/bin/bash
# MacFabric App 构建 — swiftc 直编（无 Xcode，CLT SDK）→ MacFabric.app
set -euo pipefail
cd "$(dirname "$0")"
APP=build/MacFabric.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > build/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>MacFabric</string>
  <key>CFBundleIdentifier</key><string>io.macfabric.app</string>
  <key>CFBundleName</key><string>MacFabric</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
</dict>
</plist>
EOF

swiftc -O \
  -framework SwiftUI -framework AppKit \
  Sources/MacFabricApp.swift -o "$APP/Contents/MacOS/MacFabric"

cp build/Info.plist "$APP/Contents/Info.plist"
# 图标（scripts/make-icon.swift 生成 build/AppIcon.icns；缺失时跳过不阻塞构建）
[ -f build/AppIcon.icns ] && cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
echo "构建完成: ${APP}  (open ${APP} 启动)"
