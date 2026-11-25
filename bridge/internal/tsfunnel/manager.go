package tsfunnel

import (
	"context"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"regexp"
	"strings"
	"sync"
	"time"

	"tailscale.com/client/local"
	"tailscale.com/ipn"
	"tailscale.com/tsnet"
)

// State describes the lifecycle state of the embedded Tailscale Funnel tunnel.
type State string

const (
	StateDisabled    State = "disabled"
	StateStarting    State = "starting"
	StateNeedsLogin  State = "needs_login"
	StateRunning     State = "running"
	StateTailnetOnly State = "tailnet_only"
	StateError       State = "error"
)

// Status is the JSON telemetry snapshot rendered in the Antigravity Sidecar UI.
type Status struct {
	Enabled      bool   `json:"enabled"`
	State        State  `json:"state"`
	Hostname     string `json:"hostname"`
	AuthURL      string `json:"authUrl,omitempty"`
	FunnelURL    string `json:"funnelUrl,omitempty"`
	TailnetURL   string `json:"tailnetUrl,omitempty"`
	AccountLogin string `json:"accountLogin,omitempty"`
	Message      string `json:"message,omitempty"`
	HelpURL      string `json:"helpUrl,omitempty"`
}

// Options configures the embedded tsnet Funnel manager.
type Options struct {
	Hostname        string
	StateDir        string
	Port            string
	Handler         http.Handler
	OnPersistChange func(enabled bool)
}

// Manager hosts an embedded Tailscale node (tsnet) and exposes the mobile bridge over
// Tailscale Funnel (public HTTPS, zero phone VPN required) plus private Tailnet.
type Manager struct {
	hostname        string
	stateDir        string
	port            string
	handler         http.Handler
	onPersistChange func(enabled bool)

	mu            sync.RWMutex
	status        Status
	tsSrv         *tsnet.Server
	cancel        context.CancelFunc
	funnelSrv     *http.Server
	tailnetSrv    *http.Server
	funnelLn      net.Listener
	tailnetLn     net.Listener
	retryFunnelCh chan struct{}
	closed        bool
}

var urlPattern = regexp.MustCompile(`https://[^\s"'<>]+`)

// NewManager constructs a Tailscale Funnel manager (starts disabled until Enable is called).
func NewManager(opts Options) *Manager {
	port := strings.TrimSpace(opts.Port)
	if port == "" {
		port = "8765"
	}
	host := SanitizeHostname(opts.Hostname)
	return &Manager{
		hostname:        host,
		stateDir:        opts.StateDir,
		port:            port,
		handler:         PublicHandler(opts.Handler),
		onPersistChange: opts.OnPersistChange,
		status: Status{
			Enabled:  false,
			State:    StateDisabled,
			Hostname: host,
			Message:  "未开启外网隧道（当前仅局域网直连）",
		},
	}
}

// PublicHandler wraps the bridge handler for Funnel/Tailnet exposure, blocking loopback-only
// internal endpoints such as /internal/hook while keeping token-authenticated /api/v1/* intact.
func PublicHandler(inner http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/internal/") || r.URL.Path == "/internal" {
			http.NotFound(w, r)
			return
		}
		if inner == nil {
			http.NotFound(w, r)
			return
		}
		inner.ServeHTTP(w, r)
	})
}

// SanitizeHostname converts an arbitrary OS hostname into a valid DNS label prefixed with "agy-".
func SanitizeHostname(raw string) string {
	s := strings.ToLower(strings.TrimSpace(raw))
	s = strings.TrimSuffix(s, ".local")
	var b strings.Builder
	prevDash := false
	for _, r := range s {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') {
			b.WriteRune(r)
			prevDash = false
		} else if !prevDash && b.Len() > 0 {
			b.WriteByte('-')
			prevDash = true
		}
	}
	cleaned := strings.Trim(b.String(), "-")
	if cleaned == "" {
		cleaned = "host"
	}
	if !strings.HasPrefix(cleaned, "agy-") {
		cleaned = "agy-" + cleaned
	}
	if len(cleaned) > 60 {
		cleaned = strings.TrimRight(cleaned[:60], "-")
	}
	return cleaned
}

// ExtractHelpURL finds a Tailscale authorization/admin URL inside an error message or returns a sensible default.
func ExtractHelpURL(errText string) string {
	if m := urlPattern.FindString(errText); m != "" {
		return strings.TrimRight(m, ".,;)")
	}
	lower := strings.ToLower(errText)
	if strings.Contains(lower, "acl") || strings.Contains(lower, "policy") || strings.Contains(lower, "funnel") {
		return "https://login.tailscale.com/admin/acls"
	}
	return "https://login.tailscale.com/admin/dns"
}

// Status returns a thread-safe snapshot of the current tunnel state.
func (m *Manager) Status() Status {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.status
}

