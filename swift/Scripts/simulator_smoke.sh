#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PACKAGE_DIR="${ROOT_DIR}/swift"
SCHEME="${DGW_IOS_SMOKE_SCHEME:-SwiftDataGatewayClient-Package}"
DESTINATION="${DGW_IOS_SMOKE_DESTINATION:-platform=iOS Simulator,name=iPhone 17}"
DESTINATION_TIMEOUT_SECONDS="${DGW_IOS_SMOKE_DESTINATION_TIMEOUT_SECONDS:-30}"
CHECK_COMMAND_TIMEOUT_SECONDS="${DGW_IOS_SMOKE_CHECK_COMMAND_TIMEOUT_SECONDS:-60}"
DEFAULT_TEST_TIMEOUT_SECONDS="${DGW_IOS_SMOKE_DEFAULT_TEST_TIMEOUT_SECONDS:-120}"
MAX_TEST_TIMEOUT_SECONDS="${DGW_IOS_SMOKE_MAX_TEST_TIMEOUT_SECONDS:-300}"
OTHER_SWIFT_FLAGS_VALUE="${DGW_IOS_SMOKE_OTHER_SWIFT_FLAGS:-}"
if [[ "${DGW_PUBLIC_DNS_DEV:-}" == "1" ]]; then
  OTHER_SWIFT_FLAGS_VALUE="${OTHER_SWIFT_FLAGS_VALUE:+${OTHER_SWIFT_FLAGS_VALUE} }-DDEV"
fi
XCODEBUILD_BUILD_SETTINGS=()
if [[ -n "$OTHER_SWIFT_FLAGS_VALUE" ]]; then
  XCODEBUILD_BUILD_SETTINGS+=(OTHER_SWIFT_FLAGS="$OTHER_SWIFT_FLAGS_VALUE")
fi
if [[ "${DGW_IOS_SMOKE_PUBLIC_PATH:-}" == "1" ]]; then
  SMOKE_TEST_ONE="${DGW_IOS_SMOKE_TEST_ONE:-DataGatewayClientIntegrationTests/LocalStackHarnessTests/publicPathCanExchangeForBearerToken()}"
  SMOKE_TEST_TWO="${DGW_IOS_SMOKE_TEST_TWO:-DataGatewayClientIntegrationTests/LocalStackHarnessTests/publicPathRuntimeBootstrapAndControlPlaneFlow()}"
  SMOKE_TEST_THREE="${DGW_IOS_SMOKE_TEST_THREE:-DataGatewayClientIntegrationTests/LocalStackHarnessTests/publicPathDeviceInitThenUploadFlow()}"
else
  SMOKE_TEST_ONE="${DGW_IOS_SMOKE_TEST_ONE:-DataGatewayClientIntegrationTests/LocalStackHarnessTests/localCredentialCanExchangeForBearerToken()}"
  SMOKE_TEST_TWO="${DGW_IOS_SMOKE_TEST_TWO:-DataGatewayClientIntegrationTests/LocalStackHarnessTests/localStackRuntimeBootstrapAndControlPlaneFlow()}"
  SMOKE_TEST_THREE="${DGW_IOS_SMOKE_TEST_THREE:-DataGatewayClientIntegrationTests/LocalStackHarnessTests/localGatewayInitThenUploadFlow()}"
fi
DERIVED_DATA_PATH="${DGW_IOS_SMOKE_DERIVED_DATA_PATH:-$(mktemp -d /tmp/swift-dgw-derived.XXXXXX)}"

