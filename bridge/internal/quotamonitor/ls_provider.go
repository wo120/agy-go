package quotamonitor

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/antigravity-mobile/bridge/internal/procutil"
	"github.com/antigravity-mobile/bridge/internal/statestore"
)

type weeklyAnchor struct {
	pct5h    int
	budget7d int64
}

// LanguageServerProvider reads authoritative subscription tier and live model pool quotas
// directly from the local Antigravity LanguageServerService GetUserStatus RPC.
type LanguageServerProvider struct {
	daemonDir string
	store     *statestore.Store
	client    *http.Client

	mu           sync.Mutex
	cached       *QuotaSnapshot
	cachedAt     time.Time
	cacheTTL     time.Duration
	weeklyAnchor map[string]weeklyAnchor
	pidAlive     func(int) bool
	envLookup    func(string) string
}

// NewLanguageServerProvider constructs a direct Antigravity Language Server quota collector.
func NewLanguageServerProvider(daemonDir string, store *statestore.Store) *LanguageServerProvider {
	return &LanguageServerProvider{
		daemonDir: daemonDir,
		store:     store,
		client: &http.Client{
			Timeout:   4 * time.Second,
			Transport: &http.Transport{Proxy: nil}, // Always bypass system proxy for local loopback.
		},
		cacheTTL:     5 * time.Second,
		weeklyAnchor: make(map[string]weeklyAnchor),
		pidAlive:     procutil.IsPIDAlive,
		envLookup:    os.Getenv,
	}
}

type getUserStatusResp struct {
	UserStatus struct {
		UserTier struct {
			ID   string `json:"id"`
			Name string `json:"name"`
		} `json:"userTier"`
		PlanStatus struct {
			PlanInfo struct {
				PlanName string `json:"planName"`
			} `json:"planInfo"`
		} `json:"planStatus"`
		CascadeModelConfigData struct {
			DefaultOverrideModelConfig struct {
				ModelOrAlias struct {
					Model string `json:"model"`
				} `json:"modelOrAlias"`
			} `json:"defaultOverrideModelConfig"`
			ClientModelConfigs []struct {
				Label        string `json:"label"`
				ModelID      string `json:"modelId"`
				TagTitle     string `json:"tagTitle"`
				ModelOrAlias struct {
					Model string `json:"model"`
				} `json:"modelOrAlias"`
				QuotaInfo *struct {
					RemainingFraction float64 `json:"remainingFraction"`
					ResetTime         string  `json:"resetTime"`
				} `json:"quotaInfo"`
			} `json:"clientModelConfigs"`
		} `json:"cascadeModelConfigData"`
	} `json:"userStatus"`
}

type retrieveQuotaSummaryResp struct {
	Response struct {
		Groups []struct {
			DisplayName string `json:"displayName"`
			Description string `json:"description"`
			Buckets     []struct {
				BucketID          string  `json:"bucketId"`
				DisplayName       string  `json:"displayName"`
				Window            string  `json:"window"` // "weekly" | "5h"
				RemainingFraction float64 `json:"remainingFraction"`
				ResetTime         string  `json:"resetTime"`
			} `json:"buckets"`
		} `json:"groups"`
	} `json:"response"`
}

// Fetch retrieves live subscription tier and real Gemini / Claude·GPT quota pools from Antigravity LS.
func (p *LanguageServerProvider) Fetch(ctx context.Context, now time.Time) (*QuotaSnapshot, error) {
	p.mu.Lock()
	if p.cached != nil && now.Sub(p.cachedAt) < p.cacheTTL {
		snap := *p.cached
		p.mu.Unlock()
		return &snap, nil
	}
	p.mu.Unlock()

	addr, csrf, err := p.discoverEndpoint()
	if err != nil {
		return nil, err
	}

	url := fmt.Sprintf("http://%s/exa.language_server_pb.LanguageServerService/GetUserStatus", addr)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader([]byte("{}")))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	if csrf != "" {
		req.Header.Set("x-codeium-csrf-token", csrf)
	}

	resp, err := p.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("GetUserStatus HTTP %d", resp.StatusCode)
	}

	var raw getUserStatusResp
	if err := json.NewDecoder(resp.Body).Decode(&raw); err != nil {
		return nil, err
	}

	summary, _ := p.fetchQuotaSummary(ctx, addr, csrf)

	snap := p.buildSnapshot(&raw, summary, now)
	if len(snap.Pools) == 0 {
		return nil, errors.New("no quota pools returned by GetUserStatus")
	}

	p.mu.Lock()
	p.cached = snap
	p.cachedAt = now
	p.mu.Unlock()
	return snap, nil
}

