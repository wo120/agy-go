package sidecarui

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"

	"rsc.io/qr"

	"github.com/antigravity-mobile/bridge/internal/hubserver"
	"github.com/antigravity-mobile/bridge/internal/notifier"
)

// Server serves the Antigravity Aux Pane Web UI on 127.0.0.1:$ANTIGRAVITY_SIDECAR_WEB_PORT.
type Server struct {
	hub        *hubserver.Server
	configPath string
	uiToken    string
}

// New creates an Antigravity Sidecar UI handler backed by the live hub server.
func New(hub *hubserver.Server, configPath, uiToken string) *Server {
	return &Server{
		hub:        hub,
		configPath: configPath,
		uiToken:    strings.TrimSpace(uiToken),
	}
}

// Handler returns the loopback-only HTTP handler matching Antigravity sidecar_sdk conventions.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/", s.handleIndex)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"ok":true}`))
	})
	mux.HandleFunc("/api/status", s.handleStatus)
	mux.HandleFunc("/api/rotate-token", s.requireToken(s.handleRotateToken))
	mux.HandleFunc("/api/test-notify", s.requireToken(s.handleTestNotify))
	mux.HandleFunc("/api/tunnel/enable", s.requireToken(s.handleTunnelEnable))
	mux.HandleFunc("/api/tunnel/disable", s.requireToken(s.handleTunnelDisable))
	mux.HandleFunc("/api/tunnel/logout", s.requireToken(s.handleTunnelLogout))
	return mux
}

func (s *Server) requireToken(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		if s.uiToken != "" {
			provided := r.Header.Get("x-sidecar-token")
			if provided == "" {
				provided = r.URL.Query().Get("token")
			}
			if provided != s.uiToken {
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusUnauthorized)
				_, _ = w.Write([]byte(`{"error":"unauthorized"}`))
				return
			}
		}
		next(w, r)
	}
}

func (s *Server) handleIndex(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	html := strings.ReplaceAll(indexHTMLTemplate, "__SIDECAR_TOKEN__", jsonStringLiteral(s.uiToken))
	_, _ = w.Write([]byte(html))
}

func (s *Server) handleStatus(w http.ResponseWriter, r *http.Request) {
	forceRefresh := r.URL.Query().Get("refresh") == "1" || r.URL.Query().Get("refresh") == "true"
	summary := s.hub.StatusSummaryWithRefresh(r.Context(), forceRefresh)
	if pairing, ok := summary["pairing"]; ok {
		if raw, err := json.Marshal(pairing); err == nil {
			summary["pairingJson"] = string(raw)
			if svg, err := BuildQRSVG(string(raw)); err == nil {
				summary["qrSvg"] = svg
			}
		}
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(w).Encode(summary)
}

func (s *Server) handleRotateToken(w http.ResponseWriter, r *http.Request) {
	if _, err := s.hub.RotateBootstrapToken(s.configPath); err != nil {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusInternalServerError)
		_ = json.NewEncoder(w).Encode(map[string]any{"ok": false, "error": err.Error()})
		return
	}
	s.handleStatus(w, r)
}

func (s *Server) handleTestNotify(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Title string `json:"title"`
		Body  string `json:"body"`
	}
	_ = json.NewDecoder(http.MaxBytesReader(w, r.Body, 16*1024)).Decode(&body)
	if strings.TrimSpace(body.Title) == "" {
		body.Title = "agy-remote 连接测试"
	}
	if strings.TrimSpace(body.Body) == "" {
		body.Body = "来自 Antigravity 桌面插件面板的实时提醒，确认收到后可直接回复测试闭环！"
	}
	s.hub.TriggerCustomAlert(notifier.Alert{
		Kind:         "NEED_CONFIRM",
		Title:        body.Title,
		Workspace:    "agy-remote",
		Body:         body.Body,
		QuickReplies: []string{"收到，测试正常", "稍后查看"},
	})
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"ok":      true,
		"clients": s.hub.ConnectedClientCount(),
	})
}

func (s *Server) handleTunnelEnable(w http.ResponseWriter, r *http.Request) {
	if err := s.hub.EnableTunnel(); err != nil {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusInternalServerError)
		_ = json.NewEncoder(w).Encode(map[string]any{"ok": false, "error": err.Error()})
		return
	}
	s.handleStatus(w, r)
}

