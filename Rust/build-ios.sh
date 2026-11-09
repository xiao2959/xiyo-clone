#!/usr/bin/env bash
# 编出 iOS 静态库（只在 Mac 上跑）
set -euo pipefail

cd "$(dirname "$0")"

echo "== 1. 检查 Rust =="
command -v cargo >/dev/null || { echo "没装 Rust，先跑: curl https://sh.rustup.rs -sSf | sh"; exit 1; }
rustup target add aarch64-apple-ios 2>/dev/null || true

echo "== 2. 编译 (aarch64-apple-ios, release) =="
cargo build --release --target aarch64-apple-ios

OUT=target/aarch64-apple-ios/release/libidevice_ffi.a
test -f "$OUT" || { echo "编译产物不存在"; exit 1; }
ls -lh "$OUT"

echo
echo "== 3. 导出符号（要和 App/Bridge/include/idevice_ffi.h 完全一致）=="
nm -gU "$OUT" | awk '{print $NF}' | grep -E '^_(pairing_|simulate_location|clear_location)' | sort

echo
echo "== 4. 放到 Xcode 能找到的位置 =="
mkdir -p ../App/Bridge/lib
cp "$OUT" ../App/Bridge/lib/
echo "已复制到 App/Bridge/lib/libidevice_ffi.a"
echo
echo "下一步：Xcode 里 App target -> Build Settings："
echo "  Library Search Paths 加 \$(SRCROOT)/App/Bridge/lib"
echo "  (OTHER_LDFLAGS 已含 -lidevice_ffi)"
