package git

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

const gitCommandTimeout = 30 * time.Second

var packageLogger = slog.Default()

// Status describes the working tree state of a project repository.
type Status struct {
	Branch      string
	Commit      string
	RemoteURL   string
	Modified    []string
	Untracked   []string
	Staged      []string
	IsClean     bool
	HasUnpushed bool
}

// DiffEntry describes a single changed file from git diff output.
type DiffEntry struct {
	Path    string
	OldPath string
	Type    string
	Hunks   []string
}

// Error captures structured execution and validation failures for git calls.
type Error struct {
	Op     string
	Dir    string
	Args   []string
	Output string
	Err    error
}

func (e *Error) Error() string {
	if e == nil {
		return "git: <nil>"
	}

	var parts []string
	if strings.TrimSpace(e.Op) != "" {
		parts = append(parts, e.Op)
	}
	if strings.TrimSpace(e.Dir) != "" {
		parts = append(parts, fmt.Sprintf("dir=%q", e.Dir))
	}
	if len(e.Args) > 0 {
		parts = append(parts, fmt.Sprintf("args=%q", strings.Join(e.Args, " ")))
	}
	if strings.TrimSpace(e.Output) != "" {
		parts = append(parts, fmt.Sprintf("output=%q", truncate(e.Output, 240)))
	}
	if e.Err != nil {
		parts = append(parts, e.Err.Error())
	}

	return "git: " + strings.Join(parts, ": ")
}

func (e *Error) Unwrap() error {
	if e == nil {
		return nil
	}
	return e.Err
}

// GetStatus reads the repository branch, commit, staged, unstaged, and
// untracked file state from projectDir.
func GetStatus(ctx context.Context, projectDir string) (*Status, error) {
	projectDir, err := validateProjectDir(projectDir)
	if err != nil {
		return nil, err
	}
	if ctx == nil {
		return nil, &Error{Op: "get status", Dir: projectDir, Err: errors.New("context is nil")}
	}

	statusOutput, err := runGit(ctx, projectDir, "status", "--porcelain=1", "--branch")
	if err != nil {
		return nil, &Error{Op: "get status", Dir: projectDir, Err: err}
	}

	commit, err := runGit(ctx, projectDir, "rev-parse", "HEAD")
	if err != nil {
		return nil, &Error{Op: "get status", Dir: projectDir, Err: err}
	}

	remoteURL, _ := runGitOptional(ctx, projectDir, "config", "--get", "remote.origin.url")
	status := &Status{
		Commit:    strings.TrimSpace(commit),
		RemoteURL: strings.TrimSpace(remoteURL),
	}

	lines := splitNonEmptyLines(statusOutput)
	if len(lines) > 0 && strings.HasPrefix(lines[0], "## ") {
		status.Branch = parseStatusBranch(lines[0])
		status.HasUnpushed = parseAheadFlag(lines[0])
		lines = lines[1:]
	}

	for _, line := range lines {
		if len(line) < 3 {
			continue
		}

		code := line[:2]
		path := parsePorcelainPath(line[3:])
		if path == "" {
			continue
		}

		x := code[0]
		y := code[1]

		switch {
		case x == '?' && y == '?':
			status.Untracked = append(status.Untracked, path)
		default:
			if x != ' ' && x != '?' {
				status.Staged = append(status.Staged, path)
			}
			if y != ' ' {
				status.Modified = append(status.Modified, path)
			}
		}
	}

	status.Modified = uniqueSorted(status.Modified)
	status.Staged = uniqueSorted(status.Staged)
	status.Untracked = uniqueSorted(status.Untracked)
	status.IsClean = len(status.Modified) == 0 && len(status.Staged) == 0 && len(status.Untracked) == 0

	if !status.HasUnpushed {
		status.HasUnpushed = hasUnpushedCommits(ctx, projectDir)
	}

	packageLogger.Debug("git status collected",
		"project_dir", projectDir,
		"branch", status.Branch,
		"clean", status.IsClean,
		"unpushed", status.HasUnpushed,
	)

	return status, nil
}

