#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PACKAGE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PACKAGE_ROOT/.." && pwd)"
TOOL_BIN="$REPO_ROOT/.local/toolchains/swift-proto/bin"

mkdir -p "$REPO_ROOT/.local/src" "$TOOL_BIN"

swift build -c release --product protoc-gen-swift --package-path "$PACKAGE_ROOT/.build/checkouts/swift-protobuf"
swift build -c release --product protoc-gen-grpc-swift-2 --package-path "$PACKAGE_ROOT/.build/checkouts/grpc-swift-protobuf"

SWIFT_BIN="$(swift build -c release --show-bin-path --package-path "$PACKAGE_ROOT/.build/checkouts/swift-protobuf")/protoc-gen-swift"
GRPC_BIN="$(swift build -c release --show-bin-path --package-path "$PACKAGE_ROOT/.build/checkouts/grpc-swift-protobuf")/protoc-gen-grpc-swift-2"

cp "$SWIFT_BIN" "$TOOL_BIN/protoc-gen-swift"
cp "$GRPC_BIN" "$TOOL_BIN/protoc-gen-grpc-swift-2"

echo "Swift proto toolchain installed into $TOOL_BIN"
