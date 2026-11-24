package notifier

import (
	"bytes"
	"encoding/json"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/antigravity-mobile/bridge/internal/statestore"
)

// Alert represents a high-priority notification pushed to Android & optional webhooks.
type Alert struct {
	AlertID        string   `json:"alertId"`
	Kind           string   `json:"kind"` // "NEED_CONFIRM" | "TASK_COMPLETED"
	ConversationID string   `json:"conversationId"`
	Title          string   `json:"title"`
	Workspace      string   `json:"workspace"`
	Body           string   `json:"body"`
	QuickReplies   []string `json:"quickReplies,omitempty"`
	CreatedAt      int64    `json:"createdAt"`
}

// Manager stores recent alerts in memory and dispatches enabled external webhooks asynchronously.
type Manager struct {
	store  *statestore.Store
	client *http.Client

	mu     sync.RWMutex
	recent []Alert
}

// NewManager creates an alert manager backed by statestore webhook configs.
func NewManager(store *statestore.Store) *Manager {
	return &Manager{
		store:  store,
		client: &http.Client{Timeout: 8 * time.Second},
	}
}

// Publish records an alert into recent history and triggers optional webhook delivery.
func (m *Manager) Publish(alert Alert) {
	if alert.CreatedAt == 0 {
		alert.CreatedAt = time.Now().Unix()
	}

	m.mu.Lock()
	m.recent = append([]Alert{alert}, m.recent...)
	if len(m.recent) > 100 {
		m.recent = m.recent[:100]
	}
	m.mu.Unlock()

	if m.store != nil {
		go m.forwardWebhooks(alert)
	}
}

// Recent returns the latest alerts for the mobile notification center.
func (m *Manager) Recent(limit int) []Alert {
	m.mu.RLock()
	defer m.mu.RUnlock()
	if limit <= 0 || limit > len(m.recent) {
		limit = len(m.recent)
	}
	out := make([]Alert, limit)
	copy(out, m.recent[:limit])
	return out
}

func (m *Manager) forwardWebhooks(alert Alert) {
	endpoints, err := m.store.ListEnabledWebhooks()
	if err != nil || len(endpoints) == 0 {
		return
	}
	for _, ep := range endpoints {
		switch strings.ToLower(ep.Kind) {
		case "ntfy":
			req, err := http.NewRequest(http.MethodPost, ep.URL, strings.NewReader(alert.Body))
			if err != nil {
				continue
			}
			req.Header.Set("Title", alert.Title)
			req.Header.Set("Priority", "high")
			if ep.AuthHeader != "" {
				req.Header.Set("Authorization", ep.AuthHeader)
			}
			if resp, err := m.client.Do(req); err == nil {
				_ = resp.Body.Close()
			}
		default:
			raw, _ := json.Marshal(alert)
			req, err := http.NewRequest(http.MethodPost, ep.URL, bytes.NewReader(raw))
			if err != nil {
				continue
			}
			req.Header.Set("Content-Type", "application/json")
			if ep.AuthHeader != "" {
				req.Header.Set("Authorization", ep.AuthHeader)
			}
			if resp, err := m.client.Do(req); err == nil {
				_ = resp.Body.Close()
			}
		}
	}
}
