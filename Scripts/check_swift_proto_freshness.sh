#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PACKAGE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GENERATED_DIR="$PACKAGE_ROOT/Sources/DGWProto/Generated"
SNAPSHOT_DIR="$(mktemp -d /tmp/swift-proto-generated.XXXXXX)"
trap 'rm -rf "$SNAPSHOT_DIR"' EXIT

cp -R "$GENERATED_DIR" "$SNAPSHOT_DIR/Generated"

"$SCRIPT_DIR/gen_swift_proto.sh"

if ! diff -ru "$SNAPSHOT_DIR/Generated" "$GENERATED_DIR"; then
  echo "Swift proto generated sources are stale. Run Scripts/gen_swift_proto.sh and commit the updated files." >&2
  exit 1
fi

echo "Swift proto generated sources are fresh."