// GetDiff returns changed files and unified hunk headers for either the staged
// or unstaged diff.
func GetDiff(ctx context.Context, projectDir string, cached bool) ([]DiffEntry, error) {
	projectDir, err := validateProjectDir(projectDir)
	if err != nil {
		return nil, err
	}
	if ctx == nil {
		return nil, &Error{Op: "get diff", Dir: projectDir, Err: errors.New("context is nil")}
	}

	args := []string{"diff", "--name-status", "--find-renames"}
	if cached {
		args = append(args, "--cached")
	}

	output, err := runGit(ctx, projectDir, args...)
	if err != nil {
		return nil, &Error{Op: "get diff", Dir: projectDir, Err: err}
	}

	entries := make([]DiffEntry, 0)
	for _, line := range splitNonEmptyLines(output) {
		entry, ok, parseErr := parseNameStatusLine(line)
		if parseErr != nil {
			return nil, &Error{Op: "get diff", Dir: projectDir, Output: line, Err: parseErr}
		}
		if !ok {
			continue
		}

		diffArgs := []string{"diff", "-U0", "--find-renames"}
		if cached {
			diffArgs = append(diffArgs, "--cached")
		}
		if entry.OldPath != "" {
			diffArgs = append(diffArgs, "--", entry.OldPath, entry.Path)
		} else {
			diffArgs = append(diffArgs, "--", entry.Path)
		}

		diffOutput, diffErr := runGit(ctx, projectDir, diffArgs...)
		if diffErr != nil {
			return nil, &Error{Op: "get diff", Dir: projectDir, Err: diffErr}
		}

		entry.Hunks = parseHunks(diffOutput)
		entries = append(entries, entry)
	}

	return entries, nil
}

// ListBranches lists local branches and returns the current branch when the
// repository is not in detached HEAD mode.
func ListBranches(ctx context.Context, projectDir string) (current string, branches []string, err error) {
	projectDir, err = validateProjectDir(projectDir)
	if err != nil {
		return "", nil, err
	}
	if ctx == nil {
		return "", nil, &Error{Op: "list branches", Dir: projectDir, Err: errors.New("context is nil")}
	}

	current, err = runGit(ctx, projectDir, "branch", "--show-current")
	if err != nil {
		return "", nil, &Error{Op: "list branches", Dir: projectDir, Err: err}
	}

	output, err := runGit(ctx, projectDir, "for-each-ref", "--format=%(refname:short)", "refs/heads")
	if err != nil {
		return "", nil, &Error{Op: "list branches", Dir: projectDir, Err: err}
	}

	return strings.TrimSpace(current), uniqueSorted(splitNonEmptyLines(output)), nil
}

// CheckoutBranch switches the repository worktree to branch.
func CheckoutBranch(ctx context.Context, projectDir, branch string) error {
	projectDir, err := validateProjectDir(projectDir)
	if err != nil {
		return err
	}
	if ctx == nil {
		return &Error{Op: "checkout branch", Dir: projectDir, Err: errors.New("context is nil")}
	}
	branch = strings.TrimSpace(branch)
	if branch == "" {
		return &Error{Op: "checkout branch", Dir: projectDir, Err: errors.New("branch is required")}
	}

	if _, err := runGit(ctx, projectDir, "check-ref-format", "--branch", branch); err != nil {
		return &Error{Op: "checkout branch", Dir: projectDir, Err: err}
	}

	if _, err := runGit(ctx, projectDir, "checkout", branch); err != nil {
		return &Error{Op: "checkout branch", Dir: projectDir, Err: err}
	}
	return nil
}

