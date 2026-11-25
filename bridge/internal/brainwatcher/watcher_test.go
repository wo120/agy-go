package brainwatcher

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/antigravity-mobile/bridge/internal/statestore"
)

func TestIncrementalScanHydrationAndModelFormat(t *testing.T) {
	if got := FormatModelDisplay("gemini-4-neon-xhigh"); got != "Neon · XHigh" {
		t.Fatalf("expected 'Neon · XHigh', got %q", got)
	}
	if got := FormatModelDisplay("gemini-4-carbon-high"); got != "Carbon · High" {
		t.Fatalf("expected 'Carbon · High', got %q", got)
	}
	if got := ClassifyModelPool("claude-sonnet-4-5"); got != "claude_gpt" {
		t.Fatalf("expected claude_gpt, got %q", got)
	}

	tmp := t.TempDir()
	st, err := statestore.Open(filepath.Join(tmp, "state.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	brainDir := filepath.Join(tmp, "brain")
	logsDir := filepath.Join(brainDir, "conv-1", ".system_generated", "logs")
	if err := os.MkdirAll(logsDir, 0o755); err != nil {
		t.Fatal(err)
	}

	compactPath := filepath.Join(logsDir, "transcript.jsonl")
	fullPath := filepath.Join(logsDir, "transcript_full.jsonl")

	line1 := `{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-11-24T13:00:00Z","content":"hello"}` + "\n"
	line2 := `{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-24T13:01:00Z","model":"gemini-4-neon-xhigh","input_tokens":2000,"cache_read_tokens":1000,"output_tokens":300,"content":"short...","truncated_fields":["content"]}` + "\n"
	line2Full := `{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-24T13:01:00Z","model":"gemini-4-neon-xhigh","input_tokens":2000,"cache_read_tokens":1000,"output_tokens":300,"content":"full hydrated response content"}` + "\n"

	if err := os.WriteFile(compactPath, []byte(line1+line2), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(fullPath, []byte(line1+line2Full), 0o644); err != nil {
		t.Fatal(err)
	}

	var appendedCount int
	w := New(brainDir, st, EventCallbacks{
		OnStepsAppended: func(convID string, steps []TranscriptStep, stats ConversationStats) {
			appendedCount += len(steps)
		},
	})
	if err := w.ScanAll(); err != nil {
		t.Fatal(err)
	}

	stats, ok := w.GetStats("conv-1")
	if !ok || stats.LatestModelDisplay != "Neon · XHigh" {
		t.Fatalf("unexpected stats: %+v", stats)
	}

	// Verify ReadSteps hydrates truncated_fields from transcript_full.jsonl
	steps, hasMore, err := w.ReadSteps("conv-1", 0, 50)
	if err != nil || hasMore || len(steps) != 2 {
		t.Fatalf("ReadSteps failed: len=%d hasMore=%v err=%v", len(steps), hasMore, err)
	}
	if steps[1].Content != "full hydrated response content" {
		t.Fatalf("expected hydrated content, got %q", steps[1].Content)
	}

	// Append a new ask_question step and trigger incremental scan
	f, err := os.OpenFile(compactPath, os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	line3 := `{"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-24T13:02:00Z","model":"gemini-4-neon-xhigh","tool_calls":[{"name":"ask_question","args":{"questions":[{"question":"确认直接开工吗？","options":["(Recommended) 直接开工","先等等"]}]}}]}` + "\n"
	_, _ = f.WriteString(line3)
	_ = f.Close()

	_, stats2, err := w.scanConversation("conv-1", true)
	if err != nil {
		t.Fatal(err)
	}
	if !stats2.NeedsConfirm || appendedCount != 1 {
		t.Fatalf("expected NeedsConfirm=true and appendedCount=1, got %+v count=%d", stats2, appendedCount)
	}
}

func TestCompactTranscriptStringifiedToolCallArgs(t *testing.T) {
	tmp := t.TempDir()
	st, err := statestore.Open(filepath.Join(tmp, "state.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	brainDir := filepath.Join(tmp, "brain")
	logsDir := filepath.Join(brainDir, "conv-compact", ".system_generated", "logs")
	if err := os.MkdirAll(logsDir, 0o755); err != nil {
		t.Fatal(err)
	}

	// Antigravity compact transcript.jsonl serializes tool_calls[].args values as JSON strings
	// without setting truncated_fields when below the truncation threshold.
	line1 := `{"step_index":0,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-24T13:00:00Z","tool_calls":[{"name":"write_file","args":{"ArtifactMetadata":"{\"RequestFeedback\":true,\"Summary\":\"plan\",\"UserFacing\":true}"}}]}` + "\n"
	line2 := `{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-24T13:01:00Z","tool_calls":[{"name":"ask_question","args":{"questions":"[{\"is_multi_select\":false,\"options\":[\"(Recommended) 方案 A\",\"方案 B\"],\"question\":\"如何提交改动？\"}]"}}]}` + "\n"

	compactPath := filepath.Join(logsDir, "transcript.jsonl")
	if err := os.WriteFile(compactPath, []byte(line1+line2), 0o644); err != nil {
		t.Fatal(err)
	}

	w := New(brainDir, st, EventCallbacks{})
	if err := w.ScanAll(); err != nil {
		t.Fatal(err)
	}

	stats, ok := w.GetStats("conv-compact")
	if !ok || !stats.NeedsConfirm {
		t.Fatalf("expected NeedsConfirm=true, got ok=%v stats=%+v", ok, stats)
	}
	if stats.ConfirmSnippet != "如何提交改动？" {
		t.Fatalf("expected decoded question snippet, got %q", stats.ConfirmSnippet)
	}
	if len(stats.QuickReplies) != 2 || stats.QuickReplies[0] != "方案 A" || stats.QuickReplies[1] != "方案 B" {
		t.Fatalf("unexpected quick replies: %#v", stats.QuickReplies)
	}

	steps, _, err := w.ReadSteps("conv-compact", 0, 50)
	if err != nil || len(steps) != 2 {
		t.Fatalf("ReadSteps failed: len=%d err=%v", len(steps), err)
	}

	meta, ok := steps[0].ToolCalls[0].Args["ArtifactMetadata"].(map[string]any)
	if !ok || meta["RequestFeedback"] != true {
		t.Fatalf("expected ArtifactMetadata normalized to map, got %#v", steps[0].ToolCalls[0].Args["ArtifactMetadata"])
	}

	qs, ok := steps[1].ToolCalls[0].Args["questions"].([]any)
	if !ok || len(qs) != 1 {
		t.Fatalf("expected questions normalized to []any, got %T (%#v)", steps[1].ToolCalls[0].Args["questions"], steps[1].ToolCalls[0].Args["questions"])
	}
}