usage() {
  cat <<'EOF'
Usage: swift/Scripts/simulator_smoke.sh [--check-only] [--list-destinations]

Options:
  --check-only        Validate the package scheme and simulator SDK prerequisites without running tests.
  --list-destinations Show xcodebuild destinations for the package scheme.
  -h, --help          Show this help.

Environment overrides:
  DGW_IOS_SMOKE_SCHEME
  DGW_IOS_SMOKE_DESTINATION
  DGW_IOS_SMOKE_DESTINATION_TIMEOUT_SECONDS
  DGW_IOS_SMOKE_CHECK_COMMAND_TIMEOUT_SECONDS
  DGW_IOS_SMOKE_DEFAULT_TEST_TIMEOUT_SECONDS
  DGW_IOS_SMOKE_MAX_TEST_TIMEOUT_SECONDS
  DGW_IOS_SMOKE_TEST_ONE
  DGW_IOS_SMOKE_TEST_TWO
  DGW_IOS_SMOKE_TEST_THREE
  DGW_IOS_SMOKE_DERIVED_DATA_PATH
  DGW_IOS_SMOKE_PUBLIC_PATH=1 (use fixed public endpoint tests)
  DGW_IOS_SMOKE_OTHER_SWIFT_FLAGS (extra xcodebuild OTHER_SWIFT_FLAGS)
  DGW_PUBLIC_DNS_DEV=1 (use dev-prefixed public domains and compile with -DDEV)

Required environment for real smoke execution:
  DGW_LOCAL_AUTH_ENDPOINT (local mode only)
  DGW_LOCAL_GATEWAY_ENDPOINT (local mode only)
  DGW_LOCAL_INIT_ENDPOINT (local mode only)
  DGW_LOCAL_DEVICE_ID
  DGW_LOCAL_CREDENTIAL_BASE64
  DGW_LOCAL_PERSIST_ROOT (optional, defaults to a fresh temp dir)

Notes:
  - The script runs Swift package tests on the `SwiftDataGatewayClient-Package` scheme.
  - Local mode uses `build-for-testing` + patched `.xctestrun` so simulator-hosted tests receive `DGW_LOCAL_*` environment variables.
  - Public path mode does not inject auth/gateway/init endpoints. Prepare hosts and local TLS trust with `public_dns_path_test.sh` first.
  - For DEV public path mode, set DGW_PUBLIC_DNS_DEV=1 for both this script and public_dns_path_test.sh.
  - Swift Testing method filters must include `()` in the final test identifier.
  - xcodebuild test timeouts are enabled so hangs surface as bounded failures instead of endless runs.
EOF
}

MODE="run"
RUNTIME_ENV_PREFIX="DGW_LOCAL"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-only)
      MODE="check"
      ;;
    --list-destinations)
      MODE="list"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

if [[ -n "${DGW_RUNTIME_ENV_PREFIX:-}" ]]; then
  RUNTIME_ENV_PREFIX="${DGW_RUNTIME_ENV_PREFIX}"
fi

require_scheme() {
  local output
  local output_file
  output_file="$(mktemp /tmp/swift-dgw-xcodebuild-list.XXXXXX)"
  echo "Checking xcodebuild package scheme '${SCHEME}'..."
  if ! run_with_timeout "$CHECK_COMMAND_TIMEOUT_SECONDS" "$output_file" xcodebuild -list -skipPackageUpdates; then
    echo "xcodebuild -list failed or timed out after ${CHECK_COMMAND_TIMEOUT_SECONDS}s" >&2
    print_file_and_remove "$output_file" >&2
    exit 1
  fi
  output="$(<"$output_file")"
  rm -f "$output_file"
  if [[ "$output" != *"${SCHEME}"* ]]; then
    echo "xcodebuild scheme not found: ${SCHEME}" >&2
    echo "$output" >&2
    exit 1
  fi
}

require_simulator_sdk() {
  local output_file
  output_file="$(mktemp /tmp/swift-dgw-xcodebuild-sdks.XXXXXX)"
  echo "Checking installed iOS Simulator SDKs..."
  if ! run_with_timeout "$CHECK_COMMAND_TIMEOUT_SECONDS" "$output_file" xcodebuild -showsdks; then
    echo "xcodebuild -showsdks failed or timed out after ${CHECK_COMMAND_TIMEOUT_SECONDS}s" >&2
    print_file_and_remove "$output_file" >&2
    exit 1
  fi
  if ! grep -q 'iphonesimulator' "$output_file"; then
    echo "iOS Simulator SDK not available in current Xcode installation" >&2
    print_file_and_remove "$output_file" >&2
    exit 1
  fi
  rm -f "$output_file"
}

