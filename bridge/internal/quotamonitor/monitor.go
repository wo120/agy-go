package quotamonitor

import (
	"context"
	"math"
	"time"

	"github.com/antigravity-mobile/bridge/internal/statestore"
)

const (
	Window5hSeconds int64 = 5 * 3600
	Window7dSeconds int64 = 7 * 24 * 3600
)

// ModelOption represents a concrete model exposed by the local Antigravity LanguageServer.
type ModelOption struct {
	ModelID   string `json:"modelId"`
	Label     string `json:"label"`
	PoolID    string `json:"poolId"`              // "gemini" | "claude_gpt"
	Tag       string `json:"tag,omitempty"`       // e.g. "New" | "Leaving Soon" | "Notice"
	IsDefault bool   `json:"isDefault,omitempty"` // matches desktop defaultOverrideModelConfig
}

// QuotaSnapshot is returned to mobile clients for the collapsible quota dashboard.
type QuotaSnapshot struct {
	SubscriptionTier string        `json:"subscriptionTier"`
	UpdatedAt        int64         `json:"updatedAt"`
	Pools            []PoolQuota   `json:"pools"`
	Models           []ModelOption `json:"models,omitempty"`
}

// PoolQuota represents 5h and 7d rolling quota state for a model family.
type PoolQuota struct {
	PoolID         string `json:"poolId"`         // "gemini" | "claude_gpt"
	DisplayName    string `json:"displayName"`    // "Gemini" | "Claude · GPT"
	Remaining5hPct int    `json:"remaining5hPct"` // 0..100
	Reset5hAt      *int64 `json:"reset5hAt"`      // nil when 100% full
	Remaining7dPct int    `json:"remaining7dPct"` // 0..100
	Reset7dAt      *int64 `json:"reset7dAt"`      // nil when 100% full
	Level          string `json:"level"`          // "full" | "normal" | "warning"
	Source         string `json:"source"`         // "direct" | "ledger" | "gateway"
}

// CalibrationInput lets a user align the local sliding-window estimate to real desktop percentages.
type CalibrationInput struct {
	PoolID           string   `json:"poolId"`
	Remaining5hPct   *float64 `json:"remaining5hPct,omitempty"`
	Remaining7dPct   *float64 `json:"remaining7dPct,omitempty"`
	SubscriptionTier string   `json:"subscriptionTier,omitempty"`
}

// QuotaProvider abstracts direct/gateway quota collectors vs local ledger estimators.
type QuotaProvider interface {
	Fetch(ctx context.Context, now time.Time) (*QuotaSnapshot, error)
}

// Monitor evaluates pluggable providers in priority order with local ledger fallback.
type Monitor struct {
	store     *statestore.Store
	providers []QuotaProvider
	nowFn     func() time.Time
}

// NewMonitor initializes default pool budgets and returns a pluggable quota monitor.
func NewMonitor(store *statestore.Store, subTier string, gem5h, gem7d, claude5h, claude7d int64, extraProviders ...QuotaProvider) (*Monitor, error) {
	if subTier == "" {
		subTier = "Google AI Ultra"
	}
	defaults := []statestore.QuotaConfig{
		{PoolID: "gemini", Window5hBudget: gem5h, Window7dBudget: gem7d, SubscriptionLabel: subTier},
		{PoolID: "claude_gpt", Window5hBudget: claude5h, Window7dBudget: claude7d, SubscriptionLabel: subTier},
	}
	for _, d := range defaults {
		if err := store.EnsureQuotaConfig(d); err != nil {
			return nil, err
		}
	}
	return &Monitor{
		store:     store,
		providers: extraProviders,
		nowFn:     time.Now,
	}, nil
}

// Snapshot computes the latest QuotaSnapshot via priority providers or local ledger fallback.
func (m *Monitor) Snapshot(ctx context.Context) (*QuotaSnapshot, error) {
	now := m.nowFn()
	for _, p := range m.providers {
		if snap, err := p.Fetch(ctx, now); err == nil && snap != nil && len(snap.Pools) > 0 {
			return snap, nil
		}
	}
	return m.computeFromLedger(now)
}