func (s *Server) handleTunnelDisable(w http.ResponseWriter, r *http.Request) {
	if err := s.hub.DisableTunnel(); err != nil {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusInternalServerError)
		_ = json.NewEncoder(w).Encode(map[string]any{"ok": false, "error": err.Error()})
		return
	}
	s.handleStatus(w, r)
}

func (s *Server) handleTunnelLogout(w http.ResponseWriter, r *http.Request) {
	if err := s.hub.LogoutTunnel(); err != nil {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusInternalServerError)
		_ = json.NewEncoder(w).Encode(map[string]any{"ok": false, "error": err.Error()})
		return
	}
	s.handleStatus(w, r)
}

// BuildQRSVG encodes content into a clean high-contrast vector SVG QR code.
func BuildQRSVG(content string) (string, error) {
	code, err := qr.Encode(content, qr.L)
	if err != nil {
		return "", err
	}
	size := code.Size
	const quiet = 3
	dim := size + quiet*2

	var b strings.Builder
	fmt.Fprintf(&b, `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" shape-rendering="crispEdges">`, dim, dim)
	fmt.Fprintf(&b, `<rect width="%d" height="%d" rx="2" fill="#ffffff"/>`, dim, dim)
	b.WriteString(`<path fill="#0b0c18" d="`)
	for y := 0; y < size; y++ {
		for x := 0; x < size; x++ {
			if code.Black(x, y) {
				fmt.Fprintf(&b, "M%d %dh1v1h-1z", x+quiet, y+quiet)
			}
		}
	}
	b.WriteString(`"/></svg>`)
	return b.String(), nil
}

func jsonStringLiteral(s string) string {
	raw, _ := json.Marshal(s)
	return string(raw)
}

// ContextTimeout returns a bounded request context helper.
func ContextTimeout(ctx context.Context) context.Context {
	return ctx
}

