package cmdrunner

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/antigravity-mobile/bridge/internal/procutil"
)

var (
	ErrDesktopOffline = errors.New("antigravity desktop daemon is not running")
	ErrBinaryMissing  = errors.New("antigravity agentapi binary not found")
)

// DaemonHubMeta represents public endpoint metadata in daemon/hub_*.json.
type DaemonHubMeta struct {
	PID       int    `json:"pid"`
	HTTPSPort int    `json:"httpsPort"`
	HTTPPort  int    `json:"httpPort"`
	LSVersion string `json:"lsVersion"`
	CSRFToken string `json:"csrfToken"`
}

// NewConversationOptions configures official `agentapi new-conversation`.
type NewConversationOptions struct {
	Prompt        string `json:"prompt"`
	Title         string `json:"title,omitempty"`
	Model         string `json:"model,omitempty"`
	Profile       string `json:"profile,omitempty"`
	WorkspacePath string `json:"workspacePath,omitempty"`
}

// CommandResult captures stdout and parsed metadata returned by agentapi.
type CommandResult struct {
	ConversationID string `json:"conversationId,omitempty"`
	RawOutput      string `json:"rawOutput,omitempty"`
}

// CommandExecutor abstracts command invocation for unit testing.
type CommandExecutor interface {
	Run(ctx context.Context, bin string, args []string, env []string, workDir string) ([]byte, error)
}

type osExecutor struct{}

func (osExecutor) Run(ctx context.Context, bin string, args []string, env []string, workDir string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, bin, args...)
	cmd.Env = append(os.Environ(), env...)
	if workDir != "" {
		cmd.Dir = workDir
	}
	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &out
	err := cmd.Run()
	return out.Bytes(), err
}

// Runner invokes Antigravity's official bin/agentapi CLI and local LanguageServerService.
type Runner struct {
	agentAPIBin string
	daemonDir   string
	exec        CommandExecutor
	httpClient  *http.Client
	pidAliveFn  func(int) bool
}

// New creates a Runner for Antigravity's official agentapi binary and local LS RPC client.
func New(agentAPIBin, daemonDir string) *Runner {
	return &Runner{
		agentAPIBin: agentAPIBin,
		daemonDir:   daemonDir,
		exec:        osExecutor{},
		httpClient: &http.Client{
			Timeout:   25 * time.Second,
			Transport: &http.Transport{Proxy: nil},
		},
		pidAliveFn: procutil.IsPIDAlive,
	}
}

// IsDesktopOnline reports whether a live Antigravity local language_server hub exists.
func (r *Runner) IsDesktopOnline() bool {
	_, _, err := r.discoverEndpoint()
	return err == nil
}

func (r *Runner) resolveAgentAPICmd(subArgs []string) (string, []string, error) {
	if exe := strings.TrimSpace(os.Getenv("ANTIGRAVITY_AGENTAPI_EXE")); exe != "" {
		if _, err := os.Stat(exe); err == nil {
			return exe, append([]string{"agentapi"}, subArgs...), nil
		}
	}
	if _, err := os.Stat(r.agentAPIBin); err == nil {
		return r.agentAPIBin, subArgs, nil
	}
	if runtime.GOOS == "windows" && !strings.HasSuffix(strings.ToLower(r.agentAPIBin), ".exe") {
		exePath := r.agentAPIBin + ".exe"
		if _, err := os.Stat(exePath); err == nil {
			return exePath, subArgs, nil
		}
	}
	return "", nil, ErrBinaryMissing
}

// NewConversation creates a new Antigravity conversation via official `agentapi new-conversation`.
func (r *Runner) NewConversation(ctx context.Context, opts NewConversationOptions) (*CommandResult, error) {
	prompt := strings.TrimSpace(opts.Prompt)
	if prompt == "" {
		return nil, errors.New("prompt is required")
	}
	addr, csrf, err := r.discoverEndpoint()
	if err != nil {
		return nil, err
	}

	args := []string{"new-conversation"}
	if opts.Model != "" {
		args = append(args, "--model="+opts.Model)
	}
	if opts.Title != "" {
		args = append(args, "--title="+opts.Title)
	}
	if opts.Profile != "" {
		args = append(args, "--profile="+opts.Profile)
	}
	args = append(args, prompt)

	bin, execArgs, err := r.resolveAgentAPICmd(args)
	if err != nil {
		return nil, err
	}

	runCtx, cancel := context.WithTimeout(ctx, 25*time.Second)
	defer cancel()

	env := []string{"ANTIGRAVITY_LS_ADDRESS=" + addr}
	if csrf != "" {
		env = append(env, "ANTIGRAVITY_CSRF_TOKEN="+csrf)
	}
	out, err := r.exec.Run(runCtx, bin, execArgs, env, opts.WorkspacePath)
	raw := strings.TrimSpace(string(out))
	if err != nil {
		return nil, fmt.Errorf("agentapi new-conversation failed: %s (%w)", raw, err)
	}

	res := &CommandResult{RawOutput: raw}
	var parsed map[string]any
	if json.Unmarshal(out, &parsed) == nil {
		if cid, ok := parsed["conversation_id"].(string); ok {
			res.ConversationID = cid
		} else if cid, ok := parsed["conversationId"].(string); ok {
			res.ConversationID = cid
		} else if respMap, ok := parsed["response"].(map[string]any); ok {
			if nc, ok := respMap["newConversation"].(map[string]any); ok {
				if cid, ok := nc["conversationId"].(string); ok {
					res.ConversationID = cid
				}
			}
		}
	}
	return res, nil
}

