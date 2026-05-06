#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SDK_DIR="${ROOT_DIR}/swift"
MARKER_BEGIN="# archebase-swift-sdk-public-dns begin"
MARKER_END="# archebase-swift-sdk-public-dns end"
LOCAL_IP="${DGW_PUBLIC_DNS_LOCAL_IP:-127.0.0.1}"
DOMAIN_PREFIX=""
if [[ "${DGW_PUBLIC_DNS_DEV:-}" == "1" ]]; then
  DOMAIN_PREFIX="dev-"
fi
AUTH_DOMAIN="${DOMAIN_PREFIX}auth.platform.archebase.ai"
GATEWAY_DOMAIN="${DOMAIN_PREFIX}gateway.platform.archebase.ai"
INIT_DOMAIN="${DOMAIN_PREFIX}init-device.platform.archebase.ai"
AUTH_TARGET="${DGW_LOCAL_AUTH_ENDPOINT:-127.0.0.1:15055}"
GATEWAY_TARGET="${DGW_LOCAL_GATEWAY_ENDPOINT:-127.0.0.1:15053}"
INIT_TARGET="${DGW_LOCAL_INIT_ENDPOINT:-127.0.0.1:15057}"
AUTH_TLS_PORT="${DGW_PUBLIC_AUTH_TLS_PORT:-443}"
GATEWAY_TLS_PORT="${DGW_PUBLIC_GATEWAY_TLS_PORT:-8443}"
INIT_TLS_PORT="${DGW_PUBLIC_INIT_TLS_PORT:-9443}"
CERT_DIR="${DGW_PUBLIC_DNS_CERT_DIR:-${SDK_DIR}/.public-dns}"
CERT_FILE="${CERT_DIR}/archebase-public-domains.crt"
KEY_FILE="${CERT_DIR}/archebase-public-domains.key"
PID_DIR="${CERT_DIR}/pids"

usage() {
  cat <<'USAGE'
Usage: swift/Scripts/public_dns_path_test.sh <command>

Commands:
  prepare-hosts   Add marked /etc/hosts entries for Archebase public SDK domains.
  start-proxies   Start local TLS TCP proxies for auth, gateway, and device init gRPC targets.
  run-tests       Run gated Swift tests through the fixed public endpoint SDK path.
  cleanup         Stop proxies and remove marked /etc/hosts entries.

Environment:
  DGW_PUBLIC_DNS_RUN=1 is required for prepare-hosts, start-proxies, and run-tests.
  DGW_PUBLIC_DNS_DEV=1 prepares dev-prefixed domains and runs Swift tests with -DDEV.
  DGW_LOCAL_AUTH_ENDPOINT, DGW_LOCAL_GATEWAY_ENDPOINT, and DGW_LOCAL_INIT_ENDPOINT point to local plaintext gRPC targets.
  DGW_LOCAL_CREDENTIAL_BASE64, DGW_LOCAL_DEVICE_ID, and DGW_LOCAL_PERSIST_ROOT are passed through to integration tests.

Notes:
  This script is intentionally gated and does not affect normal swift test runs.
  prepare-hosts may require sudo because it edits /etc/hosts.
  start-proxies requires openssl and socat.
USAGE
}

require_gated() {
  if [[ "${DGW_PUBLIC_DNS_RUN:-}" != "1" ]]; then
    echo "DGW_PUBLIC_DNS_RUN=1 is required for this command" >&2
    exit 2
  fi
}

normalize_target() {
  local value="$1"
  value="${value#http://}"
  value="${value#https://}"
  printf '%s\n' "$value"
}

ensure_cert() {
  mkdir -p "$CERT_DIR" "$PID_DIR"
  if [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]]; then
    return
  fi
  openssl req -x509 -newkey rsa:2048 -nodes -days 7 \
    -keyout "$KEY_FILE" \
    -out "$CERT_FILE" \
    -subj "/CN=${AUTH_DOMAIN}" \
    -addext "subjectAltName=DNS:${AUTH_DOMAIN},DNS:${GATEWAY_DOMAIN},DNS:${INIT_DOMAIN}"
}

prepare_hosts() {
  require_gated
  local block
  block="${MARKER_BEGIN}
${LOCAL_IP} ${AUTH_DOMAIN}
${LOCAL_IP} ${GATEWAY_DOMAIN}
${LOCAL_IP} ${INIT_DOMAIN}
${MARKER_END}"
  local current
  current="$(mktemp)"
  cp /etc/hosts "$current"
  python3 - "$current" "$block" <<'PY'
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
block = sys.argv[2]
text = path.read_text()
begin = "# archebase-swift-sdk-public-dns begin"
end = "# archebase-swift-sdk-public-dns end"
while begin in text and end in text:
    start = text.index(begin)
    stop = text.index(end, start) + len(end)
    text = text[:start] + text[stop:]
text = text.rstrip() + "\n" + block + "\n"
path.write_text(text)
PY
  sudo cp "$current" /etc/hosts
  rm -f "$current"
  dscacheutil -flushcache >/dev/null 2>&1 || true
  echo "Installed marked hosts entries for Archebase public SDK domains."
}

