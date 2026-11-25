#!/bin/sh
set -eu

REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
export GOTOOLCHAIN="${GOTOOLCHAIN:-auto}"
export PUB_HOSTED_URL="${PUB_HOSTED_URL:-https://pub.flutter-io.cn}"
export FLUTTER_STORAGE_BASE_URL="${FLUTTER_STORAGE_BASE_URL:-https://storage.flutter-io.cn}"

echo "=== [1/5] Go vet & race-enabled unit tests ==="
(
  cd "${REPO_ROOT}/bridge"
  go vet ./...
  go test -race ./...
)

echo "=== [2/5] Antigravity plugin manifest & guardrails check ==="
python3 - "${REPO_ROOT}" <<'PY'
import json, pathlib, sys

root = pathlib.Path(sys.argv[1])
plugin_dir = root / "plugin"

allowed_plugin_keys = {
    "name", "displayName", "version", "description", "logo",
    "suggestedPrompts", "author", "homepage", "repository", "disabled",
}
pj = json.loads((plugin_dir / "plugin.json").read_text("utf-8"))
unknown = set(pj.keys()) - allowed_plugin_keys
assert not unknown, f"plugin.json contains disallowed top-level keys: {unknown}"
assert pj.get("name") == "agy-remote", f"unexpected plugin name: {pj.get('name')}"
logo = pj.get("logo", "")
assert logo and (plugin_dir / logo).is_file(), f"plugin logo missing: {logo}"

for rel in ["hooks.json", "mcp_config.json", "sidecars/remote/sidecar.json"]:
    data = json.loads((plugin_dir / rel).read_text("utf-8"))
    assert isinstance(data, dict) and len(data) > 0, f"invalid or empty {rel}"

# Guardrail: prevent hardcoded subscription tier fallback regression in UI templates.
quota_card = (root / "app/lib/ui/home/quota_card.dart").read_text("utf-8")
assert "?? 'Google AI Ultra'" not in quota_card, "regression: hardcoded 'Google AI Ultra' fallback in quota_card.dart"
sidecar_ui = (root / "bridge/internal/sidecarui/ui.go").read_text("utf-8")
assert '>Google AI Ultra<' not in sidecar_ui, "regression: hardcoded 'Google AI Ultra' placeholder in sidecarui/ui.go"

print("Plugin manifests and regression guardrails OK.")
PY

echo "=== [3/5] Pure Dart agy_client analyze & test ==="
(
  cd "${REPO_ROOT}/app/packages/agy_client"
  dart analyze --fatal-infos
  dart test
)

echo "=== [4/5] Flutter app analyze & widget tests ==="
(
  cd "${REPO_ROOT}/app"
  flutter --no-version-check --suppress-analytics analyze
  flutter --no-version-check --suppress-analytics test
)

echo "=== [5/5] All Done Gate checks PASSED ==="
