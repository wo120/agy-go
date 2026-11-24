package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/mdp/qrterminal/v3"

	"github.com/antigravity-mobile/bridge/internal/agyreader"
	"github.com/antigravity-mobile/bridge/internal/brainwatcher"
	"github.com/antigravity-mobile/bridge/internal/cmdrunner"
	"github.com/antigravity-mobile/bridge/internal/config"
	"github.com/antigravity-mobile/bridge/internal/hubserver"
	"github.com/antigravity-mobile/bridge/internal/notifier"
	"github.com/antigravity-mobile/bridge/internal/quotamonitor"
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

	cfg, err := config.LoadOrCreate(*cfgPath)
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
		runServe(cfg)
	default:
		printUsage()
		os.Exit(1)
	}
}

func printUsage() {
	fmt.Println("Usage: agy-bridge <serve|pair|status> [--config=path] [--listen=0.0.0.0:8765]")
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
	quota, err := quotamonitor.NewMonitor(store, cfg.SubscriptionTier, cfg.Gemini5hBudget, cfg.Gemini7dBudget, cfg.Claude5hBudget, cfg.Claude7dBudget)
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
		"hostName":         cfg.HostName,
		"endpoints":        config.DiscoverEndpoints(cfg.Port(), cfg.PublicEndpoints),
		"desktopOnline":    runner.IsDesktopOnline(),
		"recentCount":      len(list),
		"quota":            snap,
		"antigravityDir":   cfg.AntigravityDir,
	}, "", "  ")
	fmt.Println(string(out))
}

func runServe(cfg *config.Config) {
	store, err := statestore.Open(cfg.StateDBPath)
	if err != nil {
		log.Fatalf("open state db: %v", err)
	}
	defer store.Close()

	// Ensure bootstrap token is also indexed in paired_devices.
	_ = store.UpsertDevice("bootstrap", "Default Paired Device", config.HashToken(cfg.BootstrapToken))

	reader := agyreader.New(filepath.Join(cfg.AntigravityDir, "conversation_summaries.db"))
	quota, err := quotamonitor.NewMonitor(store, cfg.SubscriptionTier, cfg.Gemini5hBudget, cfg.Gemini7dBudget, cfg.Claude5hBudget, cfg.Claude7dBudget)
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

	log.Printf("scanning existing brain transcripts under %s ...", filepath.Join(cfg.AntigravityDir, "brain"))
	if err := watcher.ScanAll(); err != nil {
		log.Printf("initial scan warning: %v", err)
	}
	if err := watcher.Start(); err != nil {
		log.Printf("fs watcher start warning: %v", err)
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

	log.Printf("agy-bridge listening on %s (desktopOnline=%v)", cfg.ListenAddr, runner.IsDesktopOnline())
	printPairing(cfg)

	errCh := make(chan error, 1)
	go func() {
		errCh <- httpSrv.ListenAndServe()
	}()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	select {
	case sig := <-sigCh:
		log.Printf("received %v, shutting down...", sig)
		shutCtx, shutCancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer shutCancel()
		_ = httpSrv.Shutdown(shutCtx)
	case err := <-errCh:
		if err != nil && err != http.ErrServerClosed {
			log.Fatalf("server error: %v", err)
		}
	}
}
