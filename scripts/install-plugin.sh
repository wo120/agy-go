#!/bin/sh
set -eu

REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TARGET_DIR="${HOME}/.gemini/config/plugins/agy-remote"

echo "[agy-remote] Building Go binary..."
mkdir -p "${REPO_ROOT}/plugin/bin"
(
  cd "${REPO_ROOT}/bridge"
  GOTOOLCHAIN="${GOTOOLCHAIN:-auto}" go build -o "${REPO_ROOT}/plugin/bin/agy-remote" ./cmd/agy-bridge
)

echo "[agy-remote] Installing plugin bundle to ${TARGET_DIR} ..."
mkdir -p "${TARGET_DIR}"
rm -rf "${TARGET_DIR}/assets" "${TARGET_DIR}/bin" "${TARGET_DIR}/rules" "${TARGET_DIR}/sidecars" "${TARGET_DIR}/skills"
cp "${REPO_ROOT}/plugin/plugin.json" "${TARGET_DIR}/"
cp "${REPO_ROOT}/plugin/mcp_config.json" "${TARGET_DIR}/"
cp "${REPO_ROOT}/plugin/hooks.json" "${TARGET_DIR}/"
cp -R "${REPO_ROOT}/plugin/assets" "${TARGET_DIR}/"
cp -R "${REPO_ROOT}/plugin/bin" "${TARGET_DIR}/"
cp -R "${REPO_ROOT}/plugin/rules" "${TARGET_DIR}/"
cp -R "${REPO_ROOT}/plugin/sidecars" "${TARGET_DIR}/"
cp -R "${REPO_ROOT}/plugin/skills" "${TARGET_DIR}/"
chmod +x "${TARGET_DIR}/bin/agy-remote"

# Gracefully terminate any running old sidecar binary so Antigravity (restart_policy: always) respawns the new build.
if pgrep -f "bin/agy-remote sidecar" >/dev/null 2>&1; then
  echo "[agy-remote] Restarting running sidecar process..."
  pkill -f "bin/agy-remote sidecar" || true
fi

echo "[agy-remote] Installed successfully at ${TARGET_DIR}"
