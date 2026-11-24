#!/bin/sh
set -eu

# Live end-to-end smoke check against the running local agy-remote sidecar (127.0.0.1:8765).
# Verifies health, auth rejection, authoritative quota, session list, FTS search, and path sandbox.

BASE_URL="${AGY_REMOTE_URL:-http://127.0.0.1:8765}"
CONFIG_PATH="${AGY_REMOTE_CONFIG:-${HOME}/.config/antigravity-mobile/config.json}"

NO_PROXY="*" python3 - "${BASE_URL}" "${CONFIG_PATH}" <<'PY'
import json, pathlib, sys, urllib.error, urllib.request

base_url, cfg_path = sys.argv[1].rstrip("/"), pathlib.Path(sys.argv[2])
cfg = json.loads(cfg_path.read_text("utf-8"))
token = cfg["bootstrapToken"]
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

def req_json(method, path, body=None, auth=True):
    headers = {"Content-Type": "application/json"}
    if auth:
        headers["Authorization"] = f"Bearer {token}"
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(base_url + path, data=data, headers=headers, method=method)
    with opener.open(req, timeout=8) as r:
        return r.status, json.loads(r.read().decode("utf-8"))

# 1. Health check
st, health = req_json("GET", "/api/v1/health", auth=False)
assert st == 200 and health.get("ok") is True, f"health failed: {st} {health}"
desktop_online = bool(health.get("desktopOnline"))
print(f"[PASS] health: host={health.get('hostName')} desktopOnline={desktop_online}")

# 2. Unauthenticated RPC must be rejected with HTTP 401
try:
    req_json("POST", "/api/v1/rpc", {"requestId": "smoke_unauth", "method": "quota.get"}, auth=False)
    raise AssertionError("unauthenticated RPC unexpectedly succeeded")
except urllib.error.HTTPError as e:
    assert e.code == 401, f"expected 401, got {e.code}"
    print("[PASS] auth guard: unauthenticated RPC rejected with 401")

# 3. Quota RPC (must return real direct quota when desktop is online)
st, qresp = req_json("POST", "/api/v1/rpc", {"requestId": "smoke_quota", "method": "quota.get", "params": {}})
assert st == 200 and qresp.get("ok") is True, f"quota.get failed: {qresp}"
qdata = qresp["data"]
assert qdata.get("subscriptionTier"), f"empty subscriptionTier: {qdata}"
pools = qdata.get("pools") or []
assert len(pools) >= 2, f"expected >=2 quota pools, got {pools}"
if desktop_online:
    assert all(p.get("source") == "direct" for p in pools), f"expected direct quota source when desktopOnline=true: {pools}"
print(f"[PASS] quota.get: tier={qdata['subscriptionTier']} pools={[(p['poolId'], p['remaining5hPct'], p['source']) for p in pools]}")

# 4. Sessions list & FTS search
st, sresp = req_json("POST", "/api/v1/rpc", {"requestId": "smoke_list", "method": "sessions.list", "params": {"mode": "desktop", "limit": 5}})
assert st == 200 and sresp.get("ok") is True, f"sessions.list failed: {sresp}"
reg = sresp["data"].get("regular") or []
pin = sresp["data"].get("pinned") or []
print(f"[PASS] sessions.list: pinned={len(pin)} regular={len(reg)}")

st, fts = req_json("POST", "/api/v1/rpc", {"requestId": "smoke_search", "method": "sessions.search", "params": {"query": "Antigravity", "limit": 5}})
assert st == 200 and fts.get("ok") is True, f"sessions.search failed: {fts}"
print(f"[PASS] sessions.search: hits={len(fts['data'].get('hits') or [])}")

# 5. Path sandbox must reject /etc/passwd traversal
st, fresp = req_json("GET", "/api/v1/files/content?convId=smoke-test&path=/etc/passwd")
assert st == 200 and fresp.get("ok") is False and fresp.get("error", {}).get("code") == "PATH_FORBIDDEN", f"sandbox failed to block /etc/passwd: {fresp}"
print("[PASS] filesandbox guard: /etc/passwd blocked with PATH_FORBIDDEN")

print("=== Live agy-remote smoke check PASSED ===")
PY
