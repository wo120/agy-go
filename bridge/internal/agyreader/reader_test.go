package agyreader

import (
	"database/sql"
	"path/filepath"
	"strings"
	"testing"

	_ "modernc.org/sqlite"
)

func TestReaderSummariesSubagentsAndSearch(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "conversation_summaries.db")
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	_, err = db.Exec(`
		CREATE TABLE conversation_summaries (
			conversation_id TEXT PRIMARY KEY,
			title TEXT NOT NULL DEFAULT "",
			preview TEXT NOT NULL DEFAULT "",
			step_count INTEGER NOT NULL DEFAULT 0,
			last_modified_time DATETIME NOT NULL,
			workspace_uris TEXT NOT NULL,
			status TEXT NOT NULL DEFAULT "",
			source TEXT NOT NULL DEFAULT "",
			parent_conversation_id TEXT NOT NULL DEFAULT "",
			nesting_depth INTEGER NOT NULL DEFAULT 0,
			not_fully_idle NUMERIC NOT NULL DEFAULT 0,
			killed NUMERIC NOT NULL DEFAULT 0,
			last_user_input_time DATETIME NOT NULL,
			last_user_input_step_index INTEGER NOT NULL DEFAULT -1
		);
		CREATE TABLE conversation_parents (
			conversation_id TEXT PRIMARY KEY,
			parent_id TEXT NOT NULL
		) WITHOUT ROWID;
		CREATE VIRTUAL TABLE conversations_fts USING fts5(
			conversation_id UNINDEXED,
			last_modified_time UNINDEXED,
			title, workspace, project, user_body, agent_body
		);

		INSERT INTO conversation_summaries VALUES
			('root-1', 'SuperG 超级小 G', '双端都已经全部落地', 12, '2026-11-24 12:51:00.123+00:00', '["file:///Users/apple/SuperGarmin"]', 'CASCADE_RUN_STATUS_RUNNING', '', '', 0, 1, 0, '2026-11-24 12:50:00+00:00', 10),
			('root-2', 'Antigravity 大百科', '搞定收工', 8, '2026-11-24 09:42:00+00:00', '[]', 'CASCADE_RUN_STATUS_IDLE', '', '', 0, 0, 0, '2026-11-24 09:40:00+00:00', 6),
			('sub-1', 'subagent', '', 4, '2026-11-24 12:50:30+00:00', '["file:///Users/apple/SuperGarmin"]', 'CASCADE_RUN_STATUS_IDLE', '', 'root-1', 1, 0, 0, '2026-11-24 12:50:00+00:00', 0),
			('sub-2', 'nested sub', '', 2, '2026-11-24 12:50:40+00:00', '[]', 'CASCADE_RUN_STATUS_IDLE', '', 'sub-1', 2, 0, 0, '2026-11-24 12:50:00+00:00', 0);

		INSERT INTO conversation_parents VALUES ('sub-1', 'root-1'), ('sub-2', 'sub-1');
		INSERT INTO conversations_fts VALUES ('root-1', '2026-11-24 12:51:00+00:00', 'SuperG 超级小 G', 'SuperGarmin', '', '测试 Garmin 同步', '双端都已经全部落地');
	`)
	if err != nil {
		t.Fatal(err)
	}

	r := New(dbPath)
	list, err := r.ListRootSummaries(50)
	if err != nil {
		t.Fatalf("ListRootSummaries: %v", err)
	}
	if len(list) != 2 {
		t.Fatalf("expected 2 root summaries, got %d", len(list))
	}
	if list[0].ConversationID != "root-1" || list[0].Workspace.Label != "SuperGarmin" || !list[0].Running || list[0].SubagentCount != 2 {
		t.Fatalf("unexpected first summary: %+v", list[0])
	}
	if list[1].Workspace.Kind != "global" || list[1].Workspace.Label != "通用对话" {
		t.Fatalf("expected global workspace for root-2, got %+v", list[1].Workspace)
	}

	hits, err := r.Search("Garmin", 10)
	if err != nil {
		t.Fatalf("Search: %v", err)
	}
	if len(hits) != 1 || hits[0].ConversationID != "root-1" {
		t.Fatalf("unexpected search hits: %+v", hits)
	}
}

func TestUriToLocalPathWindowsDriveURI(t *testing.T) {
	got := uriToLocalPath("file:///C:/Users/demo/project")
	if strings.HasPrefix(got, "/") || strings.HasPrefix(got, `\`) {
		t.Fatalf("expected drive-letter path without leading slash, got %q", got)
	}
	if !strings.Contains(got, "C:") {
		t.Fatalf("expected drive letter C: in %q", got)
	}
}
