package brainwatcher

import (
	"bufio"
	"bytes"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/fsnotify/fsnotify"

	"github.com/antigravity-mobile/bridge/internal/statestore"
)

// ToolCall describes an agent tool invocation captured in transcript.jsonl.
type ToolCall struct {
	Name string         `json:"name"`
	Args map[string]any `json:"args,omitempty"`
}

// MediaRef describes an uploaded media attachment in USER_INPUT.
type MediaRef struct {
	MimeType string `json:"mime_type"`
	URI      string `json:"uri"`
}

// TranscriptStep represents a single step parsed from transcript.jsonl / transcript_full.jsonl.
type TranscriptStep struct {
	StepIndex       int        `json:"step_index"`
	Source          string     `json:"source"`
	Type            string     `json:"type"`
	Status          string     `json:"status"`
	CreatedAt       string     `json:"created_at"`
	CreatedAtUnix   int64      `json:"created_at_unix"`
	Content         string     `json:"content,omitempty"`
	Thinking        string     `json:"thinking,omitempty"`
	Model           string     `json:"model,omitempty"`
	ModelDisplay    string     `json:"model_display,omitempty"`
	InputTokens     int64      `json:"input_tokens,omitempty"`
	CacheReadTokens int64      `json:"cache_read_tokens,omitempty"`
	OutputTokens    int64      `json:"output_tokens,omitempty"`
	ToolCalls       []ToolCall `json:"tool_calls,omitempty"`
	Media           []MediaRef `json:"media,omitempty"`
	TruncatedFields []string   `json:"truncated_fields,omitempty"`
}

// ConversationStats summarizes cached metadata parsed from a conversation's transcript.
type ConversationStats struct {
	LatestModel        string
	LatestModelDisplay string
	LatestPreview      string
	LatestStepIndex    int
	LatestStepType     string
	NeedsConfirm       bool
	ConfirmSnippet     string
	QuickReplies       []string
}

// EventCallbacks notifies the hub server when brain files change.
type EventCallbacks struct {
	OnStepsAppended  func(convID string, steps []TranscriptStep, stats ConversationStats)
	OnArtifactChange func(convID string)
}

// Watcher monitors ~/.gemini/antigravity/brain for incremental transcript updates and artifact changes.
type Watcher struct {
	brainDir string
	store    *statestore.Store
	cb       EventCallbacks

	mu    sync.RWMutex
	stats map[string]ConversationStats

	fsWatcher *fsnotify.Watcher
	stopCh    chan struct{}
}

// New creates a new brain directory watcher.
func New(brainDir string, store *statestore.Store, cb EventCallbacks) *Watcher {
	return &Watcher{
		brainDir: brainDir,
		store:    store,
		cb:       cb,
		stats:    make(map[string]ConversationStats),
		stopCh:   make(chan struct{}),
	}
}

// GetStats returns the cached transcript summary stats for a conversation.
func (w *Watcher) GetStats(convID string) (ConversationStats, bool) {
	w.mu.RLock()
	defer w.mu.RUnlock()
	st, ok := w.stats[convID]
	return st, ok
}

// ScanAll scans all conversation directories in brainDir incrementally (using stored offsets).
func (w *Watcher) ScanAll() error {
	entries, err := os.ReadDir(w.brainDir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	for _, e := range entries {
		if !e.IsDir() || strings.HasPrefix(e.Name(), ".") {
			continue
		}
		convID := e.Name()
		_, _, _ = w.scanConversation(convID, false)
	}
	return nil
}

// Start begins watching brainDir for transcript and artifact changes until Stop is called.
func (w *Watcher) Start() error {
	fw, err := fsnotify.NewWatcher()
	if err != nil {
		return err
	}
	w.fsWatcher = fw

	if err := os.MkdirAll(w.brainDir, 0o755); err == nil {
		_ = fw.Add(w.brainDir)
		if entries, err := os.ReadDir(w.brainDir); err == nil {
			for _, e := range entries {
				if e.IsDir() && !strings.HasPrefix(e.Name(), ".") {
					w.watchConvDir(e.Name())
				}
			}
		}
	}

	go w.loop()
	return nil
}

// Stop terminates file watching.
func (w *Watcher) Stop() {
	close(w.stopCh)
	if w.fsWatcher != nil {
		_ = w.fsWatcher.Close()
	}
}

func (w *Watcher) watchConvDir(convID string) {
	if w.fsWatcher == nil {
		return
	}
	convDir := filepath.Join(w.brainDir, convID)
	_ = w.fsWatcher.Add(convDir)
	logsDir := filepath.Join(convDir, ".system_generated", "logs")
	if fi, err := os.Stat(logsDir); err == nil && fi.IsDir() {
		_ = w.fsWatcher.Add(logsDir)
	}
}

func (w *Watcher) loop() {
	ticker := time.NewTicker(3 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-w.stopCh:
			return
		case ev, ok := <-w.fsWatcher.Events:
			if !ok {
				return
			}
			w.handleFSEvent(ev)
		case <-w.fsWatcher.Errors:
			// Ignore transient OS watch errors; periodic ticker heals missed events.
		case <-ticker.C:
			// Lightweight sweep for newly created conversation directories or missed fs events.
			if entries, err := os.ReadDir(w.brainDir); err == nil {
				for _, e := range entries {
					if !e.IsDir() || strings.HasPrefix(e.Name(), ".") {
						continue
					}
					convID := e.Name()
					w.watchConvDir(convID)
					_, _, _ = w.scanConversation(convID, true)
				}
			}
		}
	}
}

