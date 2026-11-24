package filesandbox

import (
	"errors"
	"io"
	"io/fs"
	"mime"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

const (
	DefaultMaxTextBytes = 512 * 1024      // 512 KiB per paged text read
	MaxRawMediaBytes    = 20 * 1024 * 1024 // 20 MiB raw media limit
)

var (
	ErrPathForbidden = errors.New("path is outside allowed roots or blocked by security policy")
	ErrFileTooLarge  = errors.New("file exceeds maximum allowed streaming size")
	ErrNotRegular    = errors.New("target is not a regular file")
)

// ArtifactItem describes a user-visible file under ~/.gemini/antigravity/brain/<conv-id>/.
type ArtifactItem struct {
	Name      string `json:"name"`
	RelPath   string `json:"relPath"`
	FullPath  string `json:"fullPath"`
	SizeBytes int64  `json:"sizeBytes"`
	ModTime   int64  `json:"modTime"`
	Kind      string `json:"kind"` // "markdown" | "image" | "code" | "pdf" | "text" | "binary"
	MimeType  string `json:"mimeType"`
}

// TextContentPage holds a UTF-8 paged slice of a text/markdown/code file.
type TextContentPage struct {
	Path       string `json:"path"`
	Name       string `json:"name"`
	Kind       string `json:"kind"`
	MimeType   string `json:"mimeType"`
	Content    string `json:"content"`
	Offset     int64  `json:"offset"`
	TotalBytes int64  `json:"totalBytes"`
	Truncated  bool   `json:"truncated"`
}

var excludedArtifactDirs = map[string]struct{}{
	".system_generated": {},
	".user_uploaded":    {},
	"scratch":           {},
	"browser_sandbox":   {},
}

// ListArtifacts scans a conversation's brain directory and returns user-visible artifacts.
func ListArtifacts(brainConvDir string) ([]ArtifactItem, error) {
	info, err := os.Stat(brainConvDir)
	if err != nil {
		if os.IsNotExist(err) {
			return []ArtifactItem{}, nil
		}
		return nil, err
	}
	if !info.IsDir() {
		return []ArtifactItem{}, nil
	}

	var items []ArtifactItem
	err = filepath.WalkDir(brainConvDir, func(path string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return nil
		}
		if path == brainConvDir {
			return nil
		}
		name := d.Name()
		if d.IsDir() {
			if strings.HasPrefix(name, ".") {
				return filepath.SkipDir
			}
			if _, skip := excludedArtifactDirs[name]; skip {
				return filepath.SkipDir
			}
			return nil
		}
		if strings.HasPrefix(name, ".") || isSensitiveFilename(name) {
			return nil
		}
		fi, err := d.Info()
		if err != nil || !fi.Mode().IsRegular() {
			return nil
		}
		rel, err := filepath.Rel(brainConvDir, path)
		if err != nil {
			return nil
		}
		kind, mimeType := classifyFile(name)
		items = append(items, ArtifactItem{
			Name:      name,
			RelPath:   filepath.ToSlash(rel),
			FullPath:  path,
			SizeBytes: fi.Size(),
			ModTime:   fi.ModTime().Unix(),
			Kind:      kind,
			MimeType:  mimeType,
		})
		return nil
	})
	if err != nil {
		return nil, err
	}

	sort.Slice(items, func(i, j int) bool {
		if items[i].ModTime == items[j].ModTime {
			return items[i].RelPath < items[j].RelPath
		}
		return items[i].ModTime > items[j].ModTime
	})
	return items, nil
}

// ResolveAllowed validates that targetPath is a safe regular file inside one of allowedRoots.
func ResolveAllowed(targetPath string, allowedRoots []string) (string, os.FileInfo, error) {
	targetPath = strings.TrimSpace(targetPath)
	targetPath = strings.TrimPrefix(targetPath, "file://")
	if targetPath == "" || !filepath.IsAbs(targetPath) {
		return "", nil, ErrPathForbidden
	}

	resolvedTarget, err := filepath.EvalSymlinks(filepath.Clean(targetPath))
	if err != nil {
		return "", nil, err
	}
	fi, err := os.Stat(resolvedTarget)
	if err != nil {
		return "", nil, err
	}
	if !fi.Mode().IsRegular() {
		return "", nil, ErrNotRegular
	}

	if isSensitivePath(resolvedTarget) {
		return "", nil, ErrPathForbidden
	}

	for _, root := range allowedRoots {
		if strings.TrimSpace(root) == "" {
			continue
		}
		resolvedRoot, err := filepath.EvalSymlinks(filepath.Clean(root))
		if err != nil {
			continue
		}
		if isWithinRoot(resolvedTarget, resolvedRoot) {
			return resolvedTarget, fi, nil
		}
	}
	return "", nil, ErrPathForbidden
}