// Endpoints returns the active remote URLs (Tailnet IP and/or public Funnel HTTPS URL).
func (m *Manager) Endpoints() []string {
	m.mu.RLock()
	defer m.mu.RUnlock()
	var out []string
	if m.status.TailnetURL != "" {
		out = append(out, m.status.TailnetURL)
	}
	if m.status.FunnelURL != "" {
		out = append(out, m.status.FunnelURL)
	}
	return out
}

// Enable starts the embedded tsnet node (or immediately retries Funnel when already logged in).
func (m *Manager) Enable() error {
	m.mu.Lock()
	if m.closed {
		m.mu.Unlock()
		return fmt.Errorf("tunnel manager is closed")
	}
	// If already running in tailnet_only state, trigger immediate Funnel retry instead of restarting tsnet.
	if m.tsSrv != nil && m.status.State == StateTailnetOnly {
		ch := m.retryFunnelCh
		m.status.Message = "正在重新检测 Tailscale Funnel 状态..."
		m.mu.Unlock()
		if ch != nil {
			select {
			case ch <- struct{}{}:
			default:
			}
		}
		return nil
	}
	// Already starting, waiting for login, or running.
	if m.tsSrv != nil {
		m.mu.Unlock()
		return nil
	}

	if m.stateDir != "" {
		if err := os.MkdirAll(m.stateDir, 0o700); err != nil {
			m.mu.Unlock()
			return fmt.Errorf("create tsnet state dir: %w", err)
		}
	}

	ctx, cancel := context.WithCancel(context.Background())
	retryCh := make(chan struct{}, 1)
	tsSrv := &tsnet.Server{
		Hostname: m.hostname,
		Dir:      m.stateDir,
		UserLogf: m.captureUserLog,
		Logf:     func(string, ...any) {},
	}
	m.tsSrv = tsSrv
	m.cancel = cancel
	m.retryFunnelCh = retryCh
	m.status = Status{
		Enabled:  true,
		State:    StateStarting,
		Hostname: m.hostname,
		Message:  "正在启动内置 Tailscale 节点...",
	}
	persistFn := m.onPersistChange
	m.mu.Unlock()

	if persistFn != nil {
		persistFn(true)
	}

	go m.run(ctx, tsSrv, retryCh)
	return nil
}

// Disable stops the embedded tsnet node while keeping saved login state for instant re-enable.
func (m *Manager) Disable() error {
	m.stopRuntime(Status{
		Enabled:  false,
		State:    StateDisabled,
		Hostname: m.hostname,
		Message:  "已关闭 5G 远程直连（仅局域网直连）",
	})
	if m.onPersistChange != nil {
		m.onPersistChange(false)
	}
	return nil
}

// Logout logs out the embedded Tailscale node and clears local tsnet state so user can switch accounts.
func (m *Manager) Logout() error {
	m.mu.RLock()
	srv := m.tsSrv
	m.mu.RUnlock()

	if srv != nil {
		if lc, err := srv.LocalClient(); err == nil {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			_ = lc.Logout(ctx)
			cancel()
		}
	}
	m.stopRuntime(Status{
		Enabled:  false,
		State:    StateDisabled,
		Hostname: m.hostname,
		Message:  "已退出 Tailscale 账号，下次开启可重新授权登录",
	})
	if m.stateDir != "" {
		_ = os.RemoveAll(m.stateDir)
	}
	if m.onPersistChange != nil {
		m.onPersistChange(false)
	}
	return nil
}

// Close shuts down all embedded listeners cleanly without modifying persisted enabled config.
func (m *Manager) Close() {
	m.mu.Lock()
	m.closed = true
	m.mu.Unlock()
	m.stopRuntime(Status{
		Enabled:  false,
		State:    StateDisabled,
		Hostname: m.hostname,
	})
}

func (m *Manager) stopRuntime(nextStatus Status) {
	m.mu.Lock()
	cancel := m.cancel
	funnelSrv := m.funnelSrv
	tailnetSrv := m.tailnetSrv
	funnelLn := m.funnelLn
	tailnetLn := m.tailnetLn
	tsSrv := m.tsSrv

	m.cancel = nil
	m.funnelSrv = nil
	m.tailnetSrv = nil
	m.funnelLn = nil
	m.tailnetLn = nil
	m.tsSrv = nil
	m.retryFunnelCh = nil
	m.status = nextStatus
	m.mu.Unlock()

	if cancel != nil {
		cancel()
	}
	shutCtx, shutCancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer shutCancel()
	if funnelSrv != nil {
		_ = funnelSrv.Shutdown(shutCtx)
	}
	if tailnetSrv != nil {
		_ = tailnetSrv.Shutdown(shutCtx)
	}
	if funnelLn != nil {
		_ = funnelLn.Close()
	}
	if tailnetLn != nil {
		_ = tailnetLn.Close()
	}
	if tsSrv != nil {
		_ = tsSrv.Close()
	}
}

