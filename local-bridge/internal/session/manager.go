package session

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"fmt"
	"log/slog"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"

	"github.com/echothink/godot-local-bridge/internal/config"
)

var (
	featuresVersionPattern = regexp.MustCompile(`config/features\s*=\s*PackedStringArray\("([0-9]+\.[0-9]+(?:\.[0-9]+)?)"`)
	configVersionPattern   = regexp.MustCompile(`config/version\s*=\s*"([^"]+)"`)
)

// SessionInfo describes the current editor-side session context.
type SessionInfo struct {
	SessionID     string
	Nonce         string
	ProjectDir    string
	WorkspaceID   string
	CurrentBranch string
	HeadCommit    string
	GodotVersion  string
	ProjectValid  bool
}

// SessionManager manages the lifecycle of the local editor session.
type SessionManager struct {
	config *config.Config
	logger *slog.Logger

	mu   sync.RWMutex
	info *SessionInfo
}

// NewSessionManager constructs a SessionManager.
func NewSessionManager(cfg *config.Config, logger *slog.Logger) *SessionManager {
	if logger == nil {
		logger = slog.Default()
	}

	return &SessionManager{
		config: cfg,
		logger: logger,
	}
}

// Bootstrap discovers project metadata and creates a fresh session nonce.
func (sm *SessionManager) Bootstrap() (*SessionInfo, error) {
	if sm.config == nil {
		return nil, fmt.Errorf("bootstrap session: config is nil")
	}

	projectDir := filepath.Clean(strings.TrimSpace(sm.config.ProjectDir))
	if projectDir == "" || projectDir == "." {
		return nil, fmt.Errorf("bootstrap session: project directory is required")
	}

	projectInfo, err := os.Stat(projectDir)
	if err != nil {
		return nil, fmt.Errorf("bootstrap session: stat project directory %q: %w", projectDir, err)
	}
	if !projectInfo.IsDir() {
		return nil, fmt.Errorf("bootstrap session: project path %q is not a directory", projectDir)
	}

	sessionID, err := randomToken(16)
	if err != nil {
		return nil, fmt.Errorf("bootstrap session: generate session ID: %w", err)
	}
	nonce, err := randomToken(32)
	if err != nil {
		return nil, fmt.Errorf("bootstrap session: generate session nonce: %w", err)
	}

	info := &SessionInfo{
		SessionID:   sessionID,
		Nonce:       nonce,
		ProjectDir:  projectDir,
		WorkspaceID: strings.TrimSpace(sm.config.WorkspaceID),
	}

	projectFile := filepath.Join(projectDir, "project.godot")
	projectData, err := os.ReadFile(projectFile)
	if err != nil {
		if os.IsNotExist(err) {
			sm.logger.Warn("Godot project file not found", "project_file", projectFile)
		} else {
			return nil, fmt.Errorf("bootstrap session: read project file %q: %w", projectFile, err)
		}
	} else {
		info.ProjectValid = true
		info.GodotVersion = detectGodotVersion(projectData)
	}

	gitDir, err := resolveGitDir(projectDir)
	if err != nil {
		return nil, fmt.Errorf("bootstrap session: resolve git directory: %w", err)
	}
	if gitDir != "" {
		branch, commit, err := readGitState(gitDir)
		if err != nil {
			sm.logger.Warn("failed to inspect git state", "git_dir", gitDir, "error", err)
		} else {
			info.CurrentBranch = branch
			info.HeadCommit = commit
		}
	}

	sm.mu.Lock()
	sm.info = cloneSessionInfo(info)
	sm.mu.Unlock()

	sm.logger.Info(
		"session bootstrapped",
		"session_id", info.SessionID,
		"workspace_id", info.WorkspaceID,
		"project_valid", info.ProjectValid,
		"branch", info.CurrentBranch,
	)

	return cloneSessionInfo(info), nil
}

