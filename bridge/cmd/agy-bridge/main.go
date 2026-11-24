package main

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/mdp/qrterminal/v3"

	"github.com/antigravity-mobile/bridge/internal/agyreader"
	"github.com/antigravity-mobile/bridge/internal/brainwatcher"
	"github.com/antigravity-mobile/bridge/internal/cmdrunner"
	"github.com/antigravity-mobile/bridge/internal/config"
	"github.com/antigravity-mobile/bridge/internal/hubserver"
	"github.com/antigravity-mobile/bridge/internal/mcpserver"
	"github.com/antigravity-mobile/bridge/internal/notifier"
	"github.com/antigravity-mobile/bridge/internal/quotamonitor"
	"github.com/antigravity-mobile/bridge/internal/sidecarui"
	"github.com/antigravity-mobile/bridge/internal/statestore"
)

func main() {
	if len(os.Args) < 2 {
		printUsage()
		os.Exit(1)
	}
	cmd := os.Args[1]
	fs := flag.NewFlagSet(cmd, flag.ExitOnError)
	cfgPath := fs.String("config", "", "path to config.json")
	listen := fs.String("listen", "", "override listen address (e.g. 0.0.0.0:8765)")
	_ = fs.Parse(os.Args[2:])

	resolvedCfgPath := *cfgPath
	if resolvedCfgPath == "" {
		resolvedCfgPath, _ = config.DefaultConfigPath()
	}

	cfg, err := config.LoadOrCreate(resolvedCfgPath)
	if err != nil {
		log.Fatalf("load config: %v", err)
	}
	if *listen != "" {
		cfg.ListenAddr = *listen
	}

	switch cmd {
	case "pair":
		printPairing(cfg)
	case "status":
		runStatus(cfg)
	case "serve":
		runServe(cfg, resolvedCfgPath, false)
	case "sidecar":
		runServe(cfg, resolvedCfgPath, true)
	case "mcp":
		if err := mcpserver.New(cfg).ServeStdio(context.Background(), os.Stdin, os.Stdout); err != nil {
			log.Fatalf("mcp server error: %v", err)
		}
	case "hook":
		event := ""
		if fs.NArg() > 0 {
			event = fs.Arg(0)
		}
		runHook(cfg, event)
	default:
		printUsage()
		os.Exit(1)
	}
}

func printUsage() {
	fmt.Println("Usage: agy-remote <serve|sidecar|mcp|hook|pair|status> [--config=path] [--listen=0.0.0.0:8765]")
}

func printPairing(cfg *config.Config) {
	payload := cfg.BuildPairingPayload(cfg.BootstrapToken)
	raw, _ := json.Marshal(payload)
	fmt.Printf("Host:      %s\n", payload.HostName)
	fmt.Printf("Endpoints: %v\n", payload.Endpoints)
	fmt.Printf("Token:     %s\n\n", payload.Token)
	fmt.Println("使用 Android App 扫描下方二维码配对：")
	qrterminal.GenerateHalfBlock(string(raw), qrterminal.L, os.Stdout)
	fmt.Printf("\n配对 JSON:\n%s\n", string(raw))
}

func runStatus(cfg *config.Config) {
	store, err := statestore.Open(cfg.StateDBPath)
	if err != nil {
		log.Fatalf("open state db: %v", err)
	}
	defer store.Close()

	reader := agyreader.New(filepath.Join(cfg.AntigravityDir, "conversation_summaries.db"))
	watcher := brainwatcher.New(filepath.Join(cfg.AntigravityDir, "brain"), store, brainwatcher.EventCallbacks{})
	_ = watcher.ScanAll()
	lsProv := quotamonitor.NewLanguageServerProvider(filepath.Join(cfg.AntigravityDir, "daemon"), store)
	quota, err := quotamonitor.NewMonitor(store, cfg.SubscriptionTier, cfg.Gemini5hBudget, cfg.Gemini7dBudget, cfg.Claude5hBudget, cfg.Claude7dBudget, lsProv)
	if err != nil {
		log.Fatalf("init quota: %v", err)
	}
	runner := cmdrunner.New(cfg.AgentAPIBin, filepath.Join(cfg.AntigravityDir, "daemon"))

	list, err := reader.ListRootSummaries(10)
	if err != nil {
		log.Fatalf("read summaries: %v", err)
	}
	snap, err := quota.Snapshot(context.Background())
	if err != nil {
		log.Fatalf("quota snapshot: %v", err)
	}

	out, _ := json.MarshalIndent(map[string]any{
		"hostName":       cfg.HostName,
		"endpoints":      config.DiscoverEndpoints(cfg.Port(), cfg.PublicEndpoints),
		"desktopOnline":  runner.IsDesktopOnline(),
		"recentCount":    len(list),
		"quota":          snap,
		"antigravityDir": cfg.AntigravityDir,
	}, "", "  ")
	fmt.Println(string(out))
}

