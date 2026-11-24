package agyreader

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	_ "modernc.org/sqlite"
)

// WorkspaceInfo represents either a local project workspace or a global chat.
type WorkspaceInfo struct {
	Kind     string `json:"kind"` // "workspace" | "global"
	Label    string `json:"label"`
	RootPath string `json:"rootPath,omitempty"`
}

// RawSummary mirrors a root conversation row from Antigravity's conversation_summaries.db.
type RawSummary struct {
	ConversationID        string        `json:"conversationId"`
	Title                 string        `json:"title"`
	Preview               string        `json:"preview"`
	StepCount             int           `json:"stepCount"`
	LastModifiedUnix      int64         `json:"lastModifiedUnix"`
	LastUserInputUnix     int64         `json:"lastUserInputUnix"`
	LastUserInputStepIdx  int           `json:"lastUserInputStepIndex"`
	Workspace             WorkspaceInfo `json:"workspace"`
	WorkspaceRoots        []string      `json:"workspaceRoots,omitempty"`
	Status                string        `json:"status"`
	Running               bool          `json:"running"`
	SubagentCount         int           `json:"subagentCount"`
	Source                string        `json:"source,omitempty"`
}

// SearchHit represents a match from Antigravity's conversations_fts index.
type SearchHit struct {
	ConversationID   string `json:"conversationId"`
	Title            string `json:"title"`
	Workspace        string `json:"workspace"`
	Snippet          string `json:"snippet"`
	LastModifiedUnix int64  `json:"lastModifiedUnix"`
}

// Reader provides strict read-only access to Antigravity's native conversation_summaries.db.
type Reader struct {
	dbPath string
}

// New creates a read-only reader pointing at conversation_summaries.db.
func New(dbPath string) *Reader {
	return &Reader{dbPath: dbPath}
}

func (r *Reader) openRO() (*sql.DB, error) {
	if _, err := os.Stat(r.dbPath); err != nil {
		return nil, err
	}
	dsn := fmt.Sprintf("file:%s?mode=ro&_pragma=query_only(1)&_pragma=busy_timeout(3000)", r.dbPath)
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	return db, nil
}