// ValidateNonce returns true when nonce matches the active session nonce.
func (sm *SessionManager) ValidateNonce(nonce string) bool {
	sm.mu.RLock()
	defer sm.mu.RUnlock()

	if sm.info == nil || sm.info.Nonce == "" {
		return false
	}

	nonce = strings.TrimSpace(nonce)
	if nonce == "" {
		return false
	}

	return subtle.ConstantTimeCompare([]byte(sm.info.Nonce), []byte(nonce)) == 1
}

// GetSessionInfo returns a copy of the current session metadata.
func (sm *SessionManager) GetSessionInfo() *SessionInfo {
	sm.mu.RLock()
	defer sm.mu.RUnlock()
	return cloneSessionInfo(sm.info)
}

func cloneSessionInfo(info *SessionInfo) *SessionInfo {
	if info == nil {
		return nil
	}
	cloned := *info
	return &cloned
}

func randomToken(size int) (string, error) {
	bytes := make([]byte, size)
	if _, err := rand.Read(bytes); err != nil {
		return "", err
	}
	return hex.EncodeToString(bytes), nil
}

func detectGodotVersion(projectData []byte) string {
	content := string(projectData)
	if matches := featuresVersionPattern.FindStringSubmatch(content); len(matches) == 2 {
		return matches[1]
	}
	if matches := configVersionPattern.FindStringSubmatch(content); len(matches) == 2 {
		return matches[1]
	}
	return ""
}

func resolveGitDir(projectDir string) (string, error) {
	gitPath := filepath.Join(projectDir, ".git")
	info, err := os.Stat(gitPath)
	if err != nil {
		if os.IsNotExist(err) {
			return "", nil
		}
		return "", err
	}

	if info.IsDir() {
		return gitPath, nil
	}

	data, err := os.ReadFile(gitPath)
	if err != nil {
		return "", err
	}
	line := strings.TrimSpace(string(data))
	if !strings.HasPrefix(line, "gitdir:") {
		return "", fmt.Errorf("unexpected .git file format in %q", gitPath)
	}

	dir := strings.TrimSpace(strings.TrimPrefix(line, "gitdir:"))
	if dir == "" {
		return "", fmt.Errorf("empty gitdir in %q", gitPath)
	}
	if !filepath.IsAbs(dir) {
		dir = filepath.Join(projectDir, dir)
	}

	return filepath.Clean(dir), nil
}

func readGitState(gitDir string) (string, string, error) {
	headPath := filepath.Join(gitDir, "HEAD")
	headData, err := os.ReadFile(headPath)
	if err != nil {
		return "", "", fmt.Errorf("read HEAD: %w", err)
	}

	head := strings.TrimSpace(string(headData))
	if head == "" {
		return "", "", fmt.Errorf("HEAD is empty")
	}

	if strings.HasPrefix(head, "ref:") {
		ref := strings.TrimSpace(strings.TrimPrefix(head, "ref:"))
		commit, err := readGitRef(gitDir, ref)
		if err != nil {
			return path.Base(ref), "", err
		}
		return path.Base(ref), commit, nil
	}

	return "detached", head, nil
}

func readGitRef(gitDir, ref string) (string, error) {
	refPath := filepath.Join(gitDir, filepath.FromSlash(ref))
	data, err := os.ReadFile(refPath)
	if err == nil {
		return strings.TrimSpace(string(data)), nil
	}
	if !os.IsNotExist(err) {
		return "", err
	}

	packedRefPath := filepath.Join(gitDir, "packed-refs")
	packedData, packedErr := os.ReadFile(packedRefPath)
	if packedErr != nil {
		if os.IsNotExist(packedErr) {
			return "", fmt.Errorf("reference %q not found", ref)
		}
		return "", packedErr
	}

	for _, line := range strings.Split(string(packedData), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") || strings.HasPrefix(line, "^") {
			continue
		}

		fields := strings.Fields(line)
		if len(fields) != 2 {
			continue
		}
		if fields[1] == ref {
			return fields[0], nil
		}
	}

	return "", fmt.Errorf("reference %q not found", ref)
}

func sortedRefs(refs map[string]string) []string {
	keys := make([]string, 0, len(refs))
	for key := range refs {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}