// CreateBranch creates a new local branch from base without checking it out.
func CreateBranch(ctx context.Context, projectDir, name, base string) error {
	projectDir, err := validateProjectDir(projectDir)
	if err != nil {
		return err
	}
	if ctx == nil {
		return &Error{Op: "create branch", Dir: projectDir, Err: errors.New("context is nil")}
	}

	name = strings.TrimSpace(name)
	if name == "" {
		return &Error{Op: "create branch", Dir: projectDir, Err: errors.New("branch name is required")}
	}
	if _, err := runGit(ctx, projectDir, "check-ref-format", "--branch", name); err != nil {
		return &Error{Op: "create branch", Dir: projectDir, Err: err}
	}

	args := []string{"branch", name}
	base = strings.TrimSpace(base)
	if base != "" {
		if _, err := runGit(ctx, projectDir, "rev-parse", "--verify", base+"^{commit}"); err != nil {
			return &Error{Op: "create branch", Dir: projectDir, Err: err}
		}
		args = append(args, base)
	}

	if _, err := runGit(ctx, projectDir, args...); err != nil {
		return &Error{Op: "create branch", Dir: projectDir, Err: err}
	}
	return nil
}

// ApplyPatch applies a unified diff patch to the working tree with git apply.
func ApplyPatch(ctx context.Context, projectDir string, patchContent []byte) error {
	projectDir, err := validateProjectDir(projectDir)
	if err != nil {
		return err
	}
	if ctx == nil {
		return &Error{Op: "apply patch", Dir: projectDir, Err: errors.New("context is nil")}
	}
	if len(bytes.TrimSpace(patchContent)) == 0 {
		return &Error{Op: "apply patch", Dir: projectDir, Err: errors.New("patch content is required")}
	}

	if _, err := runGitInput(ctx, projectDir, patchContent, "apply", "--recount", "--whitespace=nowarn", "-"); err != nil {
		return &Error{Op: "apply patch", Dir: projectDir, Err: err}
	}
	return nil
}

// StageFiles stages the provided paths in the index.
func StageFiles(ctx context.Context, projectDir string, paths []string) error {
	projectDir, err := validateProjectDir(projectDir)
	if err != nil {
		return err
	}
	if ctx == nil {
		return &Error{Op: "stage files", Dir: projectDir, Err: errors.New("context is nil")}
	}
	if len(paths) == 0 {
		return &Error{Op: "stage files", Dir: projectDir, Err: errors.New("paths are required")}
	}

	pathSpecs, err := normalizePathSpecs(projectDir, paths)
	if err != nil {
		return &Error{Op: "stage files", Dir: projectDir, Err: err}
	}

	args := append([]string{"add", "--"}, pathSpecs...)
	if _, err := runGit(ctx, projectDir, args...); err != nil {
		return &Error{Op: "stage files", Dir: projectDir, Err: err}
	}
	return nil
}

// CreateCommit creates a git commit from the staged index.
func CreateCommit(ctx context.Context, projectDir, message string) error {
	projectDir, err := validateProjectDir(projectDir)
	if err != nil {
		return err
	}
	if ctx == nil {
		return &Error{Op: "create commit", Dir: projectDir, Err: errors.New("context is nil")}
	}
	message = strings.TrimSpace(message)
	if message == "" {
		return &Error{Op: "create commit", Dir: projectDir, Err: errors.New("commit message is required")}
	}

	if _, err := runGit(ctx, projectDir, "commit", "--message", message); err != nil {
		return &Error{Op: "create commit", Dir: projectDir, Err: err}
	}
	return nil
}

// runGit executes git in dir with a bounded timeout and returns stdout.
func runGit(ctx context.Context, dir string, args ...string) (string, error) {
	return runGitInput(ctx, dir, nil, args...)
}