// ListRootSummaries returns all non-killed root conversations (nesting_depth = 0).
func (r *Reader) ListRootSummaries(limit int) ([]RawSummary, error) {
	db, err := r.openRO()
	if err != nil {
		if os.IsNotExist(err) {
			return []RawSummary{}, nil
		}
		return nil, err
	}
	defer db.Close()

	subCounts := r.loadSubagentCounts(db)

	query := `
		SELECT conversation_id, title, preview, step_count, last_modified_time,
		       workspace_uris, status, source, not_fully_idle,
		       last_user_input_time, last_user_input_step_index
		FROM conversation_summaries
		WHERE nesting_depth = 0 AND killed = 0
		ORDER BY last_modified_time DESC
	`
	var rows *sql.Rows
	if limit > 0 {
		rows, err = db.Query(query+" LIMIT ?", limit)
	} else {
		rows, err = db.Query(query)
	}
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]RawSummary, 0, 32)
	for rows.Next() {
		s, err := scanSummaryRow(rows, subCounts)
		if err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

// GetSummary returns a single conversation summary by ID.
func (r *Reader) GetSummary(convID string) (*RawSummary, error) {
	db, err := r.openRO()
	if err != nil {
		return nil, err
	}
	defer db.Close()

	subCounts := r.loadSubagentCounts(db)
	rows, err := db.Query(`
		SELECT conversation_id, title, preview, step_count, last_modified_time,
		       workspace_uris, status, source, not_fully_idle,
		       last_user_input_time, last_user_input_step_index
		FROM conversation_summaries
		WHERE conversation_id = ?
	`, convID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	if !rows.Next() {
		return nil, sql.ErrNoRows
	}
	s, err := scanSummaryRow(rows, subCounts)
	if err != nil {
		return nil, err
	}
	return &s, nil
}

// ListWorkspaces extracts unique known local workspace roots ordered by recent usage.
func (r *Reader) ListWorkspaces() ([]WorkspaceInfo, error) {
	summaries, err := r.ListRootSummaries(200)
	if err != nil {
		return nil, err
	}
	seen := make(map[string]struct{})
	var list []WorkspaceInfo
	for _, s := range summaries {
		if s.Workspace.Kind != "workspace" || s.Workspace.RootPath == "" {
			continue
		}
		if _, ok := seen[s.Workspace.RootPath]; ok {
			continue
		}
		seen[s.Workspace.RootPath] = struct{}{}
		list = append(list, s.Workspace)
	}
	return list, nil
}

// Search queries Antigravity's native FTS5 table (conversations_fts) with fallback to LIKE.
func (r *Reader) Search(rawQuery string, limit int) ([]SearchHit, error) {
	q := strings.TrimSpace(rawQuery)
	if q == "" {
		return []SearchHit{}, nil
	}
	if limit <= 0 || limit > 50 {
		limit = 20
	}

	db, err := r.openRO()
	if err != nil {
		if os.IsNotExist(err) {
			return []SearchHit{}, nil
		}
		return nil, err
	}
	defer db.Close()

	ftsQuery := buildFTSQuery(q)
	rows, err := db.Query(`
		SELECT conversation_id, title, workspace,
		       COALESCE(NULLIF(agent_body, ''), user_body, title) AS body,
		       MAX(last_modified_time) AS latest_time
		FROM conversations_fts
		WHERE conversations_fts MATCH ?
		GROUP BY conversation_id
		ORDER BY latest_time DESC
		LIMIT ?
	`, ftsQuery, limit)
	if err == nil {
		defer rows.Close()
		var hits []SearchHit
		for rows.Next() {
			var h SearchHit
			var body, modTime string
			if err := rows.Scan(&h.ConversationID, &h.Title, &h.Workspace, &body, &modTime); err != nil {
				return nil, err
			}
			h.Snippet = extractSnippet(body, q, 140)
			h.LastModifiedUnix = ParseTimestamp(modTime)
			hits = append(hits, h)
		}
		if err := rows.Err(); err == nil {
			return hits, nil
		}
	}

	// Graceful fallback if FTS5 query syntax fails or FTS table is absent.
	like := "%" + q + "%"
	fallbackRows, err := db.Query(`
		SELECT conversation_id, title, workspace_uris, preview, last_modified_time
		FROM conversation_summaries
		WHERE nesting_depth = 0 AND killed = 0 AND (title LIKE ? OR preview LIKE ? OR workspace_uris LIKE ?)
		ORDER BY last_modified_time DESC
		LIMIT ?
	`, like, like, like, limit)
	if err != nil {
		return nil, err
	}
	defer fallbackRows.Close()

	var hits []SearchHit
	for fallbackRows.Next() {
		var h SearchHit
		var wsURIs, preview, modTime string
		if err := fallbackRows.Scan(&h.ConversationID, &h.Title, &wsURIs, &preview, &modTime); err != nil {
			return nil, err
		}
		ws, _ := ParseWorkspaceURIs(wsURIs)
		h.Workspace = ws.Label
		h.Snippet = extractSnippet(preview, q, 140)
		h.LastModifiedUnix = ParseTimestamp(modTime)
		hits = append(hits, h)
	}
	return hits, fallbackRows.Err()
}

func (r *Reader) loadSubagentCounts(db *sql.DB) map[string]int {
	parentOf := make(map[string]string)

	if rows, err := db.Query(`SELECT conversation_id, parent_id FROM conversation_parents`); err == nil {
		for rows.Next() {
			var cid, pid string
			if rows.Scan(&cid, &pid) == nil && cid != "" && pid != "" {
				parentOf[cid] = pid
			}
		}
		rows.Close()
	}

	if rows, err := db.Query(`SELECT conversation_id, parent_conversation_id FROM conversation_summaries WHERE parent_conversation_id != ''`); err == nil {
		for rows.Next() {
			var cid, pid string
			if rows.Scan(&cid, &pid) == nil && cid != "" && pid != "" {
				if _, exists := parentOf[cid]; !exists {
					parentOf[cid] = pid
				}
			}
		}
		rows.Close()
	}

	// Count all descendants grouped by their root ancestor.
	counts := make(map[string]int)
	for cid, pid := range parentOf {
		root := pid
		seen := map[string]bool{cid: true}
		for {
			if seen[root] {
				break
			}
			seen[root] = true
			next, ok := parentOf[root]
			if !ok || next == "" {
				break
			}
			root = next
		}
		counts[root]++
	}
	return counts
}

func scanSummaryRow(rows *sql.Rows, subCounts map[string]int) (RawSummary, error) {
	var s RawSummary
	var modTimeStr, wsURIs, userTimeStr string
	var notFullyIdle int
	if err := rows.Scan(
		&s.ConversationID, &s.Title, &s.Preview, &s.StepCount, &modTimeStr,
		&wsURIs, &s.Status, &s.Source, &notFullyIdle,
		&userTimeStr, &s.LastUserInputStepIdx,
	); err != nil {
		return s, err
	}
	s.LastModifiedUnix = ParseTimestamp(modTimeStr)
	s.LastUserInputUnix = ParseTimestamp(userTimeStr)
	s.Workspace, s.WorkspaceRoots = ParseWorkspaceURIs(wsURIs)
	s.Running = notFullyIdle != 0 || strings.Contains(strings.ToUpper(s.Status), "RUNNING")
	s.SubagentCount = subCounts[s.ConversationID]
	if strings.TrimSpace(s.Title) == "" {
		s.Title = "未命名对话"
	}
	return s, nil
}

// ParseWorkspaceURIs parses JSON workspace_uris like ["file:///Users/apple/go-project/ai"].
func ParseWorkspaceURIs(raw string) (WorkspaceInfo, []string) {
	raw = strings.TrimSpace(raw)
	if raw == "" || raw == "[]" {
		return WorkspaceInfo{Kind: "global", Label: "通用对话"}, nil
	}
	var uris []string
	if err := json.Unmarshal([]byte(raw), &uris); err != nil || len(uris) == 0 {
		return WorkspaceInfo{Kind: "global", Label: "通用对话"}, nil
	}

	var roots []string
	for _, u := range uris {
		p := uriToLocalPath(u)
		if p != "" {
			roots = append(roots, p)
		}
	}
	if len(roots) == 0 {
		return WorkspaceInfo{Kind: "global", Label: "通用对话"}, nil
	}
	label := filepath.Base(roots[0])
	if label == "" || label == "/" || label == "." {
		label = roots[0]
	}
	return WorkspaceInfo{
		Kind:     "workspace",
		Label:    label,
		RootPath: roots[0],
	}, roots
}

func uriToLocalPath(u string) string {
	u = strings.TrimSpace(u)
	if u == "" {
		return ""
	}
	if strings.HasPrefix(u, "file://") {
		parsed, err := url.Parse(u)
		if err == nil && parsed.Path != "" {
			decoded, decErr := url.PathUnescape(parsed.Path)
			if decErr == nil {
				return filepath.Clean(decoded)
			}
			return filepath.Clean(parsed.Path)
		}
		return filepath.Clean(strings.TrimPrefix(u, "file://"))
	}
	if filepath.IsAbs(u) {
		return filepath.Clean(u)
	}
	return ""
}

// ParseTimestamp handles SQLite/Go/RFC3339 timestamp strings seen in Antigravity DBs.
func ParseTimestamp(s string) int64 {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0
	}
	layouts := []string{
		"2006-01-02 15:04:05.999999999-07:00",
		"2006-01-02 15:04:05.999999999Z07:00",
		"2006-01-02 15:04:05-07:00",
		"2006-01-02 15:04:05Z07:00",
		"2006-01-02 15:04:05.999999999",
		"2006-01-02 15:04:05",
		time.RFC3339Nano,
		time.RFC3339,
	}
	for _, layout := range layouts {
		if t, err := time.Parse(layout, s); err == nil {
			return t.Unix()
		}
	}
	return 0
}

func buildFTSQuery(q string) string {
	tokens := strings.Fields(q)
	escaped := make([]string, 0, len(tokens))
	for _, tok := range tokens {
		tok = strings.ReplaceAll(tok, `"`, `""`)
		if tok != "" {
			escaped = append(escaped, `"`+tok+`"`)
		}
	}
	if len(escaped) == 0 {
		return `""`
	}
	return strings.Join(escaped, " ")
}

func extractSnippet(text, query string, maxRunes int) string {
	clean := strings.Join(strings.Fields(text), " ")
	runes := []rune(clean)
	if len(runes) <= maxRunes {
		return clean
	}
	lower := strings.ToLower(clean)
	idx := strings.Index(lower, strings.ToLower(query))
	if idx < 0 {
		return string(runes[:maxRunes]) + "..."
	}
	runeIdx := len([]rune(clean[:idx]))
	start := runeIdx - 30
	if start < 0 {
		start = 0
	}
	end := start + maxRunes
	if end > len(runes) {
		end = len(runes)
	}
	prefix := ""
	suffix := ""
	if start > 0 {
		prefix = "..."
	}
	if end < len(runes) {
		suffix = "..."
	}
	return prefix + string(runes[start:end]) + suffix
}
