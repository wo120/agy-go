package quotamonitor

import (
	"context"
	"path/filepath"
	"testing"
	"time"

	"github.com/antigravity-mobile/bridge/internal/statestore"
)

func TestMonitorWindowsWarningAndCalibration(t *testing.T) {
	st, err := statestore.Open(filepath.Join(t.TempDir(), "state.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	mon, err := NewMonitor(st, "Google AI Ultra", 1000, 10000, 1000, 10000)
	if err != nil {
		t.Fatal(err)
	}
	fixedNow := time.Unix(1_795_527_000, 0)
	mon.nowFn = func() time.Time { return fixedNow }

	// Initially full
	snap, err := mon.Snapshot(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if snap.Pools[0].Remaining5hPct != 100 || snap.Pools[0].Level != "full" || snap.Pools[0].Reset5hAt != nil {
		t.Fatalf("expected full gemini pool initially, got %+v", snap.Pools[0])
	}

	// Add 700 effective cost (70% used -> 30% remaining -> warning level)
	err = st.RecordUsageBatch([]statestore.UsageEntry{
		{
			ConversationID: "c1",
			StepIndex:      1,
			CreatedAtUnix:  fixedNow.Unix() - 3600,
			PoolID:         "gemini",
			Model:          "gemini-4-neon-xhigh",
			InputTokens:    700,
		},
	})
	if err != nil {
		t.Fatal(err)
	}

	snap2, err := mon.Snapshot(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	g := snap2.Pools[0]
	if g.Remaining5hPct != 30 || g.Level != "warning" || g.Reset5hAt == nil {
		t.Fatalf("expected 30%% warning, got %+v", g)
	}
	if *g.Reset5hAt != fixedNow.Unix()-3600+Window5hSeconds {
		t.Fatalf("unexpected reset5hAt: %d", *g.Reset5hAt)
	}

	// Calibrate Gemini 5h to 84% -> budget recalculates so snapshot immediately reflects 84%
	target5h := 84.0
	snap3, err := mon.Calibrate(context.Background(), CalibrationInput{
		PoolID:         "gemini",
		Remaining5hPct: &target5h,
	})
	if err != nil {
		t.Fatal(err)
	}
	if snap3.Pools[0].Remaining5hPct != 84 {
		t.Fatalf("expected calibrated 84%%, got %d%%", snap3.Pools[0].Remaining5hPct)
	}
}