func (m *Manager) captureUserLog(format string, args ...any) {
	msg := fmt.Sprintf(format, args...)
	if strings.Contains(msg, "https://login.tailscale.com/") {
		if authURL := urlPattern.FindString(msg); authURL != "" {
			authURL = strings.TrimRight(authURL, ".,;)")
			m.mu.Lock()
			if m.tsSrv != nil && (m.status.State == StateStarting || m.status.State == StateNeedsLogin) {
				m.status.State = StateNeedsLogin
				m.status.AuthURL = authURL
				m.status.Message = "请在浏览器中完成授权登录（支持 GitHub / Google）"
			}
			m.mu.Unlock()
		}
	}
}

func (m *Manager) run(ctx context.Context, tsSrv *tsnet.Server, retryCh <-chan struct{}) {
	proxyURL := ensureSystemProxyForTsnet()

	if err := tsSrv.Start(); err != nil {
		m.setError(tsSrv, fmt.Sprintf("启动内置 Tailscale 失败：%v", err))
		return
	}
	lc, err := tsSrv.LocalClient()
	if err != nil {
		m.setError(tsSrv, fmt.Sprintf("连接 Tailscale LocalClient 失败：%v", err))
		return
	}

	watcher, err := lc.WatchIPNBus(ctx, ipn.NotifyInitialState)
	if err != nil {
		if ctx.Err() == nil {
			m.setError(tsSrv, fmt.Sprintf("监听 Tailscale 状态失败：%v", err))
		}
		return
	}
	defer watcher.Close()

	go m.pollAuthURL(ctx, tsSrv, lc, proxyURL)

	servingStarted := false

	for {
		n, err := watcher.Next()
		if err != nil {
			if ctx.Err() == nil {
				m.setError(tsSrv, fmt.Sprintf("Tailscale 状态通道断开：%v", err))
			}
			return
		}

		if n.BrowseToURL != nil && *n.BrowseToURL != "" {
			m.mu.Lock()
			if m.tsSrv == tsSrv {
				m.status.State = StateNeedsLogin
				m.status.AuthURL = *n.BrowseToURL
				m.status.Message = "请在浏览器中完成授权登录（支持 GitHub / Google）"
			}
			m.mu.Unlock()
		}

		if n.State == nil {
			continue
		}

		switch *n.State {
		case ipn.NeedsLogin:
			m.mu.Lock()
			if m.tsSrv == tsSrv {
				m.status.State = StateNeedsLogin
				if m.status.AuthURL == "" {
					m.status.Message = "正在向 Tailscale 控制面申请授权链接..."
				} else {
					m.status.Message = "请在浏览器中完成授权登录（支持 GitHub / Google）"
				}
			}
			m.mu.Unlock()

		case ipn.NeedsMachineAuth:
			m.mu.Lock()
			if m.tsSrv == tsSrv {
				m.status.State = StateNeedsLogin
				m.status.HelpURL = "https://login.tailscale.com/admin/machines"
				m.status.Message = "节点等待管理员在 Tailscale 后台批准"
			}
			m.mu.Unlock()

		case ipn.Running:
			if !servingStarted {
				servingStarted = true
				go m.startListenersLoop(ctx, tsSrv, lc, retryCh)
			}
		}
	}
}

func (m *Manager) pollAuthURL(ctx context.Context, tsSrv *tsnet.Server, lc *local.Client, proxyURL string) {
	startedAt := time.Now()
	retriedInteractive := false
	ticker := time.NewTicker(1500 * time.Millisecond)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			st, err := lc.StatusWithoutPeers(ctx)
			if err != nil || st == nil {
				continue
			}
			if st.BackendState == "Running" {
				return
			}
			if st.AuthURL != "" {
				m.mu.Lock()
				if m.tsSrv == tsSrv {
					m.status.State = StateNeedsLogin
					m.status.AuthURL = st.AuthURL
					m.status.Message = "请在浏览器中完成授权登录（支持 GitHub / Google）"
				}
				m.mu.Unlock()
				return
			}
			elapsed := time.Since(startedAt)
			if elapsed > 10*time.Second && !retriedInteractive && st.BackendState == "NeedsLogin" {
				retriedInteractive = true
				_ = lc.StartLoginInteractive(ctx)
			}
			if elapsed > 20*time.Second {
				hint := "无法连接 controlplane.tailscale.com，请检查网络或代理设置"
				if proxyURL != "" {
					hint = fmt.Sprintf("经系统代理 %s 连接 controlplane.tailscale.com 超时，请确认代理可用", proxyURL)
				}
				if len(st.Health) > 0 {
					hint = hint + "（" + strings.Join(st.Health, "; ") + "）"
				}
				m.mu.Lock()
				if m.tsSrv == tsSrv && m.status.AuthURL == "" && m.status.State == StateNeedsLogin {
					m.status.Message = hint
				}
				m.mu.Unlock()
			}
		}
	}
}