// SendMessage delivers a user reply/decision to an existing conversation via LanguageServerService/SendUserCascadeMessage.
// Using SendUserCascadeMessage (instead of `agentapi send-message`, which emits a <SYSTEM_MESSAGE>) records a true USER_INPUT turn.
func (r *Runner) SendMessage(ctx context.Context, conversationID, content string) (*CommandResult, error) {
	conversationID = strings.TrimSpace(conversationID)
	content = strings.TrimSpace(content)
	if conversationID == "" || content == "" {
		return nil, errors.New("conversationId and content are required")
	}
	addr, csrf, err := r.discoverEndpoint()
	if err != nil {
		return nil, err
	}

	baseURL := addr
	if !strings.HasPrefix(baseURL, "http://") && !strings.HasPrefix(baseURL, "https://") {
		baseURL = "http://" + baseURL
	}
	endpoint := strings.TrimRight(baseURL, "/") + "/exa.language_server_pb.LanguageServerService/SendUserCascadeMessage"

	payload, err := json.Marshal(map[string]any{
		"cascadeId": conversationID,
		"items": []map[string]string{
			{"text": content},
		},
	})
	if err != nil {
		return nil, err
	}

	runCtx, cancel := context.WithTimeout(ctx, 25*time.Second)
	defer cancel()

	req, err := http.NewRequestWithContext(runCtx, http.MethodPost, endpoint, bytes.NewReader(payload))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Connect-Protocol-Version", "1")
	if csrf != "" {
		req.Header.Set("x-codeium-csrf-token", csrf)
	}

	client := r.httpClient
	if client == nil {
		client = &http.Client{
			Timeout:   25 * time.Second,
			Transport: &http.Transport{Proxy: nil},
		}
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("SendUserCascadeMessage request failed: %w", err)
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	raw := strings.TrimSpace(string(body))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("SendUserCascadeMessage HTTP %d: %s", resp.StatusCode, raw)
	}
	return &CommandResult{ConversationID: conversationID, RawOutput: raw}, nil
}

func (r *Runner) discoverEndpoint() (string, string, error) {
	if envAddr := strings.TrimSpace(os.Getenv("ANTIGRAVITY_LS_ADDRESS")); envAddr != "" {
		return envAddr, strings.TrimSpace(os.Getenv("ANTIGRAVITY_CSRF_TOKEN")), nil
	}
	matches, err := filepath.Glob(filepath.Join(r.daemonDir, "hub_*.json"))
	if err != nil || len(matches) == 0 {
		return "", "", ErrDesktopOffline
	}

	var bestAddr, bestCSRF string
	var bestMtime int64
	for _, p := range matches {
		fi, err := os.Stat(p)
		if err != nil {
			continue
		}
		data, err := os.ReadFile(p)
		if err != nil {
			continue
		}
		var meta DaemonHubMeta
		if err := json.Unmarshal(data, &meta); err != nil || meta.PID <= 0 {
			continue
		}
		if !r.pidAliveFn(meta.PID) {
			continue
		}
		port := meta.HTTPPort
		if port <= 0 {
			port = meta.HTTPSPort
		}
		if port <= 0 {
			continue
		}
		if fi.ModTime().UnixNano() >= bestMtime {
			bestMtime = fi.ModTime().UnixNano()
			bestAddr = fmt.Sprintf("127.0.0.1:%d", port)
			bestCSRF = meta.CSRFToken
		}
	}
	if bestAddr == "" {
		return "", "", ErrDesktopOffline
	}
	return bestAddr, bestCSRF, nil
}
