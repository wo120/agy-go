package statestore

import (
	"path/filepath"
	"testing"
	"time"
)

func TestStoreLifecycleAndLedger(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "bridge_state.db")
	st, err := Open(dbPath)
	if err != nil {
		t.Fatalf("Open failed: %v", err)
	}
	defer st.Close()

	if err := st.UpsertDevice("dev1", "Xiaomi 17 Pro", "hash_abc"); err != nil {
		t.Fatalf("UpsertDevice: %v", err)
	}
	ok, err := st.ValidateTokenHash("hash_abc")
	if err != nil || !ok {
		t.Fatalf("expected valid token, got ok=%v err=%v", ok, err)
	}
	ok, err = st.ValidateTokenHash("wrong")
	if err != nil || ok {
		t.Fatalf("expected invalid token, got ok=%v err=%v", ok, err)
	}

	if err := st.SetPinned("conv1", true, 1); err != nil {
		t.Fatalf("SetPinned: %v", err)
	}
	if err := st.MarkRead("conv1", 10); err != nil {
		t.Fatalf("MarkRead: %v", err)
	}
	// Monotonic check: smaller stepIndex must not regress last_read_step_index.
	if err := st.MarkRead("conv1", 5); err != nil {
		t.Fatalf("MarkRead smaller: %v", err)
	}
	metas, err := st.GetAllSessionMeta()
	if err != nil {
		t.Fatalf("GetAllSessionMeta: %v", err)
	}
	if !metas["conv1"].Pinned || metas["conv1"].LastReadStepIndex != 10 {
		t.Fatalf("unexpected meta: %+v", metas["conv1"])
	}

	now := time.Now().Unix()
	entries := []UsageEntry{
		{ConversationID: "conv1", StepIndex: 1, CreatedAtUnix: now - 100, PoolID: "gemini", Model: "gemini-4-neon-high", InputTokens: 1000, CacheReadTokens: 500, OutputTokens: 200},
		// Duplicate primary key should be ignored idempotently.
		{ConversationID: "conv1", StepIndex: 1, CreatedAtUnix: now - 100, PoolID: "gemini", Model: "gemini-4-neon-high", InputTokens: 9999, CacheReadTokens: 0, OutputTokens: 0},
	}
	if err := st.RecordUsageBatch(entries); err != nil {
		t.Fatalf("RecordUsageBatch: %v", err)
	}
	usage, err := st.QueryWindowUsage("gemini", now-3600)
	if err != nil {
		t.Fatalf("QueryWindowUsage: %v", err)
	}
	// cost = 1000 + 200*4 + 500/10 = 1850
	if usage.TotalCost != 1850 || usage.RequestCount != 1 || usage.OldestUnix != now-100 {
		t.Fatalf("unexpected usage: %+v", usage)
	}
}
