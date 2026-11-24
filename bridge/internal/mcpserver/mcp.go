package mcpserver

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"path/filepath"
	"strings"
	"time"

	"github.com/antigravity-mobile/bridge/internal/agyreader"
	"github.com/antigravity-mobile/bridge/internal/brainwatcher"
	"github.com/antigravity-mobile/bridge/internal/cmdrunner"
	"github.com/antigravity-mobile/bridge/internal/config"
	"github.com/antigravity-mobile/bridge/internal/quotamonitor"
	"github.com/antigravity-mobile/bridge/internal/statestore"
)

type rpcReq struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      any             `json:"id,omitempty"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type rpcResp struct {
	JSONRPC string    `json:"jsonrpc"`
	ID      any       `json:"id,omitempty"`
	Result  any       `json:"result,omitempty"`
	Error   *rpcError `json:"error,omitempty"`
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

// Server implements a lightweight stdio MCP server for the agy-remote Antigravity plugin.
type Server struct {
	cfg        *config.Config
	httpClient *http.Client
}

// New creates a new stdio MCP server using the shared agy-remote configuration.
func New(cfg *config.Config) *Server {
	return &Server{
		cfg: cfg,
		httpClient: &http.Client{
			Timeout:   5 * time.Second,
			Transport: &http.Transport{Proxy: nil}, // Always bypass system proxy for local loopback.
		},
	}
}

// ServeStdio processes line-delimited JSON-RPC 2.0 MCP frames from in to out.
func (s *Server) ServeStdio(ctx context.Context, in io.Reader, out io.Writer) error {
	scanner := bufio.NewScanner(in)
	scanner.Buffer(make([]byte, 64*1024), 4*1024*1024)
	enc := json.NewEncoder(out)

	for scanner.Scan() {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}
		line := bytes.TrimSpace(scanner.Bytes())
		if len(line) == 0 {
			continue
		}
		var req rpcReq
		if err := json.Unmarshal(line, &req); err != nil {
			continue
		}
		resp := s.handle(ctx, req)
		if resp != nil {
			if err := enc.Encode(resp); err != nil {
				return err
			}
		}
	}
	return scanner.Err()
}

func (s *Server) handle(ctx context.Context, req rpcReq) *rpcResp {
	switch req.Method {
	case "initialize":
		return &rpcResp{
			JSONRPC: "2.0",
			ID:      req.ID,
			Result: map[string]any{
				"protocolVersion": "2024-11-05",
				"capabilities":    map[string]any{"tools": map[string]any{}},
				"serverInfo":      map[string]any{"name": "agy-remote", "version": "0.2.0"},
			},
		}
	case "notifications/initialized":
		return nil
	case "ping":
		return &rpcResp{JSONRPC: "2.0", ID: req.ID, Result: map[string]any{}}
	case "tools/list":
		return &rpcResp{
			JSONRPC: "2.0",
			ID:      req.ID,
			Result:  map[string]any{"tools": toolDefinitions()},
		}
	case "tools/call":
		var p struct {
			Name      string         `json:"name"`
			Arguments map[string]any `json:"arguments"`
		}
		if err := json.Unmarshal(req.Params, &p); err != nil {
			return &rpcResp{JSONRPC: "2.0", ID: req.ID, Error: &rpcError{Code: -32602, Message: "invalid params"}}
		}
		text, isErr := s.callTool(ctx, p.Name, p.Arguments)
		return &rpcResp{
			JSONRPC: "2.0",
			ID:      req.ID,
			Result: map[string]any{
				"content": []map[string]any{{"type": "text", "text": text}},
				"isError": isErr,
			},
		}
	default:
		if req.ID == nil {
			return nil
		}
		return &rpcResp{
			JSONRPC: "2.0",
			ID:      req.ID,
			Error:   &rpcError{Code: -32601, Message: "method not found: " + req.Method},
		}
	}
}

func toolDefinitions() []map[string]any {
	return []map[string]any{
		{
			"name":        "agy_remote_status",
			"description": "Check agy-remote bridge status, LAN/Tailscale direct endpoints, desktop runtime health, connected mobile clients, and 5h/7d model quota snapshot.",
			"inputSchema": map[string]any{"type": "object", "properties": map[string]any{}},
		},
		{
			"name":        "agy_remote_pairing_info",
			"description": "Return the mobile pairing endpoints and QR pairing instructions for connecting the Android Levity app to this Mac.",
			"inputSchema": map[string]any{"type": "object", "properties": map[string]any{}},
		},
		{
			"name":        "agy_remote_notify_mobile",
			"description": "Send an immediate high-priority push alert to connected Android devices (e.g. morning briefing, task completion, or decision confirmation with quick reply buttons).",
			"inputSchema": map[string]any{
				"type": "object",
				"properties": map[string]any{
					"title":          map[string]any{"type": "string", "description": "Short alert title"},
					"body":           map[string]any{"type": "string", "description": "Notification body text"},
					"conversationId": map[string]any{"type": "string", "description": "Optional conversation ID to deep-link into"},
					"kind":           map[string]any{"type": "string", "enum": []string{"NEED_CONFIRM", "TASK_COMPLETED"}},
					"quickReplies":   map[string]any{"type": "array", "items": map[string]any{"type": "string"}, "description": "Up to 2 quick-reply action labels"},
				},
				"required": []string{"body"},
			},
		},
	}
}

func (s *Server) callTool(ctx context.Context, name string, args map[string]any) (string, bool) {
	switch name {
	case "agy_remote_status":
		return s.toolStatus(ctx)
	case "agy_remote_pairing_info":
		payload := s.cfg.BuildPairingPayload(s.cfg.BootstrapToken)
		raw, _ := json.MarshalIndent(payload, "", "  ")
		return fmt.Sprintf("主机：%s\n可用端点：%v\n\n可在 Antigravity 右侧边栏打开 agy-remote 面板直接扫码，或粘贴以下配对 JSON：\n%s", payload.HostName, payload.Endpoints, string(raw)), false
	case "agy_remote_notify_mobile":
		return s.toolNotifyMobile(args)
	default:
		return "unknown tool: " + name, true
	}
}

func (s *Server) toolStatus(ctx context.Context) (string, bool) {
	bridgeAlive := false
	port := s.cfg.Port()
	if resp, err := s.httpClient.Get(fmt.Sprintf("http://127.0.0.1:%s/api/v1/health", port)); err == nil {
		bridgeAlive = resp.StatusCode == http.StatusOK
		_ = resp.Body.Close()
	}

	st, err := statestore.Open(s.cfg.StateDBPath)
	if err != nil {
		return fmt.Sprintf("bridgeRunning=%v, failed to open state db: %v", bridgeAlive, err), true
	}
	defer st.Close()

	watcher := brainwatcher.New(filepath.Join(s.cfg.AntigravityDir, "brain"), st, brainwatcher.EventCallbacks{})
	_ = watcher.ScanAll()
	quota, _ := quotamonitor.NewMonitor(st, s.cfg.SubscriptionTier, s.cfg.Gemini5hBudget, s.cfg.Gemini7dBudget, s.cfg.Claude5hBudget, s.cfg.Claude7dBudget)
	snap, _ := quota.Snapshot(ctx)
	reader := agyreader.New(filepath.Join(s.cfg.AntigravityDir, "conversation_summaries.db"))
	recent, _ := reader.ListRootSummaries(5)
	runner := cmdrunner.New(s.cfg.AgentAPIBin, filepath.Join(s.cfg.AntigravityDir, "daemon"))

	out, _ := json.MarshalIndent(map[string]any{
		"bridgeRunning": bridgeAlive,
		"hostName":      s.cfg.HostName,
		"listenAddr":    s.cfg.ListenAddr,
		"endpoints":     config.DiscoverEndpoints(port, s.cfg.PublicEndpoints),
		"desktopOnline": runner.IsDesktopOnline(),
		"recentCount":   len(recent),
		"quota":         snap,
	}, "", "  ")
	return string(out), false
}

func (s *Server) toolNotifyMobile(args map[string]any) (string, bool) {
	bodyText, _ := args["body"].(string)
	if strings.TrimSpace(bodyText) == "" {
		return "body is required", true
	}
	title, _ := args["title"].(string)
	convID, _ := args["conversationId"].(string)
	kind, _ := args["kind"].(string)
	var quickReplies []string
	if rawQR, ok := args["quickReplies"].([]any); ok {
		for _, item := range rawQR {
			if str, ok := item.(string); ok && strings.TrimSpace(str) != "" {
				quickReplies = append(quickReplies, str)
			}
		}
	}

	payload, _ := json.Marshal(map[string]any{
		"event":          "notify",
		"title":          title,
		"body":           bodyText,
		"conversationId": convID,
		"kind":           kind,
		"quickReplies":   quickReplies,
	})

	url := fmt.Sprintf("http://127.0.0.1:%s/internal/hook", s.cfg.Port())
	req, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(payload))
	if err != nil {
		return err.Error(), true
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+s.cfg.BootstrapToken)

	resp, err := s.httpClient.Do(req)
	if err != nil {
		return fmt.Sprintf("agy-remote sidecar 未运行，无法推送通知 (%v)。请确认已启用 agy-remote 插件。", err), true
	}
	defer resp.Body.Close()
	respBytes, _ := io.ReadAll(resp.Body)
	return string(respBytes), resp.StatusCode != http.StatusOK
}
