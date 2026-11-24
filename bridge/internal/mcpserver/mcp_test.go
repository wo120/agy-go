package mcpserver

import (
	"bytes"
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/antigravity-mobile/bridge/internal/config"
)

func TestMCPInitializeAndToolsList(t *testing.T) {
	cfg := &config.Config{
		HostName:       "ClawStation",
		ListenAddr:     "0.0.0.0:8765",
		BootstrapToken: "agy_live_test",
	}
	srv := New(cfg)

	input := strings.Join([]string{
		`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}`,
		`{"jsonrpc":"2.0","id":2,"method":"tools/list"}`,
		`{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"agy_remote_pairing_info","arguments":{}}}`,
	}, "\n") + "\n"

	var out bytes.Buffer
	if err := srv.ServeStdio(context.Background(), strings.NewReader(input), &out); err != nil {
		t.Fatalf("ServeStdio: %v", err)
	}

	lines := strings.Split(strings.TrimSpace(out.String()), "\n")
	if len(lines) != 3 {
		t.Fatalf("expected 3 JSON-RPC responses, got %d: %s", len(lines), out.String())
	}

	var r2 map[string]any
	if err := json.Unmarshal([]byte(lines[1]), &r2); err != nil {
		t.Fatal(err)
	}
	result := r2["result"].(map[string]any)
	tools := result["tools"].([]any)
	if len(tools) != 3 {
		t.Fatalf("expected 3 tools, got %d", len(tools))
	}
	if !strings.Contains(lines[2], "ClawStation") {
		t.Fatalf("expected pairing info response to include hostName, got %s", lines[2])
	}
}
