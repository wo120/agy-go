package config

import (
	"net"
	"path/filepath"
	"strings"
	"testing"
)

func TestLoadOrCreateAndToken(t *testing.T) {
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "config.json")

	cfg, err := LoadOrCreate(cfgPath)
	if err != nil {
		t.Fatalf("LoadOrCreate failed: %v", err)
	}
	if !strings.HasPrefix(cfg.BootstrapToken, "agy_live_") {
		t.Fatalf("unexpected token prefix: %s", cfg.BootstrapToken)
	}
	if cfg.Port() != "8765" {
		t.Fatalf("expected port 8765, got %s", cfg.Port())
	}

	// Reloading should preserve generated token.
	cfg2, err := LoadOrCreate(cfgPath)
	if err != nil {
		t.Fatalf("second LoadOrCreate failed: %v", err)
	}
	if cfg2.BootstrapToken != cfg.BootstrapToken {
		t.Fatalf("token changed across reloads")
	}
}

func TestIPClassification(t *testing.T) {
	if !IsTailscaleIP(net.ParseIP("100.101.102.103")) {
		t.Fatal("expected 100.101.102.103 to be Tailscale IP")
	}
	if IsTailscaleIP(net.ParseIP("100.63.1.1")) {
		t.Fatal("expected 100.63.1.1 not to be Tailscale IP")
	}
	if !IsPrivateLANIP(net.ParseIP("192.168.1.50")) {
		t.Fatal("expected 192.168.1.50 to be private LAN IP")
	}
	if IsPrivateLANIP(net.ParseIP("8.8.8.8")) {
		t.Fatal("expected 8.8.8.8 not to be private LAN IP")
	}
}