// ReadTextPage safely reads a paged text slice of a file inside allowedRoots.
func ReadTextPage(targetPath string, allowedRoots []string, offset, limit int64) (*TextContentPage, error) {
	resolved, fi, err := ResolveAllowed(targetPath, allowedRoots)
	if err != nil {
		return nil, err
	}
	if offset < 0 {
		offset = 0
	}
	if limit <= 0 || limit > DefaultMaxTextBytes {
		limit = DefaultMaxTextBytes
	}

	f, err := os.Open(resolved)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	if offset > 0 {
		if _, err := f.Seek(offset, io.SeekStart); err != nil {
			return nil, err
		}
	}

	buf, err := io.ReadAll(io.LimitReader(f, limit))
	if err != nil {
		return nil, err
	}

	name := filepath.Base(resolved)
	kind, mimeType := classifyFile(name)
	return &TextContentPage{
		Path:       resolved,
		Name:       name,
		Kind:       kind,
		MimeType:   mimeType,
		Content:    string(buf),
		Offset:     offset,
		TotalBytes: fi.Size(),
		Truncated:  offset+int64(len(buf)) < fi.Size(),
	}, nil
}

// OpenRaw safely opens a binary/media file within MaxRawMediaBytes.
func OpenRaw(targetPath string, allowedRoots []string) (*os.File, os.FileInfo, string, error) {
	resolved, fi, err := ResolveAllowed(targetPath, allowedRoots)
	if err != nil {
		return nil, nil, "", err
	}
	if fi.Size() > MaxRawMediaBytes {
		return nil, nil, "", ErrFileTooLarge
	}
	f, err := os.Open(resolved)
	if err != nil {
		return nil, nil, "", err
	}
	_, mimeType := classifyFile(filepath.Base(resolved))
	return f, fi, mimeType, nil
}

func isWithinRoot(target, root string) bool {
	rel, err := filepath.Rel(root, target)
	if err != nil {
		return false
	}
	if rel == "." {
		return true
	}
	return rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))
}

func isSensitivePath(fullPath string) bool {
	parts := strings.Split(filepath.ToSlash(fullPath), "/")
	for _, p := range parts {
		if p == ".git" || p == ".ssh" {
			return true
		}
	}
	return isSensitiveFilename(filepath.Base(fullPath))
}

func isSensitiveFilename(name string) bool {
	lower := strings.ToLower(name)
	if lower == ".env" || strings.HasPrefix(lower, ".env.") {
		return true
	}
	for _, suffix := range []string{".pem", ".key", ".p12", ".pfx", ".pb"} {
		if strings.HasSuffix(lower, suffix) {
			return true
		}
	}
	for _, prefix := range []string{"id_rsa", "id_ed25519", "id_ecdsa"} {
		if strings.HasPrefix(lower, prefix) {
			return true
		}
	}
	for _, kw := range []string{"credentials", "secret", "kubeconfig"} {
		if strings.Contains(lower, kw) && !strings.HasSuffix(lower, ".md") && !strings.HasSuffix(lower, ".go") {
			return true
		}
	}
	return false
}

func classifyFile(name string) (string, string) {
	ext := strings.ToLower(filepath.Ext(name))
	switch ext {
	case ".md", ".markdown":
		return "markdown", "text/markdown; charset=utf-8"
	case ".png":
		return "image", "image/png"
	case ".jpg", ".jpeg":
		return "image", "image/jpeg"
	case ".webp":
		return "image", "image/webp"
	case ".gif":
		return "image", "image/gif"
	case ".svg":
		return "image", "image/svg+xml"
	case ".pdf":
		return "pdf", "application/pdf"
	case ".go", ".dart", ".kt", ".java", ".ts", ".tsx", ".js", ".jsx", ".py", ".rs", ".sh", ".yaml", ".yml", ".json", ".toml", ".sql", ".css", ".html", ".xml", ".swift", ".c", ".cpp", ".h":
		return "code", "text/plain; charset=utf-8"
	case ".txt", ".log", ".csv":
		return "text", "text/plain; charset=utf-8"
	default:
		mt := mime.TypeByExtension(ext)
		if mt == "" {
			mt = "application/octet-stream"
		}
		if strings.HasPrefix(mt, "text/") {
			return "text", mt
		}
		return "binary", mt
	}
}
