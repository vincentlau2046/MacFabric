#!/bin/bash
# App 侧契约测试（CLT swiftc 直编，无 XCTest 依赖）
# 用法：bash scripts/test-app-contracts.sh
# 产物与临时文件只写 $CLAUDE_JOB_DIR/tmp（未设置时退 build/.contracts）
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${CLAUDE_JOB_DIR:-$PWD/build}/tmp/app-contracts"
mkdir -p "$OUT"
# 参与契约测试的纯逻辑源（不依赖 SwiftUI）；新增共享逻辑文件须在此登记
SOURCES="macfabric-app/Sources/ProductModels.swift macfabric-app/Sources/AuthState.swift macfabric-app/Sources/GatewayClient.swift macfabric-app/Sources/AdminTokenFileStore.swift"
TEST="macfabric-app/Tests/main.swift"
swiftc -module-cache-path "$OUT/module-cache" $SOURCES "$TEST" -o "$OUT/contract-tests"
"$OUT/contract-tests"
