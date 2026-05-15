#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKSPACE_DIR="$(cd "${PACKAGE_DIR}/.." && pwd)"
DATA_PLATFORM_ROOT="${DATA_PLATFORM_ROOT:-${WORKSPACE_DIR}/data-platform}"
DATA_PLATFORM_ALIYUN_CONFIG="${DATA_PLATFORM_ALIYUN_CONFIG:-${DATA_PLATFORM_ROOT}/_prd_aliyun_deploy_0515.yaml}"
ENV_FILE="${DATA_SDK_ALIYUN_ENV_FILE:-/tmp/data-sdk-aliyun-env.sh}"
RUN_CLEANUP="${DATA_SDK_ALIYUN_CLEAN_TEST_DATA:-true}"
CLEANUP_DRY_RUN=false
SWIFT_ARGS=()

usage() {
  cat <<'EOF'
Usage: Scripts/run_aliyun_integration.sh [options] [swift test args...]

Runs data-sdk Swift tests with the real Aliyun integration environment, then
cleans e2e test data from data-platform DB and OSS.

Options:
  --env-file PATH              Source Aliyun test env exports before swift test
  --data-platform-root PATH    data-platform checkout path
  --config PATH                data-platform Aliyun deploy config
  --skip-cleanup               Do not run data-platform e2e cleanup at exit
  --cleanup-dry-run            Print cleanup plan without deleting data
  --help                       Show this help

Examples:
  Scripts/run_aliyun_integration.sh
  Scripts/run_aliyun_integration.sh -- --filter manualAliyunDeviceInitOnce
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file)
      ENV_FILE="${2:-}"
      shift 2
      ;;
    --env-file=*)
      ENV_FILE="${1#--env-file=}"
      shift
      ;;
    --data-platform-root)
      DATA_PLATFORM_ROOT="${2:-}"
      shift 2
      ;;
    --data-platform-root=*)
      DATA_PLATFORM_ROOT="${1#--data-platform-root=}"
      shift
      ;;
    --config)
      DATA_PLATFORM_ALIYUN_CONFIG="${2:-}"
      shift 2
      ;;
    --config=*)
      DATA_PLATFORM_ALIYUN_CONFIG="${1#--config=}"
      shift
      ;;
    --skip-cleanup)
      RUN_CLEANUP=false
      shift
      ;;
    --cleanup-dry-run)
      CLEANUP_DRY_RUN=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --)
      shift
      SWIFT_ARGS+=("$@")
      break
      ;;
    *)
      SWIFT_ARGS+=("$1")
      shift
      ;;
  esac
done

case "${RUN_CLEANUP}" in
  false|FALSE|0|no|NO|off|OFF) RUN_CLEANUP=false ;;
  *) RUN_CLEANUP=true ;;
esac

if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi

cleanup() {
  local exit_rc=$?
  local cleanup_rc=0
  if [[ "${RUN_CLEANUP}" == "true" ]]; then
    if [[ ! -f "${DATA_PLATFORM_ALIYUN_CONFIG}" ]]; then
      echo "data-platform Aliyun config not found: ${DATA_PLATFORM_ALIYUN_CONFIG}" >&2
      cleanup_rc=1
    else
      # shellcheck source=../../data-platform/deploy/aliyun/lib/db.sh
      source "${DATA_PLATFORM_ROOT}/deploy/aliyun/lib/db.sh"
      aliyun_deploy_load_config "${DATA_PLATFORM_ALIYUN_CONFIG}" >/dev/null
      aliyun_deploy_init_state_dir >/dev/null
      E2E_STORE_DB_HOST="${ALIYUN_DEPLOY_DB_OPERATOR_HOST}" \
      E2E_STORE_DB_PORT="${ALIYUN_DEPLOY_DB_OPERATOR_PORT}" \
      E2E_STORE_DB_USER="${ALIYUN_DEPLOY_DB_USERNAME}" \
      E2E_STORE_DB_PASSWORD="${ALIYUN_DEPLOY_DB_PASSWORD}" \
      E2E_STORE_DB_NAME="${ALIYUN_DEPLOY_DB_STORE_NAME}" \
      E2E_OSS_BUCKET="${ALIYUN_DEPLOY_OSS_BUCKET}" \
      E2E_OSS_ENDPOINT="${ALIYUN_DEPLOY_OSS_PUBLIC_ENDPOINT}" \
      E2E_OSS_KEY_PREFIX="${ALIYUN_DEPLOY_OSS_KEY_PREFIX}" \
      E2E_ALIYUN_CLI_PROFILE="${ALIYUN_DEPLOY_CLI_PROFILE}" \
      E2E_CLEANUP_DATA_SDK_ENV_FILE="${ENV_FILE}" \
      E2E_CLEAN_TEST_DATA_DRY_RUN="${CLEANUP_DRY_RUN}" \
      "${DATA_PLATFORM_ROOT}/integration_tests/e2e/cleanup_test_data.sh" || cleanup_rc=$?
    fi
  fi
  if [[ "${exit_rc}" -eq 0 && "${cleanup_rc}" -ne 0 ]]; then
    return "${cleanup_rc}"
  fi
  return "${exit_rc}"
}
trap cleanup EXIT

cd "${PACKAGE_DIR}"
swift test "${SWIFT_ARGS[@]}"