require_available_simulator() {
  local devices
  local output_file
  output_file="$(mktemp /tmp/swift-dgw-simctl-devices.XXXXXX)"
  echo "Checking available iOS Simulator devices..."
  if ! run_with_timeout "$CHECK_COMMAND_TIMEOUT_SECONDS" "$output_file" xcrun simctl list devices available; then
    echo "xcrun simctl list devices available failed or timed out after ${CHECK_COMMAND_TIMEOUT_SECONDS}s" >&2
    print_file_and_remove "$output_file" >&2
    exit 1
  fi
  devices="$(<"$output_file")"
  rm -f "$output_file"
  if [[ "$devices" != *"iPhone"* && "$devices" != *"iPad"* ]]; then
    echo "No available iOS simulator devices. Install a simulator runtime or run 'xcodebuild -downloadPlatform iOS'." >&2
    echo "$devices" >&2
    exit 1
  fi
}

require_smoke_test_filters() {
  for filter in "$SMOKE_TEST_ONE" "$SMOKE_TEST_TWO" "$SMOKE_TEST_THREE"; do
    if [[ "$filter" != *"()" ]]; then
      echo "Simulator smoke test filter must include trailing (): ${filter}" >&2
      exit 1
    fi
  done
}

print_file_and_remove() {
  local file_path="$1"
  if [[ -s "$file_path" ]]; then
    printf '%s\n' "$(<"$file_path")"
  fi
  rm -f "$file_path"
}

