package filesandbox

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestSandboxSecurityAndPaging(t *testing.T) {
	base := t.TempDir()
	brainDir := filepath.Join(base, "brain", "conv1")
	wsDir := filepath.Join(base, "workspace")
	outsideDir := filepath.Join(base, "outside")
	for _, d := range []string{
		filepath.Join(brainDir, ".system_generated"),
		filepath.Join(brainDir, "scratch"),
		wsDir,
		outsideDir,
	} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}

	planPath := filepath.Join(brainDir, "plan.md")
	_ = os.WriteFile(planPath, []byte("# Plan\nHello Antigravity"), 0o644)
	_ = os.WriteFile(filepath.Join(brainDir, ".system_generated", "internal.json"), []byte("{}"), 0o644)
	_ = os.WriteFile(filepath.Join(brainDir, "scratch", "tmp.txt"), []byte("tmp"), 0o644)
	_ = os.WriteFile(filepath.Join(wsDir, ".env"), []byte("SECRET=123"), 0o644)
	_ = os.WriteFile(filepath.Join(wsDir, "main.go"), []byte("package main\n"), 0o644)
	outsideFile := filepath.Join(outsideDir, "secret.txt")
	_ = os.WriteFile(outsideFile, []byte("topsecret"), 0o644)
	symlinkEscape := filepath.Join(wsDir, "escape.txt")
	_ = os.Symlink(outsideFile, symlinkEscape)

	// 1. Artifact listing ignores .system_generated and scratch
	artifacts, err := ListArtifacts(brainDir)
	if err != nil {
		t.Fatalf("ListArtifacts: %v", err)
	}
	if len(artifacts) != 1 || artifacts[0].Name != "plan.md" || artifacts[0].Kind != "markdown" {
		t.Fatalf("unexpected artifacts: %+v", artifacts)
	}

	roots := []string{brainDir, wsDir}

	// 2. Allowed file with file:// prefix and pagination
	page, err := ReadTextPage("file://"+planPath, roots, 0, 6)
	if err != nil {
		t.Fatalf("ReadTextPage allowed: %v", err)
	}
	if page.Content != "# Plan" || !page.Truncated {
		t.Fatalf("unexpected page: %+v", page)
	}

	// 3. Sensitive .env blocked
	if _, err := ReadTextPage(filepath.Join(wsDir, ".env"), roots, 0, 100); !errors.Is(err, ErrPathForbidden) {
		t.Fatalf("expected ErrPathForbidden for .env, got %v", err)
	}

	// 4. Directory traversal blocked
	if _, err := ReadTextPage(filepath.Join(wsDir, "..", "outside", "secret.txt"), roots, 0, 100); !errors.Is(err, ErrPathForbidden) {
		t.Fatalf("expected ErrPathForbidden for traversal, got %v", err)
	}

	// 5. Symlink escape blocked
	if _, err := ReadTextPage(symlinkEscape, roots, 0, 100); !errors.Is(err, ErrPathForbidden) {
		t.Fatalf("expected ErrPathForbidden for symlink escape, got %v", err)
	}
}