func runServe(cfg *config.Config, cfgPath string, sidecarMode bool) {
	store, err := statestore.Open(cfg.StateDBPath)
	if err != nil {
		log.Fatalf("open state db: %v", err)
	}
	defer store.Close()

	_ = store.UpsertDevice("bootstrap", "Default Paired Device", config.HashToken(cfg.BootstrapToken))

	reader := agyreader.New(filepath.Join(cfg.AntigravityDir, "conversation_summaries.db"))
	lsProv := quotamonitor.NewLanguageServerProvider(filepath.Join(cfg.AntigravityDir, "daemon"), store)
	quota, err := quotamonitor.NewMonitor(store, cfg.SubscriptionTier, cfg.Gemini5hBudget, cfg.Gemini7dBudget, cfg.Claude5hBudget, cfg.Claude7dBudget, lsProv)
	if err != nil {
		log.Fatalf("init quota monitor: %v", err)
	}
	runner := cmdrunner.New(cfg.AgentAPIBin, filepath.Join(cfg.AntigravityDir, "daemon"))
	notif := notifier.NewManager(store)

	var srv *hubserver.Server
	watcher := brainwatcher.New(filepath.Join(cfg.AntigravityDir, "brain"), store, brainwatcher.EventCallbacks{
		OnStepsAppended: func(convID string, steps []brainwatcher.TranscriptStep, stats brainwatcher.ConversationStats) {
			if srv != nil {
				srv.OnStepsAppended(convID, steps, stats)
			}
		},
		OnArtifactChange: func(convID string) {
			if srv != nil {
				srv.OnArtifactChange(convID)
			}
		},
	})

	srv = hubserver.New(cfg, store, reader, watcher, quota, runner, notif)

	log.Printf("[agy-remote] scanning brain transcripts under %s", filepath.Join(cfg.AntigravityDir, "brain"))
	if err := watcher.ScanAll(); err != nil {
		log.Printf("[agy-remote] initial scan warning: %v", err)
	}
	if err := watcher.Start(); err != nil {
		log.Printf("[agy-remote] fs watcher warning: %v", err)
	}
	defer watcher.Stop()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	srv.StartStatePoller(ctx)

	httpSrv := &http.Server{
		Addr:              cfg.ListenAddr,
		Handler:           srv.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
	}

	errCh := make(chan error, 2)
	go func() {
		log.Printf("[agy-remote] mobile bridge listening on %s (desktopOnline=%v)", cfg.ListenAddr, runner.IsDesktopOnline())
		errCh <- httpSrv.ListenAndServe()
	}()

	var uiHTTP *http.Server
	if sidecarMode {
		webPort := strings.TrimSpace(os.Getenv("ANTIGRAVITY_SIDECAR_WEB_PORT"))
		if webPort == "" {
			webPort = strings.TrimSpace(os.Getenv("PORT"))
		}
		if webPort != "" {
			uiSrv := sidecarui.New(srv, cfgPath, os.Getenv("ANTIGRAVITY_SIDECAR_UI_TOKEN"))
			uiHTTP = &http.Server{
				Addr:              "127.0.0.1:" + webPort,
				Handler:           uiSrv.Handler(),
				ReadHeaderTimeout: 10 * time.Second,
			}
			go func() {
				fmt.Printf("[sidecar] listening on 127.0.0.1:%s\n", webPort)
				errCh <- uiHTTP.ListenAndServe()
			}()
		}
	} else {
		printPairing(cfg)
	}

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	select {
	case sig := <-sigCh:
		log.Printf("[agy-remote] received %v, shutting down...", sig)
		shutCtx, shutCancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer shutCancel()
		_ = httpSrv.Shutdown(shutCtx)
		if uiHTTP != nil {
			_ = uiHTTP.Shutdown(shutCtx)
		}
	case err := <-errCh:
		if err != nil && err != http.ErrServerClosed {
			log.Fatalf("[agy-remote] server error: %v", err)
		}
	}
}

// runHook handles Antigravity lifecycle hooks (Stop / PostToolUse) and forwards instant alerts to the local sidecar.
// Always prints `{}` and exits 0 quickly so it never blocks the agent execution loop.
func runHook(cfg *config.Config, event string) {
	defer fmt.Println("{}")

	raw, _ := io.ReadAll(io.LimitReader(os.Stdin, 512*1024))
	var input map[string]any
	_ = json.Unmarshal(raw, &input)

	convID, _ := input["conversationId"].(string)
	hookEvent := strings.ToLower(strings.TrimSpace(event))
	if hookEvent == "" {
		if hn, ok := input["hookEventName"].(string); ok {
			hookEvent = strings.ToLower(hn)
		}
	}

	payload := map[string]any{
		"conversationId": convID,
	}

	switch hookEvent {
	case "stop":
		reason, _ := input["terminationReason"].(string)
		if reason == "USER_CANCELED" {
			return
		}
		payload["event"] = "stop"
		payload["kind"] = "TASK_COMPLETED"
	case "post-tool-use", "posttooluse":
		tc, _ := input["toolCall"].(map[string]any)
		toolName, _ := tc["name"].(string)
		if toolName != "ask_question" {
			return
		}
		payload["event"] = "ask_question"
		payload["kind"] = "NEED_CONFIRM"
		payload["body"] = "Agent 发起了多选/决策提问，等待你的确认"
		payload["quickReplies"] = []string{"确认，按推荐方案继续", "稍等我看一下"}
	default:
		return
	}

	bodyBytes, _ := json.Marshal(payload)
	client := &http.Client{
		Timeout:   2 * time.Second,
		Transport: &http.Transport{Proxy: nil},
	}
	req, err := http.NewRequest(http.MethodPost, fmt.Sprintf("http://127.0.0.1:%s/internal/hook", cfg.Port()), bytes.NewReader(bodyBytes))
	if err != nil {
		return
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+cfg.BootstrapToken)
	if resp, err := client.Do(req); err == nil {
		_ = resp.Body.Close()
	}
}