run_with_timeout() {
  local timeout_seconds="$1"
  local output_file="$2"
  shift 2
  python3 - "$timeout_seconds" "$output_file" "$@" <<'PY'
import subprocess
import sys

timeout = float(sys.argv[1])
output_file = sys.argv[2]
command = sys.argv[3:]

with open(output_file, "wb") as fh:
    try:
        completed = subprocess.run(
            command,
            stdout=fh,
            stderr=subprocess.STDOUT,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired:
        sys.exit(124)

sys.exit(completed.returncode)
PY
}

build_for_testing() {
  xcodebuild build-for-testing \
    -skipPackageUpdates \
    -scheme "$SCHEME" \
    -destination "$DESTINATION" \
    -destination-timeout "$DESTINATION_TIMEOUT_SECONDS" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    "${XCODEBUILD_BUILD_SETTINGS[@]}"
}

resolve_xctestrun_path() {
  local candidates=()
  shopt -s nullglob
  candidates=("$DERIVED_DATA_PATH"/Build/Products/*.xctestrun)
  shopt -u nullglob

  if [[ ${#candidates[@]} -ne 1 ]]; then
    echo "Expected exactly one .xctestrun file under ${DERIVED_DATA_PATH}/Build/Products, found ${#candidates[@]}" >&2
    exit 1
  fi

  printf '%s\n' "${candidates[0]}"
}

patch_xctestrun_environment() {
  local xctestrun_path="$1"
  python3 - "$xctestrun_path" "$RUNTIME_ENV_PREFIX" "$DGW_AUTH_ENDPOINT_VALUE" "$DGW_GATEWAY_ENDPOINT_VALUE" "$DGW_INIT_ENDPOINT_VALUE" "$DGW_DEVICE_ID_VALUE" "$DGW_CREDENTIAL_BASE64_VALUE" "$DGW_PERSIST_ROOT_VALUE" "$DEFAULT_TEST_TIMEOUT_SECONDS" "$MAX_TEST_TIMEOUT_SECONDS" <<'PY'
import plistlib
import os
import sys

path, prefix, auth, gateway, init_endpoint, device_id, credential, persist_root, default_timeout, max_timeout = sys.argv[1:]

with open(path, "rb") as fh:
    payload = plistlib.load(fh)

try:
    targets = payload["TestConfigurations"][0]["TestTargets"]
    target = next(item for item in targets if item.get("BlueprintName") == "DataGatewayClientIntegrationTests")
except (KeyError, IndexError, StopIteration) as exc:
    raise SystemExit(f"failed to locate DataGatewayClientIntegrationTests in {path}: {exc}")

for key in ("EnvironmentVariables", "TestingEnvironmentVariables"):
    variables = target.setdefault(key, {})
    variables[f"{prefix}_RUNTIME_INTEGRATION"] = "1"
    variables[f"{prefix}_AUTH_ENDPOINT"] = auth
    variables[f"{prefix}_GATEWAY_ENDPOINT"] = gateway
    variables[f"{prefix}_INIT_ENDPOINT"] = init_endpoint
    variables[f"{prefix}_DEVICE_ID"] = device_id
    variables[f"{prefix}_CREDENTIAL_BASE64"] = credential
    variables[f"{prefix}_PERSIST_ROOT"] = persist_root

for extra_key in (
    "DGW_OSS_TEST_ENDPOINT",
    "DGW_OSS_TEST_BUCKET",
    "DGW_OSS_TEST_ACCESS_KEY_ID",
    "DGW_OSS_TEST_ACCESS_KEY_SECRET",
    "DGW_OSS_TEST_SECURITY_TOKEN",
    "DGW_OSS_TEST_OBJECT_PREFIX",
    "DATA_GATEWAY_CLIENT_USE_MOCK_OSS",
    f"{prefix}_TLS_MODE",
):
    extra_value = os.environ.get(extra_key)
    if extra_value:
        for scope in ("EnvironmentVariables", "TestingEnvironmentVariables"):
            target.setdefault(scope, {})[extra_key] = extra_value

target["TestTimeoutsEnabled"] = True
target["DefaultTestExecutionTimeAllowance"] = int(default_timeout)
target["MaximumTestExecutionTimeAllowance"] = int(max_timeout)

with open(path, "wb") as fh:
    plistlib.dump(payload, fh)
PY
}

patch_xctestrun_public_environment() {
  local xctestrun_path="$1"
  python3 - "$xctestrun_path" "$DGW_DEVICE_ID_VALUE" "$DGW_CREDENTIAL_BASE64_VALUE" "$DGW_PERSIST_ROOT_VALUE" "$DEFAULT_TEST_TIMEOUT_SECONDS" "$MAX_TEST_TIMEOUT_SECONDS" <<'PY'
import plistlib
import sys

path, device_id, credential, persist_root, default_timeout, max_timeout = sys.argv[1:]

with open(path, "rb") as fh:
    payload = plistlib.load(fh)

try:
    targets = payload["TestConfigurations"][0]["TestTargets"]
    target = next(item for item in targets if item.get("BlueprintName") == "DataGatewayClientIntegrationTests")
except (KeyError, IndexError, StopIteration) as exc:
    raise SystemExit(f"failed to locate DataGatewayClientIntegrationTests in {path}: {exc}")

for key in ("EnvironmentVariables", "TestingEnvironmentVariables"):
    variables = target.setdefault(key, {})
    variables["DGW_PUBLIC_DNS_INTEGRATION"] = "1"
    variables["DGW_REAL_RUNTIME_INTEGRATION"] = "1"
    variables["DGW_REAL_DEVICE_INIT_INTEGRATION"] = "1"
    variables["DGW_REAL_DEVICE_ID"] = device_id
    variables["DGW_REAL_CREDENTIAL_BASE64"] = credential
    variables["DGW_REAL_PERSIST_ROOT"] = persist_root
    variables["DATA_GATEWAY_CLIENT_USE_MOCK_OSS"] = "1"
    variables["DGW_OSS_TEST_ENDPOINT"] = "https://oss-cn-shanghai.aliyuncs.com"
    variables["DGW_OSS_TEST_BUCKET"] = "public-dns-placeholder"
    variables["DGW_OSS_TEST_ACCESS_KEY_ID"] = "placeholder"
    variables["DGW_OSS_TEST_ACCESS_KEY_SECRET"] = "placeholder"
    variables["DGW_OSS_TEST_SECURITY_TOKEN"] = "placeholder"
    variables["DGW_OSS_TEST_OBJECT_PREFIX"] = "swift-public-dns"

target["TestTimeoutsEnabled"] = True
target["DefaultTestExecutionTimeAllowance"] = int(default_timeout)
target["MaximumTestExecutionTimeAllowance"] = int(max_timeout)

with open(path, "wb") as fh:
    plistlib.dump(payload, fh)
PY
}

require_public_path_ready() {
  local domain_prefix=""
  if [[ "${DGW_PUBLIC_DNS_DEV:-}" == "1" ]]; then
    domain_prefix="dev-"
  fi
  for domain in "${domain_prefix}auth.platform.archebase.ai" "${domain_prefix}gateway.platform.archebase.ai" "${domain_prefix}init-device.platform.archebase.ai"; do
    if ! grep -q "${domain}" /etc/hosts; then
      echo "${domain} is not mapped in /etc/hosts. Run public_dns_path_test.sh prepare-hosts first." >&2
      exit 1
    fi
  done
}

run_smoke_tests() {
  local xctestrun_path="$1"
  xcodebuild test-without-building \
    -xctestrun "$xctestrun_path" \
    -destination "$DESTINATION" \
    -destination-timeout "$DESTINATION_TIMEOUT_SECONDS" \
    "-only-testing:${SMOKE_TEST_ONE}" \
    "-only-testing:${SMOKE_TEST_TWO}" \
    "-only-testing:${SMOKE_TEST_THREE}"
}

pushd "$PACKAGE_DIR" >/dev/null
require_scheme
require_simulator_sdk
require_smoke_test_filters

case "$MODE" in
  check)
    echo "Simulator smoke prerequisites look valid for scheme: ${SCHEME}"
    ;;
  list)
    xcodebuild -scheme "$SCHEME" -showdestinations
    ;;
  run)
    require_available_simulator

    CREDENTIAL_KEY="${RUNTIME_ENV_PREFIX}_CREDENTIAL_BASE64"
    DEVICE_ID_KEY="${RUNTIME_ENV_PREFIX}_DEVICE_ID"
    PERSIST_ROOT_KEY="${RUNTIME_ENV_PREFIX}_PERSIST_ROOT"
    RUNTIME_FLAG_KEY="${RUNTIME_ENV_PREFIX}_RUNTIME_INTEGRATION"

    export "${RUNTIME_FLAG_KEY}=1"
    export "${PERSIST_ROOT_KEY}=${DGW_REAL_PERSIST_ROOT_OVERRIDE:-${!PERSIST_ROOT_KEY:-$(mktemp -d /tmp/swift-dgw-sim.XXXXXX)}}"

    for key in "$CREDENTIAL_KEY"; do
      if [[ -z "${!key:-}" ]]; then
        echo "${key} is required for simulator smoke execution" >&2
        exit 1
      fi
    done

    if [[ "${DGW_IOS_SMOKE_PUBLIC_PATH:-}" != "1" ]]; then
      AUTH_ENDPOINT_KEY="${RUNTIME_ENV_PREFIX}_AUTH_ENDPOINT"
      GATEWAY_ENDPOINT_KEY="${RUNTIME_ENV_PREFIX}_GATEWAY_ENDPOINT"
      INIT_ENDPOINT_KEY="${RUNTIME_ENV_PREFIX}_INIT_ENDPOINT"
      for key in "$AUTH_ENDPOINT_KEY" "$GATEWAY_ENDPOINT_KEY"; do
        if [[ -z "${!key:-}" ]]; then
          echo "${key} is required for simulator smoke execution" >&2
          exit 1
        fi
      done
    fi

    DGW_DEVICE_ID_VALUE="${!DEVICE_ID_KEY:-}"
    DGW_CREDENTIAL_BASE64_VALUE="${!CREDENTIAL_KEY}"
    DGW_PERSIST_ROOT_VALUE="${!PERSIST_ROOT_KEY}"

    build_for_testing
    XCTESTRUN_PATH="$(resolve_xctestrun_path)"
    if [[ "${DGW_IOS_SMOKE_PUBLIC_PATH:-}" == "1" ]]; then
      require_public_path_ready
      patch_xctestrun_public_environment "$XCTESTRUN_PATH"
    else
      DGW_AUTH_ENDPOINT_VALUE="${!AUTH_ENDPOINT_KEY}"
      DGW_GATEWAY_ENDPOINT_VALUE="${!GATEWAY_ENDPOINT_KEY}"
      DGW_INIT_ENDPOINT_VALUE="${!INIT_ENDPOINT_KEY:-}"
      patch_xctestrun_environment "$XCTESTRUN_PATH"
    fi
    run_smoke_tests "$XCTESTRUN_PATH"
    ;;
esac

popd >/dev/null
