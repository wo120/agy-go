package notifier

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/antigravity-mobile/bridge/internal/statestore"
)

func TestManagerPublishHistoryAndWebhookForwarding(t *testing.T) {
	st, err := statestore.Open(filepath.Join(t.TempDir(), "state.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	var mu sync.Mutex
	var ntfyTitle, ntfyBody, ntfyAuth string
	var jsonAlert Alert
	doneCh := make(chan struct{}, 2)

	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		mu.Lock()
		defer mu.Unlock()
		switch r.URL.Path {
		case "/ntfy":
			ntfyTitle = r.Header.Get("Title")
			ntfyAuth = r.Header.Get("Authorization")
			ntfyBody = string(body)
			doneCh <- struct{}{}
		case "/webhook":
			_ = json.Unmarshal(body, &jsonAlert)
			doneCh <- struct{}{}
		}
		w.WriteHeader(http.StatusOK)
	}))
	defer ts.Close()

	if err := st.UpsertWebhook(statestore.WebhookEndpoint{
		ID: "w1", Name: "MyNtfy", Kind: "ntfy", URL: ts.URL + "/ntfy", AuthHeader: "Bearer ntfy_tok", Enabled: true,
	}); err != nil {
		t.Fatal(err)
	}
	if err := st.UpsertWebhook(statestore.WebhookEndpoint{
		ID: "w2", Name: "Generic", Kind: "webhook", URL: ts.URL + "/webhook", Enabled: true,
	}); err != nil {
		t.Fatal(err)
	}
	if err := st.UpsertWebhook(statestore.WebhookEndpoint{
		ID: "w3", Name: "Disabled", Kind: "webhook", URL: ts.URL + "/disabled", Enabled: false,
	}); err != nil {
		t.Fatal(err)
	}

	mgr := NewManager(st)
	mgr.client = &http.Client{Timeout: 3 * time.Second, Transport: &http.Transport{Proxy: nil}}

	mgr.Publish(Alert{
		AlertID:        "a1",
		Kind:           "NEED_CONFIRM",
		ConversationID: "conv-42",
		Title:          "AGY Go",
		Body:           "确认直接开工？",
	})

	for i := 0; i < 2; i++ {
		select {
		case <-doneCh:
		case <-time.After(3 * time.Second):
			t.Fatal("timed out waiting for webhook deliveries")
		}
	}

	recent := mgr.Recent(10)
	if len(recent) != 1 || recent[0].AlertID != "a1" {
		t.Fatalf("unexpected recent alerts: %+v", recent)
	}

	mu.Lock()
	defer mu.Unlock()
	if ntfyTitle != "AGY Go" || ntfyBody != "确认直接开工？" || ntfyAuth != "Bearer ntfy_tok" {
		t.Fatalf("unexpected ntfy delivery: title=%q body=%q auth=%q", ntfyTitle, ntfyBody, ntfyAuth)
	}
	if jsonAlert.AlertID != "a1" || jsonAlert.ConversationID != "conv-42" {
		t.Fatalf("unexpected json webhook alert: %+v", jsonAlert)
	}
}
