package tsfunnel

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestPublicHandlerBlocksInternalEndpoints(t *testing.T) {
	inner := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok:" + r.URL.Path))
	})
	h := PublicHandler(inner)

	blockedPaths := []string{"/internal/hook", "/internal", "/internal/debug"}
	for _, p := range blockedPaths {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, p, nil))
		if rec.Code != http.StatusNotFound {
			t.Fatalf("expected 404 for %s, got %d", p, rec.Code)
		}
	}

	allowedPaths := []string{"/api/v1/health", "/api/v1/rpc", "/api/v1/mux"}
	for _, p := range allowedPaths {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, p, nil))
		if rec.Code != http.StatusOK {
			t.Fatalf("expected 200 for %s, got %d", p, rec.Code)
		}
	}
}

func TestSanitizeHostname(t *testing.T) {
	cases := map[string]string{
		"MacBook-Pro.local": "agy-macbook-pro",
		"SBY_PC 01":         "agy-sby-pc-01",
		"agy-already":       "agy-already",
		"中文主机":              "agy-host",
		"":                  "agy-host",
	}
	for in, want := range cases {
		if got := SanitizeHostname(in); got != want {
			t.Fatalf("SanitizeHostname(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestExtractHelpURL(t *testing.T) {
	errWithLink := "Funnel not enabled; visit https://login.tailscale.com/f/funnel?node=abc123 to enable."
	if got := ExtractHelpURL(errWithLink); got != "https://login.tailscale.com/f/funnel?node=abc123" {
		t.Fatalf("unexpected extracted URL: %q", got)
	}
	if got := ExtractHelpURL("ACL policy denies funnel"); got != "https://login.tailscale.com/admin/acls" {
		t.Fatalf("expected ACL fallback URL, got %q", got)
	}
	if got := ExtractHelpURL("HTTPS certs disabled"); got != "https://login.tailscale.com/admin/dns" {
		t.Fatalf("expected DNS fallback URL, got %q", got)
	}
}