func runGitInput(ctx context.Context, dir string, input []byte, args ...string) (string, error) {
	dir, err := validateProjectDir(dir)
	if err != nil {
		return "", err
	}
	if ctx == nil {
		return "", &Error{Op: "run git", Dir: dir, Args: append([]string(nil), args...), Err: errors.New("context is nil")}
	}
	if len(args) == 0 {
		return "", &Error{Op: "run git", Dir: dir, Err: errors.New("git arguments are required")}
	}

	cmdCtx, cancel := context.WithTimeout(ctx, gitCommandTimeout)
	defer cancel()

	cmd := exec.CommandContext(cmdCtx, "git", args...)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), "LC_ALL=C", "LANG=C")
	if len(input) > 0 {
		cmd.Stdin = bytes.NewReader(input)
	}

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	packageLogger.Debug("running git command", "dir", dir, "args", args)
	err = cmd.Run()
	stdoutText := strings.TrimSpace(stdout.String())
	stderrText := strings.TrimSpace(stderr.String())
	if err != nil {
		output := stderrText
		if output == "" {
			output = stdoutText
		}
		if cmdCtx.Err() != nil {
			err = cmdCtx.Err()
		}
		packageLogger.Warn("git command failed", "dir", dir, "args", args, "error", err, "output", output)
		return "", &Error{Op: "run git", Dir: dir, Args: append([]string(nil), args...), Output: output, Err: err}
	}

	if stderrText != "" {
		packageLogger.Debug("git command stderr", "dir", dir, "args", args, "stderr", stderrText)
	}

	return stdoutText, nil
}

func validateProjectDir(projectDir string) (string, error) {
	projectDir = filepath.Clean(strings.TrimSpace(projectDir))
	if projectDir == "" || projectDir == "." {
		return "", &Error{Op: "validate project dir", Err: errors.New("project directory is required")}
	}

	info, err := os.Stat(projectDir)
	if err != nil {
		return "", &Error{Op: "validate project dir", Dir: projectDir, Err: err}
	}
	if !info.IsDir() {
		return "", &Error{Op: "validate project dir", Dir: projectDir, Err: errors.New("project path is not a directory")}
	}

	return projectDir, nil
}

func runGitOptional(ctx context.Context, dir string, args ...string) (string, error) {
	output, err := runGit(ctx, dir, args...)
	if err != nil {
		packageLogger.Debug("optional git command failed", "dir", dir, "args", args, "error", err)
		return "", err
	}
	return output, nil
}

func hasUnpushedCommits(ctx context.Context, dir string) bool {
	if _, err := runGitOptional(ctx, dir, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"); err != nil {
		return false
	}

	output, err := runGitOptional(ctx, dir, "rev-list", "--left-right", "--count", "@{upstream}...HEAD")
	if err != nil {
		return false
	}

	fields := strings.Fields(output)
	if len(fields) != 2 {
		return false
	}

	ahead, convErr := strconv.Atoi(fields[1])
	if convErr != nil {
		return false
	}

	return ahead > 0
}

func parseStatusBranch(line string) string {
	line = strings.TrimSpace(strings.TrimPrefix(line, "##"))
	if line == "" {
		return ""
	}

	branchPart := line
	if idx := strings.Index(branchPart, "..."); idx >= 0 {
		branchPart = branchPart[:idx]
	}
	if idx := strings.Index(branchPart, " ["); idx >= 0 {
		branchPart = branchPart[:idx]
	}
	branchPart = strings.TrimSpace(branchPart)
	if strings.HasPrefix(branchPart, "HEAD") {
		return ""
	}
	return branchPart
}

func parseAheadFlag(line string) bool {
	lower := strings.ToLower(line)
	return strings.Contains(lower, "[ahead ")
}

func splitNonEmptyLines(output string) []string {
	if strings.TrimSpace(output) == "" {
		return nil
	}

	scanner := bufio.NewScanner(strings.NewReader(output))
	lines := make([]string, 0)
	for scanner.Scan() {
		line := strings.TrimRight(scanner.Text(), "\r")
		if strings.TrimSpace(line) == "" {
			continue
		}
		lines = append(lines, line)
	}
	return lines
}