func (p *LanguageServerProvider) fetchQuotaSummary(ctx context.Context, addr, csrf string) (*retrieveQuotaSummaryResp, error) {
	url := fmt.Sprintf("http://%s/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary", addr)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader([]byte("{}")))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Connect-Protocol-Version", "1")
	if csrf != "" {
		req.Header.Set("x-codeium-csrf-token", csrf)
	}
	resp, err := p.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("RetrieveUserQuotaSummary HTTP %d", resp.StatusCode)
	}
	var out retrieveQuotaSummaryResp
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, err
	}
	if len(out.Response.Groups) == 0 {
		return nil, errors.New("empty quota summary groups")
	}
	return &out, nil
}

// InvalidateCache clears the short TTL cache (e.g. after manual calibration or refresh).
func (p *LanguageServerProvider) InvalidateCache() {
	p.mu.Lock()
	p.cached = nil
	p.mu.Unlock()
}

func (p *LanguageServerProvider) buildSnapshot(raw *getUserStatusResp, summary *retrieveQuotaSummaryResp, now time.Time) *QuotaSnapshot {
	tier := strings.TrimSpace(raw.UserStatus.UserTier.Name)
	if tier == "" {
		tier = strings.TrimSpace(raw.UserStatus.PlanStatus.PlanInfo.PlanName)
	}
	if tier == "" {
		tier = "Google AI"
	}

	type agg struct {
		seen    bool
		minFrac float64
		resetAt *int64
	}
	buckets := map[string]*agg{
		"gemini":     {minFrac: 2.0},
		"claude_gpt": {minFrac: 2.0},
	}

	defaultModelRef := strings.TrimSpace(raw.UserStatus.CascadeModelConfigData.DefaultOverrideModelConfig.ModelOrAlias.Model)
	seenModels := make(map[string]struct{})
	models := make([]ModelOption, 0, len(raw.UserStatus.CascadeModelConfigData.ClientModelConfigs))

	for _, mc := range raw.UserStatus.CascadeModelConfigData.ClientModelConfigs {
		poolID := classifyConfigPool(mc.ModelID, mc.Label)
		modelID := strings.TrimSpace(mc.ModelID)
		if modelID != "" {
			if _, dup := seenModels[modelID]; !dup {
				seenModels[modelID] = struct{}{}
				label := strings.TrimSpace(mc.Label)
				if label == "" {
					label = modelID
				}
				models = append(models, ModelOption{
					ModelID:   modelID,
					Label:     label,
					PoolID:    poolID,
					Tag:       strings.TrimSpace(mc.TagTitle),
					IsDefault: defaultModelRef != "" && strings.TrimSpace(mc.ModelOrAlias.Model) == defaultModelRef,
				})
			}
		}

		if mc.QuotaInfo == nil {
			continue
		}
		b := buckets[poolID]
		frac := clampFloat(mc.QuotaInfo.RemainingFraction, 0, 1)
		var resetPtr *int64
		if mc.QuotaInfo.ResetTime != "" {
			if t, err := time.Parse(time.RFC3339Nano, mc.QuotaInfo.ResetTime); err == nil {
				u := t.Unix()
				resetPtr = &u
			} else if t, err := time.Parse(time.RFC3339, mc.QuotaInfo.ResetTime); err == nil {
				u := t.Unix()
				resetPtr = &u
			}
		}

		if !b.seen || frac < b.minFrac {
			b.seen = true
			b.minFrac = frac
			b.resetAt = resetPtr
		}
	}

	defs := []struct {
		id   string
		name string
	}{
		{id: "gemini", name: "Gemini"},
		{id: "claude_gpt", name: "Claude · GPT"},
	}

	nowUnix := now.Unix()
	if summaryPools := buildPoolsFromQuotaSummary(summary); len(summaryPools) > 0 {
		return &QuotaSnapshot{
			SubscriptionTier: tier,
			UpdatedAt:        nowUnix,
			Pools:            summaryPools,
			Models:           models,
		}
	}

	pools := make([]PoolQuota, 0, len(defs))
	for _, d := range defs {
		b := buckets[d.id]
		if !b.seen {
			continue
		}
		pct := int(math.Round(b.minFrac * 100.0))
		if pct > 100 {
			pct = 100
		}
		if pct < 0 {
			pct = 0
		}

		// Determine whether the authoritative resetTime belongs to the 5h window (<= 6h) or 7d window (> 6h).
		isWeeklyReset := b.resetAt != nil && (*b.resetAt-nowUnix) > 6*3600

		var rem5, rem7 int
		var reset5, reset7 *int64

		if isWeeklyReset {
			// Weekly quota window is the binding ceiling reported by Antigravity.
			rem7 = pct
			if pct < 100 {
				reset7 = b.resetAt
			}
			rem5 = pct
			if pct < 100 {
				reset5 = b.resetAt
			}
		} else {
			// Standard 5h rolling window directly from Antigravity.
			rem5 = pct
			if pct < 100 {
				reset5 = b.resetAt
			}
			// Estimate 7d rolling window anchored to real 5h consumption ratio when ledger is available.
			rem7, reset7 = p.estimateWeeklyFromDirect5h(d.id, rem5, nowUnix)
		}

		pools = append(pools, PoolQuota{
			PoolID:         d.id,
			DisplayName:    d.name,
			Remaining5hPct: rem5,
			Reset5hAt:      reset5,
			Remaining7dPct: rem7,
			Reset7dAt:      reset7,
			Level:          classifyLevel(rem5, rem7),
			Source:         "direct",
		})
	}

	return &QuotaSnapshot{
		SubscriptionTier: tier,
		UpdatedAt:        nowUnix,
		Pools:            pools,
		Models:           models,
	}
}

