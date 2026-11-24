package statestore

import (
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"time"

	_ "modernc.org/sqlite"
)

// Store manages sidecar metadata in bridge_state.db without touching Antigravity's native DB.
type Store struct {
	db *sql.DB
}

// SessionMeta stores mobile-specific pin and unread cursor metadata.
type SessionMeta struct {
	ConversationID    string
	Pinned            bool
	PinnedOrder       int
	LastReadStepIndex int
	UpdatedAt         int64
}

// UsageEntry represents a single planner step's token consumption for quota windows.
type UsageEntry struct {
	ConversationID  string
	StepIndex       int
	CreatedAtUnix   int64
	PoolID          string // "gemini" | "claude_gpt"
	Model           string
	InputTokens     int64
	CacheReadTokens int64
	OutputTokens    int64
}

// WindowUsage holds aggregated usage within a sliding time window.
type WindowUsage struct {
	TotalCost      int64
	RequestCount   int
	OldestUnix     int64
	TotalInput     int64
	TotalCacheRead int64
	TotalOutput    int64
}

// QuotaConfig stores budget and manual calibration baselines for a model pool.
type QuotaConfig struct {
	PoolID            string
	Window5hBudget    int64
	Window7dBudget    int64
	CalibratedAtUnix  int64
	Calibrated5hPct   *float64
	Calibrated7dPct   *float64
	SubscriptionLabel string
}

// WebhookEndpoint configures optional external alert forwarding (ntfy/gotify/webhook).
type WebhookEndpoint struct {
	ID         string `json:"id"`
	Name       string `json:"name"`
	Kind       string `json:"kind"`
	URL        string `json:"url"`
	AuthHeader string `json:"authHeader,omitempty"`
	Enabled    bool   `json:"enabled"`
	CreatedAt  int64  `json:"createdAt"`
}

// Open opens or initializes bridge_state.db with WAL mode enabled.
func Open(dbPath string) (*Store, error) {
	if err := os.MkdirAll(filepath.Dir(dbPath), 0o700); err != nil {
		return nil, fmt.Errorf("create state db dir: %w", err)
	}
	dsn := fmt.Sprintf("file:%s?_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)&_pragma=foreign_keys(1)", dbPath)
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("open state db: %w", err)
	}
	db.SetMaxOpenConns(1)

	s := &Store{db: db}
	if err := s.migrate(); err != nil {
		_ = db.Close()
		return nil, err
	}
	return s, nil
}

// Close closes the underlying SQLite database.
func (s *Store) Close() error {
	return s.db.Close()
}

func (s *Store) migrate() error {
	const schema = `
CREATE TABLE IF NOT EXISTS paired_devices (
	device_id TEXT PRIMARY KEY,
	device_name TEXT NOT NULL,
	token_hash TEXT NOT NULL UNIQUE,
	created_at INTEGER NOT NULL,
	last_seen_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS session_meta (
	conversation_id TEXT PRIMARY KEY,
	pinned INTEGER NOT NULL DEFAULT 0,
	pinned_order INTEGER NOT NULL DEFAULT 0,
	last_read_step_index INTEGER NOT NULL DEFAULT -1,
	updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS usage_ledger (
	conversation_id TEXT NOT NULL,
	step_index INTEGER NOT NULL,
	created_at_unix INTEGER NOT NULL,
	pool_id TEXT NOT NULL,
	model TEXT NOT NULL,
	input_tokens INTEGER NOT NULL DEFAULT 0,
	cache_read_tokens INTEGER NOT NULL DEFAULT 0,
	output_tokens INTEGER NOT NULL DEFAULT 0,
	PRIMARY KEY (conversation_id, step_index)
);
CREATE INDEX IF NOT EXISTS idx_usage_ledger_pool_time ON usage_ledger(pool_id, created_at_unix);

CREATE TABLE IF NOT EXISTS quota_configs (
	pool_id TEXT PRIMARY KEY,
	window_5h_budget INTEGER NOT NULL,
	window_7d_budget INTEGER NOT NULL,
	calibrated_at_unix INTEGER NOT NULL DEFAULT 0,
	calibrated_5h_pct REAL,
	calibrated_7d_pct REAL,
	subscription_label TEXT NOT NULL DEFAULT 'Google AI Ultra'
);

CREATE TABLE IF NOT EXISTS watcher_offsets (
	conversation_id TEXT PRIMARY KEY,
	byte_offset INTEGER NOT NULL DEFAULT 0,
	last_mtime_ns INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS webhook_endpoints (
	id TEXT PRIMARY KEY,
	name TEXT NOT NULL,
	kind TEXT NOT NULL,
	url TEXT NOT NULL,
	auth_header TEXT NOT NULL DEFAULT '',
	enabled INTEGER NOT NULL DEFAULT 1,
	created_at INTEGER NOT NULL
);
`
	_, err := s.db.Exec(schema)
	return err
}

