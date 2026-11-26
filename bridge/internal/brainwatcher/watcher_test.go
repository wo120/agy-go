package brainwatcher

import (
	"os"
	"path/filepath"
	"strings"
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

func TestReadStepsForClientCompactsNoiseAndHandlesLargeLines(t *testing.T) {
	tmp := t.TempDir()
	st, err := statestore.Open(filepath.Join(tmp, "state.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	brainDir := filepath.Join(tmp, "brain")
	logsDir := filepath.Join(brainDir, "conv-slim", ".system_generated", "logs")
	if err := os.MkdirAll(logsDir, 0o755); err != nil {
		t.Fatal(err)
	}

	// Build a payload with GENERIC/SYSTEM_MESSAGE noise and a large write_file tool arg.
	largeBuf := make([]byte, 32*1024)
	for i := range largeBuf {
		largeBuf[i] = 'a'
	}
	lines := "" +
		`{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-11-24T13:00:00Z","content":"hi"}` + "\n" +
		`{"step_index":1,"source":"SYSTEM","type":"SYSTEM_MESSAGE","status":"DONE","created_at":"2026-11-24T13:00:01Z","content":"injected"}` + "\n" +
		`{"step_index":2,"source":"SYSTEM","type":"GENERIC","status":"DONE","created_at":"2026-11-24T13:00:02Z","content":"` + string(largeBuf) + `"}` + "\n" +
		`{"step_index":3,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-24T13:00:03Z","content":"done","tool_calls":[{"name":"write_file","args":{"Content":"` + string(largeBuf) + `","ArtifactMetadata":{"RequestFeedback":true}}},{"name":"run_command","args":{"CommandLine":"echo 1"}},{"name":"ask_question","args":{"questions":[{"question":"继续？","options":["是","否"]}]}}]}` + "\n"

	if err := os.WriteFile(filepath.Join(logsDir, "transcript.jsonl"), []byte(lines), 0o644); err != nil {
		t.Fatal(err)
	}

	w := New(brainDir, st, EventCallbacks{})
	steps, hasMore, err := w.ReadStepsForClient("conv-slim", 0, 50)
	if err != nil || hasMore {
		t.Fatalf("ReadStepsForClient failed: hasMore=%v err=%v", hasMore, err)
	}
	if len(steps) != 2 {
		t.Fatalf("expected only USER_INPUT and PLANNER_RESPONSE (2 steps), got %d", len(steps))
	}
	if steps[0].StepIndex != 0 || steps[1].StepIndex != 3 {
		t.Fatalf("unexpected step indices: %d, %d", steps[0].StepIndex, steps[1].StepIndex)
	}
	tcs := steps[1].ToolCalls
	if len(tcs) != 3 {
		t.Fatalf("expected 3 tool calls preserved, got %d", len(tcs))
	}
	if _, hasHeavy := tcs[0].Args["Content"]; hasHeavy {
		t.Fatalf("expected heavy write_file Content stripped, got %#v", tcs[0].Args)
	}
	if _, hasMeta := tcs[0].Args["ArtifactMetadata"]; !hasMeta {
		t.Fatalf("expected ArtifactMetadata preserved on write_file")
	}
	if len(tcs[1].Args) != 0 {
		t.Fatalf("expected run_command args stripped, got %#v", tcs[1].Args)
	}
	if _, hasQ := tcs[2].Args["questions"]; !hasQ {
		t.Fatalf("expected ask_question questions preserved")
	}
}

func TestCleanUserInputContentAndStepEnrichment(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
	}{
		{
			name: "plain",
			in:   "  hello world  ",
			want: "hello world",
		},
		{
			name: "standard wrapper",
			in:   "<USER_REQUEST>\n先优化\n</USER_REQUEST>\n<ADDITIONAL_METADATA>\nThe current local time is: 2026-11-25T02:59:10-05:00.\n</ADDITIONAL_METADATA>",
			want: "先优化",
		},
		{
			name: "with user settings change and skill",
			in:   "<USER_REQUEST>\n/last30days 查一下\n</USER_REQUEST>\n<ADDITIONAL_METADATA>\nThe current local time is: 2026-11-25T03:00:00-05:00.\n<SKILL>...</SKILL>\n</ADDITIONAL_METADATA>\n<USER_SETTINGS_CHANGE>\nModel changed\n</USER_SETTINGS_CHANGE>",
			want: "/last30days 查一下",
		},
		{
			name: "nested USER_REQUEST pasted inside user prompt",
			in: "<USER_REQUEST>\n手机端查看 会话详情时，显示用户的输入：<USER_REQUEST>\n先优化\n</USER_REQUEST>\n<ADDITIONAL_METADATA>\nThe current local time is: 2026-11-25T02:59:10-05:00.\n</ADDITIONAL_METADATA>\n\n\n而在手机端的会话详情页发送消息时，反重力显示发送的消息是系统消息   。修复这两个问题\n</USER_REQUEST>\n<ADDITIONAL_METADATA>\nThe current local time is: 2026-11-25T03:39:04-05:00.\n</ADDITIONAL_METADATA>\n<USER_SETTINGS_CHANGE>\nchanged\n</USER_SETTINGS_CHANGE>",
			want: "手机端查看 会话详情时，显示用户的输入：<USER_REQUEST>\n先优化\n</USER_REQUEST>\n<ADDITIONAL_METADATA>\nThe current local time is: 2026-11-25T02:59:10-05:00.\n</ADDITIONAL_METADATA>\n\n\n而在手机端的会话详情页发送消息时，反重力显示发送的消息是系统消息   。修复这两个问题",
		},
		{
			name: "truncated without closing tag",
			in:   "<USER_REQUEST>\npartial message...",
			want: "partial message...",
		},
	}
	for _, tc := range cases {
		if got := CleanUserInputContent(tc.in); got != tc.want {
			t.Fatalf("%s: got %q, want %q", tc.name, got, tc.want)
		}
	}

	tmp := t.TempDir()
	st, err := statestore.Open(filepath.Join(tmp, "state.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	brainDir := filepath.Join(tmp, "brain")
	logsDir := filepath.Join(brainDir, "conv-user", ".system_generated", "logs")
	if err := os.MkdirAll(logsDir, 0o755); err != nil {
		t.Fatal(err)
	}
	line := `{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"","content":"<USER_REQUEST>\n你好\n</USER_REQUEST>\n<ADDITIONAL_METADATA>\nThe current local time is: 2026-11-25T04:07:16-05:00.\n</ADDITIONAL_METADATA>\n<USER_SETTINGS_CHANGE>\nModel Selection changed\n</USER_SETTINGS_CHANGE>"}` + "\n"
	if err := os.WriteFile(filepath.Join(logsDir, "transcript.jsonl"), []byte(line), 0o644); err != nil {
		t.Fatal(err)
	}
	w := New(brainDir, st, EventCallbacks{})
	steps, _, err := w.ReadStepsForClient("conv-user", 0, 50)
	if err != nil || len(steps) != 1 {
		t.Fatalf("ReadStepsForClient failed: len=%d err=%v", len(steps), err)
	}
	if steps[0].Content != "你好" {
		t.Fatalf("expected cleaned USER_INPUT content '你好', got %q", steps[0].Content)
	}
	if steps[0].CreatedAtUnix != 1795597636 {
		t.Fatalf("expected parsed local time unix 1795597636, got %d", steps[0].CreatedAtUnix)
	}
	if !strings.Contains(steps[0].UserMetadata, "The current local time is: 2026-11-25T04:07:16-05:00.") ||
		!strings.Contains(steps[0].UserMetadata, "Model Selection changed") {
		t.Fatalf("expected preserved UserMetadata, got %q", steps[0].UserMetadata)
	}
}