func parsePorcelainPath(value string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return ""
	}

	if strings.Contains(value, " -> ") {
		parts := strings.Split(value, " -> ")
		value = parts[len(parts)-1]
	}

	if strings.HasPrefix(value, "\"") {
		if unquoted, err := strconv.Unquote(value); err == nil {
			value = unquoted
		}
	}

	return filepath.ToSlash(value)
}

func parseNameStatusLine(line string) (DiffEntry, bool, error) {
	fields := strings.Split(line, "\t")
	if len(fields) < 2 {
		return DiffEntry{}, false, fmt.Errorf("unexpected diff status line %q", line)
	}

	statusCode := strings.TrimSpace(fields[0])
	if statusCode == "" {
		return DiffEntry{}, false, fmt.Errorf("empty diff status in %q", line)
	}

	entry := DiffEntry{}
	switch statusCode[0] {
	case 'A':
		entry.Type = "added"
		entry.Path = parsePorcelainPath(fields[1])
	case 'M', 'T', 'C':
		entry.Type = "modified"
		entry.Path = parsePorcelainPath(fields[1])
	case 'D':
		entry.Type = "deleted"
		entry.Path = parsePorcelainPath(fields[1])
	case 'R':
		if len(fields) < 3 {
			return DiffEntry{}, false, fmt.Errorf("rename diff entry missing target in %q", line)
		}
		entry.Type = "renamed"
		entry.OldPath = parsePorcelainPath(fields[1])
		entry.Path = parsePorcelainPath(fields[2])
	default:
		return DiffEntry{}, false, nil
	}

	if entry.Path == "" {
		return DiffEntry{}, false, fmt.Errorf("diff entry path is empty in %q", line)
	}

	return entry, true, nil
}

func parseHunks(diffOutput string) []string {
	hunks := make([]string, 0)
	for _, line := range splitNonEmptyLines(diffOutput) {
		if strings.HasPrefix(line, "@@") {
			hunks = append(hunks, line)
		}
	}
	return hunks
}

func normalizePathSpecs(projectDir string, paths []string) ([]string, error) {
	seen := make(map[string]struct{}, len(paths))
	result := make([]string, 0, len(paths))

	for _, path := range paths {
		path = strings.TrimSpace(path)
		if path == "" {
			return nil, errors.New("path list contains an empty entry")
		}

		var rel string
		if filepath.IsAbs(path) {
			abs := filepath.Clean(path)
			relPath, err := filepath.Rel(projectDir, abs)
			if err != nil {
				return nil, fmt.Errorf("normalize path %q: %w", path, err)
			}
			if isOutsideRoot(relPath) {
				return nil, fmt.Errorf("path %q escapes project directory", path)
			}
			rel = relPath
		} else {
			rel = filepath.Clean(path)
			if rel == "." || isOutsideRoot(rel) {
				return nil, fmt.Errorf("path %q escapes project directory", path)
			}
		}

		rel = filepath.ToSlash(rel)
		if _, ok := seen[rel]; ok {
			continue
		}
		seen[rel] = struct{}{}
		result = append(result, rel)
	}

	sort.Strings(result)
	return result, nil
}

func uniqueSorted(values []string) []string {
	if len(values) == 0 {
		return nil
	}

	seen := make(map[string]struct{}, len(values))
	result := make([]string, 0, len(values))
	for _, value := range values {
		value = filepath.ToSlash(strings.TrimSpace(value))
		if value == "" {
			continue
		}
		if _, ok := seen[value]; ok {
			continue
		}
		seen[value] = struct{}{}
		result = append(result, value)
	}
	sort.Strings(result)
	return result
}

func isOutsideRoot(path string) bool {
	return path == ".." || strings.HasPrefix(path, ".."+string(filepath.Separator))
}

func truncate(value string, limit int) string {
	if limit <= 0 || len(value) <= limit {
		return value
	}
	return value[:limit] + "..."
}