// UpsertDevice registers or refreshes an authorized device token hash.
func (s *Store) UpsertDevice(deviceID, deviceName, tokenHash string) error {
	now := time.Now().Unix()
	_, err := s.db.Exec(`
		INSERT INTO paired_devices(device_id, device_name, token_hash, created_at, last_seen_at)
		VALUES (?, ?, ?, ?, ?)
		ON CONFLICT(device_id) DO UPDATE SET
			device_name = excluded.device_name,
			token_hash = excluded.token_hash,
			last_seen_at = excluded.last_seen_at
	`, deviceID, deviceName, tokenHash, now, now)
	return err
}

// ValidateTokenHash checks whether tokenHash matches an authorized device and updates last_seen_at.
func (s *Store) ValidateTokenHash(tokenHash string) (bool, error) {
	var deviceID string
	err := s.db.QueryRow(`SELECT device_id FROM paired_devices WHERE token_hash = ?`, tokenHash).Scan(&deviceID)
	if err == sql.ErrNoRows {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	_, _ = s.db.Exec(`UPDATE paired_devices SET last_seen_at = ? WHERE device_id = ?`, time.Now().Unix(), deviceID)
	return true, nil
}

// GetAllSessionMeta returns all mobile session metadata keyed by conversation_id.
func (s *Store) GetAllSessionMeta() (map[string]SessionMeta, error) {
	rows, err := s.db.Query(`SELECT conversation_id, pinned, pinned_order, last_read_step_index, updated_at FROM session_meta`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	res := make(map[string]SessionMeta)
	for rows.Next() {
		var m SessionMeta
		var pinnedInt int
		if err := rows.Scan(&m.ConversationID, &pinnedInt, &m.PinnedOrder, &m.LastReadStepIndex, &m.UpdatedAt); err != nil {
			return nil, err
		}
		m.Pinned = pinnedInt != 0
		res[m.ConversationID] = m
	}
	return res, rows.Err()
}

// SetPinned sets pin state and order for a conversation.
func (s *Store) SetPinned(convID string, pinned bool, order int) error {
	p := 0
	if pinned {
		p = 1
	}
	now := time.Now().Unix()
	_, err := s.db.Exec(`
		INSERT INTO session_meta(conversation_id, pinned, pinned_order, last_read_step_index, updated_at)
		VALUES (?, ?, ?, -1, ?)
		ON CONFLICT(conversation_id) DO UPDATE SET
			pinned = excluded.pinned,
			pinned_order = excluded.pinned_order,
			updated_at = excluded.updated_at
	`, convID, p, order, now)
	return err
}

// MarkRead advances last_read_step_index monotonically for a conversation.
func (s *Store) MarkRead(convID string, stepIndex int) error {
	now := time.Now().Unix()
	_, err := s.db.Exec(`
		INSERT INTO session_meta(conversation_id, pinned, pinned_order, last_read_step_index, updated_at)
		VALUES (?, 0, 0, ?, ?)
		ON CONFLICT(conversation_id) DO UPDATE SET
			last_read_step_index = MAX(session_meta.last_read_step_index, excluded.last_read_step_index),
			updated_at = excluded.updated_at
	`, convID, stepIndex, now)
	return err
}

// RecordUsageBatch inserts usage ledger rows idempotently.
func (s *Store) RecordUsageBatch(entries []UsageEntry) error {
	if len(entries) == 0 {
		return nil
	}
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	stmt, err := tx.Prepare(`
		INSERT OR IGNORE INTO usage_ledger(
			conversation_id, step_index, created_at_unix, pool_id, model,
			input_tokens, cache_read_tokens, output_tokens
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
	`)
	if err != nil {
		return err
	}
	defer stmt.Close()

	for _, e := range entries {
		if _, err := stmt.Exec(
			e.ConversationID, e.StepIndex, e.CreatedAtUnix, e.PoolID, e.Model,
			e.InputTokens, e.CacheReadTokens, e.OutputTokens,
		); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// QueryWindowUsage aggregates effective token cost since sinceUnix for a model pool.
func (s *Store) QueryWindowUsage(poolID string, sinceUnix int64) (WindowUsage, error) {
	var u WindowUsage
	var oldest sql.NullInt64
	err := s.db.QueryRow(`
		SELECT
			COALESCE(SUM(input_tokens + output_tokens * 4 + cache_read_tokens / 10), 0),
			COUNT(*),
			MIN(created_at_unix),
			COALESCE(SUM(input_tokens), 0),
			COALESCE(SUM(cache_read_tokens), 0),
			COALESCE(SUM(output_tokens), 0)
		FROM usage_ledger
		WHERE pool_id = ? AND created_at_unix >= ?
	`, poolID, sinceUnix).Scan(
		&u.TotalCost, &u.RequestCount, &oldest,
		&u.TotalInput, &u.TotalCacheRead, &u.TotalOutput,
	)
	if err != nil {
		return u, err
	}
	if oldest.Valid {
		u.OldestUnix = oldest.Int64
	}
	return u, nil
}

// EnsureQuotaConfig inserts default budget config for a pool if absent.
func (s *Store) EnsureQuotaConfig(cfg QuotaConfig) error {
	_, err := s.db.Exec(`
		INSERT OR IGNORE INTO quota_configs(
			pool_id, window_5h_budget, window_7d_budget, calibrated_at_unix,
			calibrated_5h_pct, calibrated_7d_pct, subscription_label
		) VALUES (?, ?, ?, ?, ?, ?, ?)
	`, cfg.PoolID, cfg.Window5hBudget, cfg.Window7dBudget, cfg.CalibratedAtUnix,
		cfg.Calibrated5hPct, cfg.Calibrated7dPct, cfg.SubscriptionLabel)
	return err
}

// GetQuotaConfig returns budget and calibration config for a pool.
func (s *Store) GetQuotaConfig(poolID string) (*QuotaConfig, error) {
	var c QuotaConfig
	var p5, p7 sql.NullFloat64
	err := s.db.QueryRow(`
		SELECT pool_id, window_5h_budget, window_7d_budget, calibrated_at_unix,
		       calibrated_5h_pct, calibrated_7d_pct, subscription_label
		FROM quota_configs WHERE pool_id = ?
	`, poolID).Scan(
		&c.PoolID, &c.Window5hBudget, &c.Window7dBudget, &c.CalibratedAtUnix,
		&p5, &p7, &c.SubscriptionLabel,
	)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if p5.Valid {
		v := p5.Float64
		c.Calibrated5hPct = &v
	}
	if p7.Valid {
		v := p7.Float64
		c.Calibrated7dPct = &v
	}
	return &c, nil
}

// SaveQuotaConfig upserts budget and calibration values for a pool.
func (s *Store) SaveQuotaConfig(cfg QuotaConfig) error {
	_, err := s.db.Exec(`
		INSERT INTO quota_configs(
			pool_id, window_5h_budget, window_7d_budget, calibrated_at_unix,
			calibrated_5h_pct, calibrated_7d_pct, subscription_label
		) VALUES (?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(pool_id) DO UPDATE SET
			window_5h_budget = excluded.window_5h_budget,
			window_7d_budget = excluded.window_7d_budget,
			calibrated_at_unix = excluded.calibrated_at_unix,
			calibrated_5h_pct = excluded.calibrated_5h_pct,
			calibrated_7d_pct = excluded.calibrated_7d_pct,
			subscription_label = excluded.subscription_label
	`, cfg.PoolID, cfg.Window5hBudget, cfg.Window7dBudget, cfg.CalibratedAtUnix,
		cfg.Calibrated5hPct, cfg.Calibrated7dPct, cfg.SubscriptionLabel)
	return err
}

// GetWatcherOffset retrieves the stored transcript tail byte offset for a conversation.
func (s *Store) GetWatcherOffset(convID string) (int64, int64, error) {
	var offset, mtime int64
	err := s.db.QueryRow(`SELECT byte_offset, last_mtime_ns FROM watcher_offsets WHERE conversation_id = ?`, convID).Scan(&offset, &mtime)
	if err == sql.ErrNoRows {
		return 0, 0, nil
	}
	return offset, mtime, err
}

// SetWatcherOffset saves the latest scanned byte offset for a conversation.
func (s *Store) SetWatcherOffset(convID string, offset, mtimeNs int64) error {
	_, err := s.db.Exec(`
		INSERT INTO watcher_offsets(conversation_id, byte_offset, last_mtime_ns)
		VALUES (?, ?, ?)
		ON CONFLICT(conversation_id) DO UPDATE SET
			byte_offset = excluded.byte_offset,
			last_mtime_ns = excluded.last_mtime_ns
	`, convID, offset, mtimeNs)
	return err
}

// UpsertWebhook inserts or updates an external alert webhook endpoint.
func (s *Store) UpsertWebhook(ep WebhookEndpoint) error {
	en := 0
	if ep.Enabled {
		en = 1
	}
	if ep.CreatedAt == 0 {
		ep.CreatedAt = time.Now().Unix()
	}
	_, err := s.db.Exec(`
		INSERT INTO webhook_endpoints(id, name, kind, url, auth_header, enabled, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(id) DO UPDATE SET
			name = excluded.name,
			kind = excluded.kind,
			url = excluded.url,
			auth_header = excluded.auth_header,
			enabled = excluded.enabled
	`, ep.ID, ep.Name, ep.Kind, ep.URL, ep.AuthHeader, en, ep.CreatedAt)
	return err
}

// ListEnabledWebhooks returns active external push webhook configurations.
func (s *Store) ListEnabledWebhooks() ([]WebhookEndpoint, error) {
	rows, err := s.db.Query(`SELECT id, name, kind, url, auth_header, enabled, created_at FROM webhook_endpoints WHERE enabled = 1`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var list []WebhookEndpoint
	for rows.Next() {
		var w WebhookEndpoint
		var en int
		if err := rows.Scan(&w.ID, &w.Name, &w.Kind, &w.URL, &w.AuthHeader, &en, &w.CreatedAt); err != nil {
			return nil, err
		}
		w.Enabled = en != 0
		list = append(list, w)
	}
	return list, rows.Err()
}