func (w *Watcher) handleFSEvent(ev fsnotify.Event) {
	rel, err := filepath.Rel(w.brainDir, ev.Name)
	if err != nil || strings.HasPrefix(rel, "..") {
		return
	}
	parts := strings.Split(filepath.ToSlash(rel), "/")
	if len(parts) == 0 || parts[0] == "" || strings.HasPrefix(parts[0], ".") {
		return
	}
	convID := parts[0]

	if len(parts) == 1 && ev.Has(fsnotify.Create) {
		w.watchConvDir(convID)
		return
	}

	if strings.HasSuffix(ev.Name, "transcript.jsonl") {
		_, _, _ = w.scanConversation(convID, true)
		return
	}

	// Non-system file changes represent artifact updates.
	if len(parts) >= 2 && !strings.HasPrefix(parts[1], ".") && parts[1] != "scratch" && parts[1] != "browser_sandbox" {
		if w.cb.OnArtifactChange != nil {
			w.cb.OnArtifactChange(convID)
		}
	}
}

func (w *Watcher) scanConversation(convID string, emitEvents bool) ([]TranscriptStep, ConversationStats, error) {
	transcriptPath := filepath.Join(w.brainDir, convID, ".system_generated", "logs", "transcript.jsonl")
	fi, err := os.Stat(transcriptPath)
	if err != nil {
		return nil, ConversationStats{}, err
	}

	prevOffset, prevMtime, _ := w.store.GetWatcherOffset(convID)
	w.mu.RLock()
	curStats, hasCached := w.stats[convID]
	w.mu.RUnlock()

	// If file was truncated or we have no in-memory stats yet, read from start for stats (ledger is idempotent).
	startOffset := prevOffset
	if fi.Size() < prevOffset || !hasCached {
		startOffset = 0
	} else if fi.Size() == prevOffset && fi.ModTime().UnixNano() == prevMtime {
		return nil, curStats, nil
	}

	f, err := os.Open(transcriptPath)
	if err != nil {
		return nil, curStats, err
	}
	defer f.Close()

	if startOffset > 0 {
		if _, err := f.Seek(startOffset, io.SeekStart); err != nil {
			return nil, curStats, err
		}
	}

	rawBytes, err := io.ReadAll(f)
	if err != nil {
		return nil, curStats, err
	}

	// Only consume up to the last complete newline so partial writes are never misparsed.
	lastNL := bytes.LastIndexByte(rawBytes, '\n')
	if lastNL < 0 {
		return nil, curStats, nil
	}
	complete := rawBytes[:lastNL+1]
	newOffset := startOffset + int64(len(complete))

	var appended []TranscriptStep
	var ledgerEntries []statestore.UsageEntry

	scanner := bufio.NewScanner(bytes.NewReader(complete))
	scanner.Buffer(make([]byte, 64*1024), 4*1024*1024)
	for scanner.Scan() {
		line := bytes.TrimSpace(scanner.Bytes())
		if len(line) == 0 {
			continue
		}
		var step TranscriptStep
		if err := json.Unmarshal(line, &step); err != nil {
			continue
		}
		enrichStep(&step)
		appended = append(appended, step)
		applyStepToStats(&curStats, step)

		if step.Type == "PLANNER_RESPONSE" && (step.InputTokens > 0 || step.OutputTokens > 0 || step.CacheReadTokens > 0) {
			ledgerEntries = append(ledgerEntries, statestore.UsageEntry{
				ConversationID:  convID,
				StepIndex:       step.StepIndex,
				CreatedAtUnix:   step.CreatedAtUnix,
				PoolID:          ClassifyModelPool(step.Model),
				Model:           step.Model,
				InputTokens:     step.InputTokens,
				CacheReadTokens: step.CacheReadTokens,
				OutputTokens:    step.OutputTokens,
			})
		}
	}

	if len(ledgerEntries) > 0 {
		_ = w.store.RecordUsageBatch(ledgerEntries)
	}
	_ = w.store.SetWatcherOffset(convID, newOffset, fi.ModTime().UnixNano())

	w.mu.Lock()
	w.stats[convID] = curStats
	w.mu.Unlock()

	if emitEvents && len(appended) > 0 && w.cb.OnStepsAppended != nil && prevOffset > 0 {
		w.cb.OnStepsAppended(convID, appended, curStats)
	}
	return appended, curStats, nil
}