func parseResetTimestamp(raw string) *int64 {
	s := strings.TrimSpace(raw)
	if s == "" {
		return nil
	}
	if t, err := time.Parse(time.RFC3339Nano, s); err == nil {
		u := t.Unix()
		return &u
	}
	if t, err := time.Parse(time.RFC3339, s); err == nil {
		u := t.Unix()
		return &u
	}
	return nil
}

func buildPoolsFromQuotaSummary(summary *retrieveQuotaSummaryResp) []PoolQuota {
	if summary == nil || len(summary.Response.Groups) == 0 {
		return nil
	}

	type windowState struct {
		seen    bool
		frac    float64
		pct     int
		resetAt *int64
	}
	type poolState struct {
		w5 windowState
		w7 windowState
	}

	parsed := map[string]*poolState{
		"gemini":     {},
		"claude_gpt": {},
	}

	for _, g := range summary.Response.Groups {
		poolID := classifyConfigPool(g.DisplayName, g.Description)
		for _, b := range g.Buckets {
			bid := strings.ToLower(strings.TrimSpace(b.BucketID))
			if strings.HasPrefix(bid, "3p-") || strings.Contains(bid, "claude") || strings.Contains(bid, "gpt") {
				poolID = "claude_gpt"
			} else if strings.HasPrefix(bid, "gemini-") {
				poolID = "gemini"
			}
			ps := parsed[poolID]
			if ps == nil {
				continue
			}

			frac := clampFloat(b.RemainingFraction, 0, 1)
			pct := int(math.Round(frac * 100.0))
			if pct > 100 {
				pct = 100
			}
			if pct < 0 {
				pct = 0
			}
			var resetPtr *int64
			if frac < 1.0 {
				resetPtr = parseResetTimestamp(b.ResetTime)
			}

			win := strings.ToLower(strings.TrimSpace(b.Window))
			isWeekly := win == "weekly" || strings.Contains(bid, "weekly") || strings.Contains(bid, "7d")
			is5h := win == "5h" || strings.Contains(bid, "5h")

			if isWeekly {
				ps.w7 = windowState{seen: true, frac: frac, pct: pct, resetAt: resetPtr}
			} else if is5h {
				ps.w5 = windowState{seen: true, frac: frac, pct: pct, resetAt: resetPtr}
			}
		}
	}

	defs := []struct {
		id   string
		name string
	}{
		{id: "gemini", name: "Gemini"},
		{id: "claude_gpt", name: "Claude · GPT"},
	}

	out := make([]PoolQuota, 0, len(defs))
	for _, d := range defs {
		ps := parsed[d.id]
		if !ps.w5.seen && !ps.w7.seen {
			continue
		}
		rem5, reset5 := ps.w5.pct, ps.w5.resetAt
		rem7, reset7 := ps.w7.pct, ps.w7.resetAt
		if !ps.w5.seen {
			rem5, reset5 = rem7, reset7
		}
		if !ps.w7.seen {
			rem7, reset7 = rem5, reset5
		}
		out = append(out, PoolQuota{
			PoolID:         d.id,
			DisplayName:    d.name,
			Remaining5hPct: rem5,
			Reset5hAt:      reset5,
			Remaining7dPct: rem7,
			Reset7dAt:      reset7,
			Level:          classifyLevel(rem5, rem7),
			Source:         "direct",
		})
	}
	return out
}