// Calibrate back-calculates pool budgets so the local sliding window aligns with the user's real percentage.
func (m *Monitor) Calibrate(ctx context.Context, in CalibrationInput) (*QuotaSnapshot, error) {
	now := m.nowFn()
	cfg, err := m.store.GetQuotaConfig(in.PoolID)
	if err != nil {
		return nil, err
	}
	if cfg == nil {
		cfg = &statestore.QuotaConfig{
			PoolID:            in.PoolID,
			Window5hBudget:    5_000_000,
			Window7dBudget:    50_000_000,
			SubscriptionLabel: "Google AI Ultra",
		}
	}

	if in.SubscriptionTier != "" {
		cfg.SubscriptionLabel = in.SubscriptionTier
	}

	if in.Remaining5hPct != nil {
		pct := clampFloat(*in.Remaining5hPct, 0, 100)
		cfg.Calibrated5hPct = &pct
		if u5, err := m.store.QueryWindowUsage(in.PoolID, now.Unix()-Window5hSeconds); err == nil && u5.TotalCost > 0 && pct < 100 {
			usedRatio := (100.0 - pct) / 100.0
			if usedRatio > 0.01 {
				cfg.Window5hBudget = int64(math.Round(float64(u5.TotalCost) / usedRatio))
			}
		}
	}

	if in.Remaining7dPct != nil {
		pct := clampFloat(*in.Remaining7dPct, 0, 100)
		cfg.Calibrated7dPct = &pct
		if u7, err := m.store.QueryWindowUsage(in.PoolID, now.Unix()-Window7dSeconds); err == nil && u7.TotalCost > 0 && pct < 100 {
			usedRatio := (100.0 - pct) / 100.0
			if usedRatio > 0.01 {
				cfg.Window7dBudget = int64(math.Round(float64(u7.TotalCost) / usedRatio))
			}
		}
	}

	cfg.CalibratedAtUnix = now.Unix()
	if err := m.store.SaveQuotaConfig(*cfg); err != nil {
		return nil, err
	}
	return m.Snapshot(ctx)
}

func (m *Monitor) computeFromLedger(now time.Time) (*QuotaSnapshot, error) {
	nowUnix := now.Unix()
	poolsDef := []struct {
		id   string
		name string
	}{
		{id: "gemini", name: "Gemini"},
		{id: "claude_gpt", name: "Claude · GPT"},
	}

	subTier := "Google AI Ultra"
	pools := make([]PoolQuota, 0, len(poolsDef))
	for _, pd := range poolsDef {
		cfg, err := m.store.GetQuotaConfig(pd.id)
		if err != nil {
			return nil, err
		}
		if cfg != nil && cfg.SubscriptionLabel != "" && pd.id == "gemini" {
			subTier = cfg.SubscriptionLabel
		}
		b5 := int64(5_000_000)
		b7 := int64(50_000_000)
		if cfg != nil {
			if cfg.Window5hBudget > 0 {
				b5 = cfg.Window5hBudget
			}
			if cfg.Window7dBudget > 0 {
				b7 = cfg.Window7dBudget
			}
		}

		u5, err := m.store.QueryWindowUsage(pd.id, nowUnix-Window5hSeconds)
		if err != nil {
			return nil, err
		}
		u7, err := m.store.QueryWindowUsage(pd.id, nowUnix-Window7dSeconds)
		if err != nil {
			return nil, err
		}

		rem5, reset5 := calcWindow(u5, b5, Window5hSeconds)
		rem7, reset7 := calcWindow(u7, b7, Window7dSeconds)

		pools = append(pools, PoolQuota{
			PoolID:         pd.id,
			DisplayName:    pd.name,
			Remaining5hPct: rem5,
			Reset5hAt:      reset5,
			Remaining7dPct: rem7,
			Reset7dAt:      reset7,
			Level:          classifyLevel(rem5, rem7),
			Source:         "ledger",
		})
	}

	return &QuotaSnapshot{
		SubscriptionTier: subTier,
		UpdatedAt:        nowUnix,
		Pools:            pools,
	}, nil
}

func calcWindow(u statestore.WindowUsage, budget, windowSec int64) (int, *int64) {
	if u.TotalCost <= 0 || u.RequestCount == 0 {
		return 100, nil
	}
	if budget <= 0 {
		budget = 1
	}
	raw := (1.0 - float64(u.TotalCost)/float64(budget)) * 100.0
	pct := int(math.Round(clampFloat(raw, 0, 99)))
	resetAt := u.OldestUnix + windowSec
	return pct, &resetAt
}

func classifyLevel(rem5, rem7 int) string {
	minPct := rem5
	if rem7 < minPct {
		minPct = rem7
	}
	if minPct >= 100 {
		return "full"
	}
	if minPct < 40 {
		return "warning"
	}
	return "normal"
}

func clampFloat(v, minV, maxV float64) float64 {
	if v < minV {
		return minV
	}
	if v > maxV {
		return maxV
	}
	return v
}