// ReadSteps reads paginated transcript steps for a conversation, hydrating truncated_fields from transcript_full.jsonl.
func (w *Watcher) ReadSteps(convID string, beforeStep, limit int) ([]TranscriptStep, bool, error) {
	if limit <= 0 || limit > 200 {
		limit = 80
	}
	logsDir := filepath.Join(w.brainDir, convID, ".system_generated", "logs")
	compactPath := filepath.Join(logsDir, "transcript.jsonl")
	fullPath := filepath.Join(logsDir, "transcript_full.jsonl")

	steps, truncatedIndices, err := readJSONLFile(compactPath)
	if err != nil {
		if os.IsNotExist(err) {
			return []TranscriptStep{}, false, nil
		}
		return nil, false, err
	}

	// Filter range before hydrating full fields so we only inspect needed steps.
	var filtered []TranscriptStep
	if beforeStep > 0 {
		for _, s := range steps {
			if s.StepIndex < beforeStep {
				filtered = append(filtered, s)
			}
		}
	} else {
		filtered = steps
	}

	hasMore := false
	if len(filtered) > limit {
		hasMore = true
		filtered = filtered[len(filtered)-limit:]
	}

	needHydrate := make(map[int]int) // step_index -> index in filtered
	for i, s := range filtered {
		if truncatedIndices[s.StepIndex] {
			needHydrate[s.StepIndex] = i
		}
	}
	if len(needHydrate) > 0 {
		hydrateFromFull(fullPath, filtered, needHydrate)
	}

	return filtered, hasMore, nil
}

func readJSONLFile(path string) ([]TranscriptStep, map[int]bool, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, nil, err
	}
	defer f.Close()

	var steps []TranscriptStep
	truncated := make(map[int]bool)
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 64*1024), 8*1024*1024)
	for scanner.Scan() {
		line := bytes.TrimSpace(scanner.Bytes())
		if len(line) == 0 {
			continue
		}
		var step TranscriptStep
		if err := json.Unmarshal(line, &step); err != nil {
			continue
		}
		enrichStep(&step)
		if len(step.TruncatedFields) > 0 {
			truncated[step.StepIndex] = true
		}
		steps = append(steps, step)
	}
	return steps, truncated, scanner.Err()
}

func hydrateFromFull(fullPath string, target []TranscriptStep, indexMap map[int]int) {
	f, err := os.Open(fullPath)
	if err != nil {
		return
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 128*1024), 16*1024*1024)
	for scanner.Scan() {
		line := bytes.TrimSpace(scanner.Bytes())
		if len(line) == 0 {
			continue
		}
		var full TranscriptStep
		if err := json.Unmarshal(line, &full); err != nil {
			continue
		}
		if pos, ok := indexMap[full.StepIndex]; ok {
			enrichStep(&full)
			full.TruncatedFields = nil
			target[pos] = full
		}
	}
}

func enrichStep(step *TranscriptStep) {
	if step.CreatedAt != "" {
		if t, err := time.Parse(time.RFC3339Nano, step.CreatedAt); err == nil {
			step.CreatedAtUnix = t.Unix()
		} else if t, err := time.Parse(time.RFC3339, step.CreatedAt); err == nil {
			step.CreatedAtUnix = t.Unix()
		}
	}
	if step.CreatedAtUnix == 0 {
		step.CreatedAtUnix = time.Now().Unix()
	}
	if step.Model != "" {
		step.ModelDisplay = FormatModelDisplay(step.Model)
	}
}

