#!/bin/sh
set -eu

REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
DIST_DIR="${REPO_ROOT}/dist"
STAGE_ROOT="$(mktemp -d)"
trap 'rm -rf "${STAGE_ROOT}"' EXIT

mkdir -p "${DIST_DIR}"

copy_bundle() {
  dest="$1"
  mkdir -p "${dest}/bin"
  cp "${REPO_ROOT}/plugin/plugin.json" "${dest}/"
  cp "${REPO_ROOT}/plugin/mcp_config.json" "${dest}/"
  cp "${REPO_ROOT}/plugin/hooks.json" "${dest}/"
  cp -R "${REPO_ROOT}/plugin/assets" "${dest}/"
  cp -R "${REPO_ROOT}/plugin/rules" "${dest}/"
  cp -R "${REPO_ROOT}/plugin/sidecars" "${dest}/"
  cp -R "${REPO_ROOT}/plugin/skills" "${dest}/"
}

build_darwin() {
  arch="$1"
  stage="${STAGE_ROOT}/macos-${arch}"
  bundle="${stage}/agy-remote"
  copy_bundle "${bundle}"

  echo "[package] Building darwin/${arch}..."
  (
    cd "${REPO_ROOT}/bridge"
    GOTOOLCHAIN="${GOTOOLCHAIN:-auto}" CGO_ENABLED=0 GOOS=darwin GOARCH="${arch}" \
      go build -trimpath -ldflags="-s -w" -o "${bundle}/bin/agy-remote" ./cmd/agy-bridge
  )
  chmod +x "${bundle}/bin/agy-remote"

  out="${DIST_DIR}/agy-remote-macos-${arch}.tar.gz"
  tar -C "${stage}" -czf "${out}" agy-remote
  echo "[package] Created ${out}"
}

build_windows() {
  arch="$1"
  stage="${STAGE_ROOT}/windows-${arch}"
  bundle="${stage}/agy-remote"
  copy_bundle "${bundle}"

  echo "[package] Building windows/${arch}..."
  (
    cd "${REPO_ROOT}/bridge"
    GOTOOLCHAIN="${GOTOOLCHAIN:-auto}" CGO_ENABLED=0 GOOS=windows GOARCH="${arch}" \
      go build -trimpath -ldflags="-s -w" -o "${bundle}/bin/agy-remote.exe" ./cmd/agy-bridge
  )

  python3 - "${bundle}" "${DIST_DIR}/agy-remote-windows-${arch}.zip" <<'PY'
import json, pathlib, sys, zipfile

bundle = pathlib.Path(sys.argv[1])
out_zip = pathlib.Path(sys.argv[2])

# Rewrite binary references to .exe inside the staged Windows bundle and validate JSON.
replacements = [
    ("mcp_config.json", '/bin/agy-remote"', '/bin/agy-remote.exe"'),
    ("hooks.json", './bin/agy-remote ', './bin/agy-remote.exe '),
    ("sidecars/remote/sidecar.json", '../../bin/agy-remote"', '../../bin/agy-remote.exe"'),
]
for rel, old, new in replacements:
    p = bundle / rel
    text = p.read_text("utf-8")
    assert old in text, f"expected {old!r} in {rel}"
    patched = text.replace(old, new)
    json.loads(patched)
    p.write_text(patched, encoding="utf-8")

with zipfile.ZipFile(out_zip, "w", compression=zipfile.ZIP_DEFLATED) as zf:
    for f in sorted(bundle.rglob("*")):
        if f.is_file():
            arcname = f.relative_to(bundle.parent).as_posix()
            zf.write(f, arcname)
print(f"[package] Created {out_zip}")
PY
}

build_darwin arm64
build_darwin amd64
build_windows amd64

ls -lh "${DIST_DIR}"
