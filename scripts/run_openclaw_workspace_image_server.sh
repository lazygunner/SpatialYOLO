#!/usr/bin/env bash

set -euo pipefail

export WORKSPACE_IMAGE_SERVER_HOST="${WORKSPACE_IMAGE_SERVER_HOST:-0.0.0.0}"
export WORKSPACE_IMAGE_SERVER_PORT="${WORKSPACE_IMAGE_SERVER_PORT:-18888}"
export WORKSPACE_IMAGE_JOBS_DIR="${WORKSPACE_IMAGE_JOBS_DIR:-/tmp/openclaw-image-jobs}"
export WORKSPACE_IMAGE_EXECUTOR="${WORKSPACE_IMAGE_EXECUTOR:-taobao-image-search}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

export OPENCLAW_IMAGE_PATH="${OPENCLAW_IMAGE_PATH:-${WORKSPACE_IMAGE_PATH:-/Users/gunner/.openclaw/workspace/image.png}}"
export OPENCLAW_BASE_URL="${OPENCLAW_BASE_URL:-${OPENCLAW_GATEWAY_BASE_URL:-http://127.0.0.1:18789}}"
export OPENCLAW_MODEL="${OPENCLAW_MODEL:-${OPENCLAW_GATEWAY_MODEL:-openclaw:main}}"
export WORKSPACE_IMAGE_SERVER_TOKEN="${WORKSPACE_IMAGE_SERVER_TOKEN:-${OPENCLAW_UPLOAD_TOKEN:-${OPENCLAW_TOKEN:-${OPENCLAW_GATEWAY_TOKEN:-}}}}"
export OPENCLAW_UPLOAD_TOKEN="${OPENCLAW_UPLOAD_TOKEN:-${WORKSPACE_IMAGE_SERVER_TOKEN}}"
export OPENCLAW_GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-${OPENCLAW_TOKEN:-${WORKSPACE_IMAGE_SERVER_TOKEN}}}"
export TAOBAO_IMAGE_SEARCH_DIR="${TAOBAO_IMAGE_SEARCH_DIR:-${SCRIPT_DIR}/taobao-image-search}"
export OPENCLAW_WAIT_FOR_TAOBAO_LOGIN_ON_EXIT="${OPENCLAW_WAIT_FOR_TAOBAO_LOGIN_ON_EXIT:-1}"

LOG_FILE="$(mktemp "${TMPDIR:-/tmp}/openclaw-workspace-image-server.XXXXXX.log")"
cleanup() {
  rm -f "${LOG_FILE}"
}
trap cleanup EXIT

wait_for_manual_restart() {
  echo "[INFO] 检测到淘宝登录态缺失，服务先不退出。" >&2
  echo "[INFO] 请先手动登录淘宝；如需保存登录态，可运行 node save-taobao-cookie.js。" >&2
  echo "[INFO] 登录完成后，请手动重启 scripts/run_openclaw_workspace_image_server.sh。" >&2
  trap 'exit 130' INT TERM
  while true; do
    sleep 3600
  done
}

set +e
node "${SCRIPT_DIR}/openclaw_workspace_image_server.mjs" "$@" 2>&1 | tee "${LOG_FILE}"
status=${PIPESTATUS[0]}
set -e

if [[ "${OPENCLAW_WAIT_FOR_TAOBAO_LOGIN_ON_EXIT}" == "1" ]] && [[ ${status} -ne 0 ]]; then
  if grep -Eq '未检测到淘宝登录状态|请先登录后重试|save-taobao-cookie\.js|登录态' "${LOG_FILE}"; then
    wait_for_manual_restart
  fi
fi

exit "${status}"