func applyStepToStats(st *ConversationStats, step TranscriptStep) {
	if step.StepIndex >= st.LatestStepIndex {
		st.LatestStepIndex = step.StepIndex
		st.LatestStepType = step.Type
	}
	if step.Model != "" {
		st.LatestModel = step.Model
		st.LatestModelDisplay = FormatModelDisplay(step.Model)
	}
	if step.Type == "PLANNER_RESPONSE" {
		if strings.TrimSpace(step.Content) != "" {
			st.LatestPreview = cleanPreview(step.Content, 160)
		}
		// Reset confirm flag on new planner turn, then detect ask_question / RequestFeedback.
		st.NeedsConfirm = false
		st.ConfirmSnippet = ""
		st.QuickReplies = nil

		for _, tc := range step.ToolCalls {
			switch tc.Name {
			case "ask_question":
				st.NeedsConfirm = true
				st.ConfirmSnippet, st.QuickReplies = extractAskQuestionSummary(tc.Args)
			case "write_file", "edit_file":
				if meta, ok := tc.Args["ArtifactMetadata"].(map[string]any); ok {
					if rf, ok := meta["RequestFeedback"].(bool); ok && rf {
						st.NeedsConfirm = true
						st.ConfirmSnippet = "Agent 提交了一份待审核方案，等待你的确认"
						st.QuickReplies = []string{"确认方案，直接开工", "我先看一下文档"}
					}
				}
			}
		}
	} else if step.Type == "USER_INPUT" {
		st.NeedsConfirm = false
		st.ConfirmSnippet = ""
		st.QuickReplies = nil
	}
}

func extractAskQuestionSummary(args map[string]any) (string, []string) {
	qs, ok := args["questions"].([]any)
	if !ok || len(qs) == 0 {
		return "Agent 有决策问题等待你确认", []string{"确认", "暂缓"}
	}
	first, ok := qs[0].(map[string]any)
	if !ok {
		return "Agent 有决策问题等待你确认", []string{"确认", "暂缓"}
	}
	snippet, _ := first["question"].(string)
	if snippet == "" {
		snippet = "Agent 有决策问题等待你确认"
	}
	var replies []string
	if opts, ok := first["options"].([]any); ok {
		for _, o := range opts {
			if s, ok := o.(string); ok && len(replies) < 2 {
				s = strings.TrimPrefix(s, "(Recommended) ")
				if len([]rune(s)) > 20 {
					s = string([]rune(s)[:20])
				}
				replies = append(replies, s)
			}
		}
	}
	return snippet, replies
}

// ClassifyModelPool maps a raw model string into "gemini" or "claude_gpt".
func ClassifyModelPool(model string) string {
	m := strings.ToLower(strings.TrimSpace(model))
	if strings.Contains(m, "claude") || strings.Contains(m, "gpt") || strings.HasPrefix(m, "o1") || strings.HasPrefix(m, "o3") || strings.HasPrefix(m, "o4") {
		return "claude_gpt"
	}
	return "gemini"
}

// FormatModelDisplay turns raw IDs like "gemini-4-neon-xhigh" into "Neon · XHigh".
func FormatModelDisplay(model string) string {
	m := strings.TrimSpace(model)
	if m == "" {
		return ""
	}
	lower := strings.ToLower(m)
	parts := strings.Split(lower, "-")

	effortMap := map[string]string{
		"xhigh":   "XHigh",
		"high":    "High",
		"medium":  "Medium",
		"low":     "Low",
		"minimal": "Minimal",
	}

	if strings.HasPrefix(lower, "gemini-") && len(parts) >= 3 {
		last := parts[len(parts)-1]
		effort, hasEffort := effortMap[last]
		coreParts := parts[1:]
		if hasEffort {
			coreParts = parts[1 : len(parts)-1]
		}
		// Prefer codename (e.g. "neon", "carbon", "hydrogen") when present after version digit.
		name := ""
		for _, p := range coreParts {
			if len(p) > 0 && (p[0] < '0' || p[0] > '9') {
				name = titleWord(p)
				break
			}
		}
		if name == "" {
			name = "Gemini " + strings.Join(coreParts, " ")
		}
		if hasEffort {
			return name + " · " + effort
		}
		return name
	}

	words := make([]string, 0, len(parts))
	for _, p := range parts {
		if p != "" {
			words = append(words, titleWord(p))
		}
	}
	return strings.Join(words, " ")
}

func titleWord(s string) string {
	if s == "" {
		return ""
	}
	if s == "gpt" {
		return "GPT"
	}
	return strings.ToUpper(s[:1]) + s[1:]
}

func cleanPreview(s string, maxRunes int) string {
	s = strings.ReplaceAll(s, "\r", " ")
	s = strings.ReplaceAll(s, "\n", " ")
	s = strings.Join(strings.Fields(s), " ")
	runes := []rune(s)
	if len(runes) > maxRunes {
		return string(runes[:maxRunes]) + "..."
	}
	return s
}