cleanup_hosts() {
  local current
  current="$(mktemp)"
  cp /etc/hosts "$current"
  python3 - "$current" <<'PY'
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
begin = "# archebase-swift-sdk-public-dns begin"
end = "# archebase-swift-sdk-public-dns end"
while begin in text and end in text:
    start = text.index(begin)
    stop = text.index(end, start) + len(end)
    text = text[:start] + text[stop:]
path.write_text(text.strip() + "\n")
PY
  sudo cp "$current" /etc/hosts
  rm -f "$current"
  dscacheutil -flushcache >/dev/null 2>&1 || true
}

start_proxy() {
  local name="$1"
  local listen_port="$2"
  local target="$3"
  local pid_file="${PID_DIR}/${name}.pid"
  if [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" >/dev/null 2>&1; then
    echo "${name} proxy already running on ${listen_port}"
    return
  fi
  socat "OPENSSL-LISTEN:${listen_port},cert=${CERT_FILE},key=${KEY_FILE},reuseaddr,fork" "TCP:$(normalize_target "$target")" &
  echo "$!" > "$pid_file"
  echo "Started ${name} TLS proxy on ${listen_port} -> $(normalize_target "$target")"
}

start_proxies() {
  require_gated
  command -v openssl >/dev/null || { echo "openssl is required" >&2; exit 2; }
  command -v socat >/dev/null || { echo "socat is required" >&2; exit 2; }
  ensure_cert
  start_proxy auth "$AUTH_TLS_PORT" "$AUTH_TARGET"
  start_proxy gateway "$GATEWAY_TLS_PORT" "$GATEWAY_TARGET"
  start_proxy init "$INIT_TLS_PORT" "$INIT_TARGET"
  echo "Trust ${CERT_FILE} locally before running TLS validation against these proxies."
}

stop_proxies() {
  if [[ -d "$PID_DIR" ]]; then
    for pid_file in "$PID_DIR"/*.pid; do
      [[ -f "$pid_file" ]] || continue
      local pid
      pid="$(cat "$pid_file")"
      kill "$pid" >/dev/null 2>&1 || true
      rm -f "$pid_file"
    done
  fi
}

run_tests() {
  require_gated
  export DGW_PUBLIC_DNS_INTEGRATION=1
  export DGW_REAL_RUNTIME_INTEGRATION=1
  export DGW_REAL_DEVICE_INIT_INTEGRATION=1
  export DGW_REAL_CREDENTIAL_BASE64="${DGW_LOCAL_CREDENTIAL_BASE64:-${DGW_REAL_CREDENTIAL_BASE64:-}}"
  export DGW_REAL_DEVICE_ID="${DGW_LOCAL_DEVICE_ID:-${DGW_REAL_DEVICE_ID:-}}"
  export DGW_REAL_PERSIST_ROOT="${DGW_LOCAL_PERSIST_ROOT:-${DGW_REAL_PERSIST_ROOT:-$(mktemp -d /tmp/swift-dgw-public-dns.XXXXXX)}}"
  export DGW_OSS_TEST_ENDPOINT="${DGW_OSS_TEST_ENDPOINT:-https://oss-cn-shanghai.aliyuncs.com}"
  export DGW_OSS_TEST_BUCKET="${DGW_OSS_TEST_BUCKET:-public-dns-placeholder}"
  export DGW_OSS_TEST_ACCESS_KEY_ID="${DGW_OSS_TEST_ACCESS_KEY_ID:-placeholder}"
  export DGW_OSS_TEST_ACCESS_KEY_SECRET="${DGW_OSS_TEST_ACCESS_KEY_SECRET:-placeholder}"
  export DGW_OSS_TEST_SECURITY_TOKEN="${DGW_OSS_TEST_SECURITY_TOKEN:-placeholder}"
  export DGW_OSS_TEST_OBJECT_PREFIX="${DGW_OSS_TEST_OBJECT_PREFIX:-swift-public-dns}"
  if [[ "${DGW_PUBLIC_DNS_DEV:-}" == "1" ]]; then
    (cd "$SDK_DIR" && swift test -Xswiftc -DDEV --filter LocalStackHarnessTests)
  else
    (cd "$SDK_DIR" && swift test --filter LocalStackHarnessTests)
  fi
}

case "${1:-}" in
  prepare-hosts) prepare_hosts ;;
  start-proxies) start_proxies ;;
  run-tests) run_tests ;;
  cleanup) stop_proxies; cleanup_hosts ;;
  -h|--help|help|"") usage ;;
  *) usage >&2; exit 2 ;;
esac
