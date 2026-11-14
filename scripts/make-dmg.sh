#!/bin/bash
# MacFabric dmg 打包 — build/MacFabric.app → dist/MacFabric.dmg
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p dist
rm -f dist/MacFabric.dmg
hdiutil create -volname MacFabric -srcfolder macfabric-app/build/MacFabric.app \
  -ov -format UDZO dist/MacFabric.dmg
echo "打包完成: dist/MacFabric.dmg"
ls -lh dist/MacFabric.dmg