func (m *Manager) startListenersLoop(ctx context.Context, tsSrv *tsnet.Server, lc *local.Client, retryCh <-chan struct{}) {
	// 1. Start private Tailnet HTTP listener on bridge port (best-effort bonus for Tailscale-installed devices).
	tailnetURL := ""
	accountLogin := ""
	if st, err := lc.Status(ctx); err == nil && st != nil {
		if st.Self != nil {
			if u, ok := st.User[st.Self.UserID]; ok {
				accountLogin = u.LoginName
			}
		}
		for _, ip := range st.TailscaleIPs {
			if ip.Is4() {
				tailnetURL = fmt.Sprintf("http://%s:%s", ip.String(), m.port)
				break
			}
		}
	}
	if tailnetURL == "" {
		if ip4, _ := tsSrv.TailscaleIPs(); ip4.IsValid() {
			tailnetURL = fmt.Sprintf("http://%s:%s", ip4.String(), m.port)
		}
	}

	if ln, err := tsSrv.Listen("tcp", ":"+m.port); err == nil {
		srv := &http.Server{Handler: m.handler, ReadHeaderTimeout: 10 * time.Second}
		m.mu.Lock()
		if m.tsSrv == tsSrv {
			m.tailnetLn = ln
			m.tailnetSrv = srv
			m.status.TailnetURL = tailnetURL
			m.status.AccountLogin = accountLogin
			m.status.AuthURL = ""
		} else {
			_ = ln.Close()
		}
		m.mu.Unlock()
		go func() {
			_ = srv.Serve(ln)
		}()
	}

	// 2. Attempt Tailscale Funnel (:443 public HTTPS) and auto-retry every 15s if awaiting admin enablement.
	ticker := time.NewTicker(15 * time.Second)
	defer ticker.Stop()

	for {
		if m.tryStartFunnel(ctx, tsSrv, lc, tailnetURL, accountLogin) {
			return
		}
		select {
		case <-ctx.Done():
			return
		case <-retryCh:
		case <-ticker.C:
		}
	}
}

func (m *Manager) tryStartFunnel(ctx context.Context, tsSrv *tsnet.Server, lc *local.Client, tailnetURL, accountLogin string) bool {
	if ctx.Err() != nil {
		return true
	}
	ln, err := tsSrv.ListenFunnel("tcp", ":443")
	if err != nil {
		helpURL := ExtractHelpURL(err.Error())
		m.mu.Lock()
		if m.tsSrv == tsSrv {
			m.status.State = StateTailnetOnly
			m.status.AuthURL = ""
			m.status.TailnetURL = tailnetURL
			m.status.AccountLogin = accountLogin
			m.status.HelpURL = helpURL
			m.status.Message = fmt.Sprintf("已登录账号，但 Tailscale 后台尚未开启 HTTPS/Funnel（%v）", err)
		}
		m.mu.Unlock()
		return false
	}

	domain := ""
	if domains := tsSrv.CertDomains(); len(domains) > 0 {
		domain = strings.TrimSuffix(domains[0], ".")
	}
	if domain == "" {
		if st, err := lc.Status(ctx); err == nil && st != nil && st.Self != nil {
			domain = strings.TrimSuffix(st.Self.DNSName, ".")
		}
	}
	funnelURL := ""
	if domain != "" {
		funnelURL = "https://" + domain
	}

	srv := &http.Server{Handler: m.handler, ReadHeaderTimeout: 10 * time.Second}
	m.mu.Lock()
	if m.tsSrv != tsSrv {
		m.mu.Unlock()
		_ = ln.Close()
		return true
	}
	m.funnelLn = ln
	m.funnelSrv = srv
	m.status = Status{
		Enabled:      true,
		State:        StateRunning,
		Hostname:     m.hostname,
		FunnelURL:    funnelURL,
		TailnetURL:   tailnetURL,
		AccountLogin: accountLogin,
		Message:      "5G 公网 HTTPS 隧道已就绪（手机端零安装扫码直连）",
	}
	m.mu.Unlock()

	log.Printf("[agy-remote] Tailscale Funnel active at %s (tailnet=%s)", funnelURL, tailnetURL)
	go func() {
		if err := srv.Serve(ln); err != nil && err != http.ErrServerClosed {
			log.Printf("[agy-remote] Tailscale Funnel server stopped: %v", err)
		}
	}()
	return true
}

func (m *Manager) setError(tsSrv *tsnet.Server, msg string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.tsSrv != tsSrv {
		return
	}
	m.status.State = StateError
	m.status.Message = msg
}