const indexHTMLTemplate = `<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width,initial-scale=1" />
<title>agy-remote</title>
<style>
  :root {
    --bg: #0a0b14;
    --card: rgba(26, 28, 46, 0.82);
    --border: rgba(255, 255, 255, 0.11);
    --text: #f3f4f8;
    --sub: #9ea4ba;
    --muted: #727892;
    --green: #34d399;
    --purple: #a78bfa;
    --orange: #f59e0b;
    --blue: #60a5fa;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    padding: 14px;
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", sans-serif;
    background: radial-gradient(circle at 20% 0%, #221840 0%, #121024 45%, #0a0b14 100%);
    color: var(--text);
    min-height: 100vh;
  }
  .card {
    background: var(--card);
    border: 1px solid var(--border);
    border-radius: 16px;
    padding: 14px;
    margin-bottom: 12px;
    backdrop-filter: blur(14px);
  }
  .row { display: flex; align-items: center; justify-content: space-between; gap: 8px; }
  .title { font-size: 15px; font-weight: 700; display: flex; align-items: center; gap: 8px; }
  .dot { width: 8px; height: 8px; border-radius: 99px; background: var(--green); box-shadow: 0 0 8px var(--green); }
  .pill { font-size: 11px; padding: 3px 9px; border-radius: 99px; background: rgba(167,139,250,0.16); color: var(--purple); border: 1px solid rgba(167,139,250,0.3); }
  .pill.ok { background: rgba(52,211,153,0.16); color: var(--green); border-color: rgba(52,211,153,0.35); }
  .pill.warn { background: rgba(245,158,11,0.16); color: var(--orange); border-color: rgba(245,158,11,0.35); }
  a.btn {
    display: inline-block;
    text-decoration: none;
    cursor: pointer;
    border: 1px solid rgba(96,165,250,0.5);
    background: rgba(96,165,250,0.22);
    color: var(--text);
    padding: 7px 11px;
    border-radius: 10px;
    font-size: 12px;
    font-weight: 600;
  }
  a.btn:hover { background: rgba(96,165,250,0.32); }
  .qr-wrap {
    margin: 12px auto;
    width: 196px;
    height: 196px;
    padding: 8px;
    background: #ffffff;
    border-radius: 14px;
    display: flex;
    align-items: center;
    justify-content: center;
  }
  .qr-wrap svg { width: 100%; height: 100%; display: block; }
  .ep { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 11.5px; color: var(--blue); background: rgba(96,165,250,0.1); padding: 6px 8px; border-radius: 8px; margin-top: 6px; word-break: break-all; }
  .actions { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 12px; }
  button {
    cursor: pointer;
    border: 1px solid var(--border);
    background: rgba(255,255,255,0.07);
    color: var(--text);
    padding: 7px 11px;
    border-radius: 10px;
    font-size: 12px;
    font-weight: 600;
  }
  button.primary { background: rgba(167,139,250,0.24); border-color: rgba(167,139,250,0.45); }
  button:hover { background: rgba(255,255,255,0.14); }
  .quota-row { display: grid; grid-template-columns: 34px 1fr 38px 86px; gap: 8px; align-items: center; font-size: 12px; margin-top: 6px; white-space: nowrap; }
  .track { height: 5px; background: rgba(255,255,255,0.14); border-radius: 99px; overflow: hidden; }
  .fill { height: 100%; background: #e5e7f0; border-radius: 99px; }
  .fill.warn { background: var(--orange); }
  .warn-text { color: var(--orange); }
  .muted { color: var(--muted); font-size: 11.5px; }
  .toast { position: fixed; bottom: 14px; left: 50%; transform: translateX(-50%); background: #1e2138; border: 1px solid var(--border); padding: 7px 14px; border-radius: 99px; font-size: 12px; display: none; }
</style>
</head>
<body>
  <div class="card">
    <div class="row">
      <div class="title"><span class="dot" id="dot"></span><span id="hostName">agy-remote</span></div>
      <span class="pill" id="clientsBadge">0 台手机在线</span>
    </div>
    <div class="muted" style="margin-top:6px" id="listenInfo">监听中...</div>
  </div>

  <div class="card">
    <div class="row">
      <div class="title" style="font-size:13.5px">5G 远程直连（内置 Tailscale Funnel）</div>
      <span class="pill" id="tunnelBadge">未开启</span>
    </div>
    <div class="muted" style="margin-top:6px" id="tunnelDesc">开启后可用 GitHub 账号一键授权，生成固定公网 HTTPS 域名；手机端（含纯血鸿蒙）零安装直接 5G 连接。</div>
    <div id="tunnelBody" style="margin-top:8px"></div>
  </div>

  <div class="card">
    <div class="row">
      <div class="title" style="font-size:13.5px">Android / 移动端扫码直连</div>
      <span class="muted">AGY Go App</span>
    </div>
    <div class="qr-wrap" id="qrBox"><span style="color:#333;font-size:12px">生成二维码中...</span></div>
    <div id="endpointsBox"></div>
    <div class="actions">
      <button class="primary" onclick="copyPairing()">复制配对 JSON</button>
      <button onclick="sendTestNotify()">发送测试通知</button>
      <button onclick="rotateToken()">重置密钥</button>
    </div>
  </div>

  <div class="card">
    <div class="row" style="margin-bottom:8px">
      <div class="title" style="font-size:13.5px">模型配额监控 (5h / 7d)</div>
      <div style="display:flex;align-items:center;gap:8px">
        <span class="muted" id="subTier">检测中...</span>
        <button style="padding:3px 9px;font-size:11px" onclick="refresh(true, true)">刷新</button>
      </div>
    </div>
    <div id="quotaBox"></div>
    <div class="muted" id="quotaUpdated" style="margin-top:4px;font-size:11px"></div>
  </div>

  <div class="toast" id="toast"></div>

<script>
const SIDECAR_TOKEN = __SIDECAR_TOKEN__;
let lastPairingJson = "";
let lastAuthUrl = "";
let pollTimer = null;

function showToast(msg) {
  const el = document.getElementById("toast");
  el.textContent = msg;
  el.style.display = "block";
  clearTimeout(window._tt);
  window._tt = setTimeout(() => { el.style.display = "none"; }, 2200);
}

function fmtReset(ts, pct) {
  if (!ts) return "满额";
  const diff = ts - Math.floor(Date.now() / 1000);
  if (diff <= 60) return "即将重置";
  const d = Math.floor(diff / 86400);
  const h = Math.floor((diff % 86400) / 3600);
  const m = Math.floor((diff % 3600) / 60);
  if (d > 0) return d + "d " + h + "h 后重置";
  if (h > 0) return h + "h " + m + "m 后重置";
  return m + "m 后重置";
}

function render(data) {
  document.getElementById("hostName").textContent = (data.hostName || "agy-remote") + " · agy-remote";
  document.getElementById("clientsBadge").textContent = (data.connectedClients || 0) + " 台手机在线";
  document.getElementById("listenInfo").textContent =
    "监听 " + (data.listenAddr || "0.0.0.0:8765") + " · 桌面运行时 " + (data.desktopOnline ? "在线" : "未检测到");
  if (data.qrSvg) {
    document.getElementById("qrBox").innerHTML = data.qrSvg;
  }
  lastPairingJson = data.pairingJson || "";
  const eps = data.endpoints || [];
  document.getElementById("endpointsBox").innerHTML = eps.map(e => '<div class="ep">' + e + '</div>').join("");

  renderTunnel(data.tunnel || { state: "disabled" });

  const q = data.quota;
  if (q && q.pools) {
    document.getElementById("subTier").textContent = q.subscriptionTier || "Google AI";
    document.getElementById("quotaBox").innerHTML = q.pools.map(p => {
      const w5 = p.remaining5hPct < 40;
      const w7 = p.remaining7dPct < 40;
      return '<div style="margin-bottom:10px">' +
        '<div style="font-size:12.5px;font-weight:600">' + p.displayName + '</div>' +
        '<div class="quota-row"><span class="muted">5h</span><div class="track"><div class="fill ' + (w5 ? 'warn' : '') + '" style="width:' + p.remaining5hPct + '%"></div></div><span class="' + (w5 ? 'warn-text' : '') + '" style="text-align:right;font-weight:600">' + p.remaining5hPct + '%</span><span class="muted" style="text-align:right">' + fmtReset(p.reset5hAt, p.remaining5hPct) + '</span></div>' +
        '<div class="quota-row"><span class="muted">7d</span><div class="track"><div class="fill ' + (w7 ? 'warn' : '') + '" style="width:' + p.remaining7dPct + '%"></div></div><span class="' + (w7 ? 'warn-text' : '') + '" style="text-align:right;font-weight:600">' + p.remaining7dPct + '%</span><span class="muted" style="text-align:right">' + fmtReset(p.reset7dAt, p.remaining7dPct) + '</span></div>' +
      '</div>';
    }).join("");
    if (q.updatedAt) {
      const dt = new Date(q.updatedAt * 1000);
      const hh = String(dt.getHours()).padStart(2, "0");
      const mm = String(dt.getMinutes()).padStart(2, "0");
      const ss = String(dt.getSeconds()).padStart(2, "0");
      document.getElementById("quotaUpdated").textContent = "上次同步：" + hh + ":" + mm + ":" + ss;
    }
  }
}

function escHtml(s) {
  return String(s || "").replace(/[&<>"']/g, c => ({ "&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;" }[c]));
}

function renderTunnel(t) {
  const badge = document.getElementById("tunnelBadge");
  const desc = document.getElementById("tunnelDesc");
  const body = document.getElementById("tunnelBody");
  const state = t.state || "disabled";
  lastAuthUrl = t.authUrl || "";

  const labels = {
    disabled: ["未开启", "pill"],
    starting: ["启动中...", "pill warn"],
    needs_login: ["等待授权", "pill warn"],
    tailnet_only: ["待开启 Funnel", "pill warn"],
    running: ["5G 已就绪", "pill ok"],
    error: ["连接异常", "pill warn"]
  };
  const meta = labels[state] || ["未开启", "pill"];
  badge.textContent = meta[0];
  badge.className = meta[1];
  if (t.message) {
    desc.textContent = t.message;
  }

  let html = "";
  if (state === "disabled" || state === "error") {
    html = '<div class="actions"><button class="primary" onclick="tunnelAction(\'enable\')">开启 5G 远程（支持 GitHub 授权）</button></div>';
  } else if (state === "starting") {
    html = '<div class="actions"><button onclick="tunnelAction(\'disable\')">取消</button></div>';
  } else if (state === "needs_login") {
    html = '<div class="actions">' +
      (t.authUrl ? '<a class="btn" href="' + escHtml(t.authUrl) + '" target="_blank" rel="noreferrer">前往登录（GitHub / Google 授权）</a><button onclick="copyAuthUrl()">复制登录链接</button>' : '<span class="muted">正在获取授权链接...</span>') +
      '<button onclick="tunnelAction(\'disable\')">关闭</button>' +
      '</div>';
  } else if (state === "tailnet_only") {
    html = (t.accountLogin ? '<div class="muted">当前账号：' + escHtml(t.accountLogin) + '</div>' : '') +
      '<div class="actions">' +
      (t.helpUrl ? '<a class="btn" href="' + escHtml(t.helpUrl) + '" target="_blank" rel="noreferrer">打开 Tailscale 后台启用 HTTPS/Funnel</a>' : '') +
      '<button class="primary" onclick="tunnelAction(\'enable\')">已开启，立即重试</button>' +
      '<button onclick="tunnelAction(\'disable\')">关闭</button>' +
      '</div>';
  } else if (state === "running") {
    html = (t.funnelUrl ? '<div class="ep" style="color:var(--green);background:rgba(52,211,153,0.12)">公网 5G：' + escHtml(t.funnelUrl) + '</div>' : '') +
      (t.accountLogin ? '<div class="muted" style="margin-top:6px">已授权账号：' + escHtml(t.accountLogin) + '（已自动写入上方二维码）</div>' : '') +
      '<div class="actions">' +
      '<button onclick="tunnelAction(\'disable\')">关闭 5G 远程</button>' +
      '<button onclick="tunnelAction(\'logout\')">退出切换账号</button>' +
      '</div>';
  }
  body.innerHTML = html;

  const fast = (state === "starting" || state === "needs_login");
  schedulePoll(fast ? 2000 : 5000);
}

function schedulePoll(ms) {
  if (window._pollMs === ms && pollTimer) return;
  window._pollMs = ms;
  clearInterval(pollTimer);
  pollTimer = setInterval(refresh, ms);
}

async function copyAuthUrl() {
  if (!lastAuthUrl) return;
  try {
    await navigator.clipboard.writeText(lastAuthUrl);
    showToast("授权登录链接已复制");
  } catch {
    showToast("复制失败");
  }
}

async function tunnelAction(action) {
  const r = await fetch("/api/tunnel/" + action, {
    method: "POST",
    headers: { "Content-Type": "application/json", "x-sidecar-token": SIDECAR_TOKEN },
    body: "{}"
  });
  if (r.ok) {
    render(await r.json());
    if (action === "enable") showToast("已启动内置 Tailscale 节点");
    if (action === "disable") showToast("已关闭 5G 远程隧道");
    if (action === "logout") showToast("已退出 Tailscale 账号");
  } else {
    showToast("操作失败 (" + r.status + ")");
  }
}

let lastForceRefreshAt = 0;
async function refresh(force, announce) {
  try {
    if (force && !announce && Date.now() - lastForceRefreshAt < 3000) return;
    if (force) lastForceRefreshAt = Date.now();
    const url = force ? "/api/status?refresh=1&_t=" + Date.now() : "/api/status?_t=" + Date.now();
    const r = await fetch(url, { cache: "no-store" });
    const d = await r.json();
    render(d);
    if (announce) showToast("配额与状态已刷新");
  } catch (e) {}
}

async function copyPairing() {
  if (!lastPairingJson) return;
  try {
    await navigator.clipboard.writeText(lastPairingJson);
    showToast("配对 JSON 已复制");
  } catch {
    showToast("复制失败，请检查剪贴板权限");
  }
}

async function sendTestNotify() {
  const r = await fetch("/api/test-notify", {
    method: "POST",
    headers: { "Content-Type": "application/json", "x-sidecar-token": SIDECAR_TOKEN },
    body: "{}"
  });
  if (r.ok) {
    const d = await r.json();
    showToast("已推送测试通知（在线设备：" + (d.clients || 0) + "）");
  } else {
    showToast("推送失败 (" + r.status + ")");
  }
}

async function rotateToken() {
  const r = await fetch("/api/rotate-token", {
    method: "POST",
    headers: { "Content-Type": "application/json", "x-sidecar-token": SIDECAR_TOKEN },
    body: "{}"
  });
  if (r.ok) {
    render(await r.json());
    showToast("已生成新配对密钥，请重新扫码");
  } else {
    showToast("重置失败 (" + r.status + ")");
  }
}

document.addEventListener("visibilitychange", () => {
  if (!document.hidden) refresh(true, false);
});
window.addEventListener("focus", () => refresh(true, false));

refresh(true, false);
schedulePoll(5000);
</script>
</body>
</html>`