func (p *LanguageServerProvider) estimateWeeklyFromDirect5h(poolID string, real5hPct int, nowUnix int64) (int, *int64) {
	if p.store == nil {
		return real5hPct, nil
	}
	u5, err5 := p.store.QueryWindowUsage(poolID, nowUnix-Window5hSeconds)
	u7, err7 := p.store.QueryWindowUsage(poolID, nowUnix-Window7dSeconds)
	if err5 != nil || err7 != nil || u7.TotalCost <= 0 || u7.RequestCount == 0 {
		if real5hPct >= 100 {
			return 100, nil
		}
		return real5hPct, nil
	}

	cfg, _ := p.store.GetQuotaConfig(poolID)
	budget7d := int64(50_000_000)
	if cfg != nil && cfg.Window7dBudget > 0 {
		budget7d = cfg.Window7dBudget
	}
	// If the user has not manually calibrated 7d, anchor 7d budget proportionally (~7x of implied 5h budget)
	// whenever real 5h shows measurable usage. Keep the anchored budget stable while real5hPct stays flat
	// between Antigravity LS server syncs so remaining7dPct does not artificially bounce upward as usage grows.
	if (cfg == nil || cfg.Calibrated7dPct == nil) && u5.TotalCost > 0 && real5hPct < 98 && real5hPct > 0 {
		p.mu.Lock()
		prev, hasPrev := p.weeklyAnchor[poolID]
		if hasPrev && prev.pct5h == real5hPct && prev.budget7d > 0 {
			budget7d = prev.budget7d
		} else {
			used5Ratio := float64(100-real5hPct) / 100.0
			implied5hBudget := float64(u5.TotalCost) / used5Ratio
			anchored7d := int64(math.Round(implied5hBudget * 7.0))
			if anchored7d > 0 {
				budget7d = anchored7d
				if p.weeklyAnchor == nil {
					p.weeklyAnchor = make(map[string]weeklyAnchor)
				}
				p.weeklyAnchor[poolID] = weeklyAnchor{pct5h: real5hPct, budget7d: anchored7d}
			}
		}
		p.mu.Unlock()
	}

	return calcWindow(u7, budget7d, Window7dSeconds)
}

func classifyConfigPool(modelID, label string) string {
	s := strings.ToLower(modelID + " " + label)
	if strings.Contains(s, "claude") || strings.Contains(s, "gpt") || strings.Contains(s, "opus") || strings.Contains(s, "sonnet") {
		return "claude_gpt"
	}
	return "gemini"
}

type daemonHubFile struct {
	PID       int    `json:"pid"`
	HTTPPort  int    `json:"httpPort"`
	HTTPSPort int    `json:"httpsPort"`
	CSRFToken string `json:"csrfToken"`
}

func (p *LanguageServerProvider) discoverEndpoint() (string, string, error) {
	if addr := strings.TrimSpace(p.envLookup("ANTIGRAVITY_LS_ADDRESS")); addr != "" {
		return addr, strings.TrimSpace(p.envLookup("ANTIGRAVITY_CSRF_TOKEN")), nil
	}
	if p.daemonDir == "" {
		return "", "", errors.New("antigravity daemon dir not configured")
	}

	matches, err := filepath.Glob(filepath.Join(p.daemonDir, "hub_*.json"))
	if err != nil || len(matches) == 0 {
		return "", "", errors.New("no live antigravity hub metadata found")
	}

	var bestAddr, bestCSRF string
	var bestMtime int64
	for _, path := range matches {
		fi, err := os.Stat(path)
		if err != nil {
			continue
		}
		raw, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		var meta daemonHubFile
		if err := json.Unmarshal(raw, &meta); err != nil || meta.PID <= 0 {
			continue
		}
		if !p.pidAlive(meta.PID) {
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
		return "", "", errors.New("antigravity language server not running")
	}
	return bestAddr, bestCSRF, nil
}
