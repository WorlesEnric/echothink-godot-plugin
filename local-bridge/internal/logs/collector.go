package logs

import (
	"bufio"
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"time"
)

var packageLogger = slog.Default()

// Entry is one parsed log record with optional structured context.
type Entry struct {
	Timestamp string         `json:"timestamp"`
	Source    string         `json:"source"`
	Level     string         `json:"level"`
	Message   string         `json:"message"`
	Context   map[string]any `json:"context,omitempty"`
}

// Bundle packages a set of collected entries for upload or inspection.
type Bundle struct {
	BundleID    string  `json:"bundle_id"`
	ProjectDir  string  `json:"project_dir"`
	Entries     []Entry `json:"entries"`
	CollectedAt string  `json:"collected_at"`
}

// Error captures structured collection failures.
type Error struct {
	Op   string
	Path string
	Err  error
}

func (e *Error) Error() string {
	if e == nil {
		return "logs: <nil>"
	}

	var parts []string
	if strings.TrimSpace(e.Op) != "" {
		parts = append(parts, e.Op)
	}
	if strings.TrimSpace(e.Path) != "" {
		parts = append(parts, fmt.Sprintf("path=%q", e.Path))
	}
	if e.Err != nil {
		parts = append(parts, e.Err.Error())
	}

	return "logs: " + strings.Join(parts, ": ")
}

func (e *Error) Unwrap() error {
	if e == nil {
		return nil
	}
	return e.Err
}

// CollectEditorLogs reads Godot editor log directories and returns a packaged bundle.
func CollectEditorLogs(projectDir string) (*Bundle, error) {
	projectDir, err := validateProjectDir(projectDir)
	if err != nil {
		return nil, err
	}

	projectName := detectProjectName(projectDir)
	dirs := candidateLogDirs(projectDir, projectName)
	entries := make([]Entry, 0)
	seenDirs := make(map[string]struct{}, len(dirs))

	for _, dir := range dirs {
		dir = filepath.Clean(strings.TrimSpace(dir))
		if dir == "" {
			continue
		}
		if _, ok := seenDirs[dir]; ok {
			continue
		}
		seenDirs[dir] = struct{}{}

		collected, err := readLogDir(dir, "editor")
		if err != nil {
			return nil, err
		}
		entries = append(entries, collected...)
	}

	packageLogger.Debug("collected editor logs", "project_dir", projectDir, "entries", len(entries))

	return PackageBundle(entries, projectDir), nil
}

// CollectImportErrors scans Godot import caches for likely error indicators.
func CollectImportErrors(projectDir string) ([]Entry, error) {
	projectDir, err := validateProjectDir(projectDir)
	if err != nil {
		return nil, err
	}

	roots := []string{
		filepath.Join(projectDir, ".godot", "imported"),
		filepath.Join(projectDir, ".import"),
	}

	entries := make([]Entry, 0)
	seen := make(map[string]struct{})
	for _, root := range roots {
		walkErr := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
			if err != nil {
				if errors.Is(err, os.ErrNotExist) {
					return nil
				}
				return err
			}
			if d.IsDir() {
				return nil
			}

			indicators, indicatorErr := importErrorEntries(projectDir, path)
			if indicatorErr != nil {
				return indicatorErr
			}
			for _, entry := range indicators {
				key := entry.Timestamp + "|" + entry.Message
				if _, ok := seen[key]; ok {
					continue
				}
				seen[key] = struct{}{}
				entries = append(entries, entry)
			}
			return nil
		})
		if walkErr != nil && !errors.Is(walkErr, os.ErrNotExist) {
			return nil, &Error{Op: "collect import errors", Path: root, Err: walkErr}
		}
	}

	sortEntries(entries)
	packageLogger.Debug("collected import errors", "project_dir", projectDir, "entries", len(entries))
	return entries, nil
}

// CollectSystemInfo returns basic runtime and tooling facts for troubleshooting.
func CollectSystemInfo() map[string]string {
	info := map[string]string{
		"os":         runtime.GOOS,
		"arch":       runtime.GOARCH,
		"go_version": runtime.Version(),
	}

	if hostname, err := os.Hostname(); err == nil && strings.TrimSpace(hostname) != "" {
		info["hostname"] = hostname
	}
	if version := detectGodotVersion(); version != "" {
		info["godot_version"] = version
	}

	return info
}

// PackageBundle returns a bundle with a generated ID and timestamp.
func PackageBundle(entries []Entry, projectDir string) *Bundle {
	clone := append([]Entry(nil), entries...)
	for idx := range clone {
		if clone[idx].Timestamp == "" {
			clone[idx].Timestamp = time.Now().UTC().Format(time.RFC3339Nano)
		}
		clone[idx].Source = normalizeSource(clone[idx].Source)
		clone[idx].Level = normalizeLevel(clone[idx].Level)
	}
	sortEntries(clone)

	return &Bundle{
		BundleID:    newBundleID(),
		ProjectDir:  filepath.Clean(strings.TrimSpace(projectDir)),
		Entries:     clone,
		CollectedAt: time.Now().UTC().Format(time.RFC3339Nano),
	}
}

// FilterByLevel returns entries at or above minLevel.
func FilterByLevel(entries []Entry, minLevel string) []Entry {
	minimum := levelRank(minLevel)
	filtered := make([]Entry, 0, len(entries))
	for _, entry := range entries {
		if levelRank(entry.Level) >= minimum {
			filtered = append(filtered, entry)
		}
	}
	return filtered
}

// FilterBySource returns entries whose source matches source, case-insensitively.
func FilterBySource(entries []Entry, source string) []Entry {
	source = normalizeSource(source)
	filtered := make([]Entry, 0, len(entries))
	for _, entry := range entries {
		if normalizeSource(entry.Source) == source {
			filtered = append(filtered, entry)
		}
	}
	return filtered
}

// parseLogLine parses one log line into an Entry when it carries useful content.
func parseLogLine(line string) *Entry {
	line = strings.TrimSpace(strings.TrimRight(line, "\r"))
	if line == "" {
		return nil
	}

	entry := &Entry{
		Source:  "editor",
		Level:   "info",
		Message: line,
	}

	if ts, rest := parseTimestampPrefix(line); ts != "" {
		entry.Timestamp = ts
		line = rest
	}

	if source, rest := parseSourcePrefix(line); source != "" {
		entry.Source = source
		line = rest
	}
	if level, rest := parseLevelPrefix(line); level != "" {
		entry.Level = level
		line = rest
	}

	entry.Message = strings.TrimSpace(line)
	if entry.Message == "" {
		return nil
	}

	if ctx := parseLineContext(entry.Message); len(ctx) > 0 {
		entry.Context = ctx
	}

	return entry
}

func validateProjectDir(projectDir string) (string, error) {
	projectDir = filepath.Clean(strings.TrimSpace(projectDir))
	if projectDir == "" || projectDir == "." {
		return "", &Error{Op: "validate project dir", Err: errors.New("project directory is required")}
	}
	info, err := os.Stat(projectDir)
	if err != nil {
		return "", &Error{Op: "validate project dir", Path: projectDir, Err: err}
	}
	if !info.IsDir() {
		return "", &Error{Op: "validate project dir", Path: projectDir, Err: errors.New("project path is not a directory")}
	}
	return projectDir, nil
}

func detectProjectName(projectDir string) string {
	projectFile := filepath.Join(projectDir, "project.godot")
	data, err := os.ReadFile(projectFile)
	if err != nil {
		return filepath.Base(projectDir)
	}

	insideApplication := false
	for _, rawLine := range strings.Split(normalizeNewlines(string(data)), "\n") {
		line := strings.TrimSpace(rawLine)
		if line == "[application]" {
			insideApplication = true
			continue
		}
		if insideApplication && strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			break
		}
		if insideApplication && strings.HasPrefix(line, "config/name=") {
			value := strings.TrimPrefix(line, "config/name=")
			return strings.Trim(unquoteScalar(strings.TrimSpace(value)), " ")
		}
	}

	return filepath.Base(projectDir)
}

func candidateLogDirs(projectDir, projectName string) []string {
	projectName = strings.TrimSpace(projectName)
	var dirs []string

	if home, err := os.UserHomeDir(); err == nil && projectName != "" {
		switch runtime.GOOS {
		case "darwin":
			dirs = append(dirs, filepath.Join(home, "Library", "Application Support", "Godot", "app_userdata", projectName, "logs"))
		case "windows":
			if appData := strings.TrimSpace(os.Getenv("APPDATA")); appData != "" {
				dirs = append(dirs, filepath.Join(appData, "Godot", "app_userdata", projectName, "logs"))
			}
		default:
			dirs = append(dirs, filepath.Join(home, ".local", "share", "godot", "app_userdata", projectName, "logs"))
		}
	}

	dirs = append(dirs,
		filepath.Join(projectDir, "user", "logs"),
		filepath.Join(projectDir, ".godot", "user", "logs"),
	)

	return dirs
}

func readLogDir(dir, source string) ([]Entry, error) {
	entries := make([]Entry, 0)
	walkErr := filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			if errors.Is(err, os.ErrNotExist) {
				return nil
			}
			return err
		}
		if d.IsDir() {
			return nil
		}
		fileEntries, err := readLogFile(path, source)
		if err != nil {
			return err
		}
		entries = append(entries, fileEntries...)
		return nil
	})
	if walkErr != nil && !errors.Is(walkErr, os.ErrNotExist) {
		return nil, &Error{Op: "read log dir", Path: dir, Err: walkErr}
	}
	sortEntries(entries)
	return entries, nil
}

func readLogFile(path, source string) ([]Entry, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, &Error{Op: "read log file", Path: path, Err: err}
	}
	defer file.Close()

	info, err := file.Stat()
	if err != nil {
		return nil, &Error{Op: "read log file", Path: path, Err: err}
	}

	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	entries := make([]Entry, 0)
	for scanner.Scan() {
		entry := parseLogLine(scanner.Text())
		if entry == nil {
			continue
		}
		if entry.Timestamp == "" {
			entry.Timestamp = info.ModTime().UTC().Format(time.RFC3339Nano)
		}
		if entry.Source == "" {
			entry.Source = source
		}
		entry.Source = normalizeSource(entry.Source)
		entry.Level = normalizeLevel(entry.Level)
		entry.Context = mergeContext(entry.Context, map[string]any{"log_file": path})
		entries = append(entries, *entry)
	}
	if err := scanner.Err(); err != nil {
		return nil, &Error{Op: "scan log file", Path: path, Err: err}
	}
	return entries, nil
}

func importErrorEntries(projectDir, path string) ([]Entry, error) {
	info, err := os.Stat(path)
	if err != nil {
		return nil, err
	}

	entries := make([]Entry, 0)
	fileName := strings.ToLower(filepath.Base(path))
	if strings.Contains(fileName, "error") || strings.Contains(fileName, "fail") {
		entries = append(entries, Entry{
			Timestamp: info.ModTime().UTC().Format(time.RFC3339Nano),
			Source:    "import",
			Level:     "error",
			Message:   fmt.Sprintf("import artifact indicates failure: %s", relPath(projectDir, path)),
			Context:   map[string]any{"file": path},
		})
	}

	textEntries, err := scanImportFile(path, info.ModTime())
	if err != nil {
		return nil, err
	}
	entries = append(entries, textEntries...)
	return entries, nil
}

func scanImportFile(path string, modTime time.Time) ([]Entry, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, &Error{Op: "scan import file", Path: path, Err: err}
	}
	defer file.Close()

	reader := bufio.NewReader(file)
	sample, _ := reader.Peek(512)
	if looksBinary(sample) {
		return nil, nil
	}
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		return nil, &Error{Op: "scan import file", Path: path, Err: err}
	}

	indicators := []string{"error", "failed", "failure", "invalid", "corrupt", "missing dependency"}
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	entries := make([]Entry, 0)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		lower := strings.ToLower(line)
		for _, indicator := range indicators {
			if strings.Contains(lower, indicator) {
				entries = append(entries, Entry{
					Timestamp: modTime.UTC().Format(time.RFC3339Nano),
					Source:    "import",
					Level:     "error",
					Message:   line,
					Context:   map[string]any{"file": path},
				})
				break
			}
		}
	}
	if err := scanner.Err(); err != nil {
		return nil, &Error{Op: "scan import file", Path: path, Err: err}
	}
	return entries, nil
}

func detectGodotVersion() string {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	for _, candidate := range []string{strings.TrimSpace(os.Getenv("GODOT_BIN")), "godot", "godot4", "godot.exe"} {
		candidate = strings.TrimSpace(candidate)
		if candidate == "" {
			continue
		}
		path, err := exec.LookPath(candidate)
		if err != nil {
			continue
		}
		cmd := exec.CommandContext(ctx, path, "--version")
		output, err := cmd.CombinedOutput()
		if err == nil && strings.TrimSpace(string(output)) != "" {
			return strings.TrimSpace(string(output))
		}
	}

	return ""
}

func parseTimestampPrefix(line string) (string, string) {
	line = strings.TrimSpace(line)
	if line == "" {
		return "", ""
	}

	if strings.HasPrefix(line, "[") {
		if idx := strings.Index(line, "]"); idx > 1 {
			candidate := line[1:idx]
			if ts := parseTimestamp(candidate); ts != "" {
				return ts, strings.TrimSpace(line[idx+1:])
			}
		}
	}

	if fields := strings.Fields(line); len(fields) > 0 {
		if ts := parseTimestamp(fields[0]); ts != "" {
			rest := strings.TrimSpace(strings.TrimPrefix(line, fields[0]))
			return ts, rest
		}
	}

	if len(line) >= len("2006-01-02 15:04:05") {
		candidate := line[:len("2006-01-02 15:04:05")]
		if ts := parseTimestamp(candidate); ts != "" {
			return ts, strings.TrimSpace(line[len(candidate):])
		}
	}

	return "", line
}

func parseTimestamp(value string) string {
	value = strings.TrimSpace(value)
	for _, layout := range []string{time.RFC3339Nano, time.RFC3339, "2006-01-02 15:04:05", "2006-01-02T15:04:05"} {
		if parsed, err := time.Parse(layout, value); err == nil {
			return parsed.UTC().Format(time.RFC3339Nano)
		}
	}
	return ""
}

func parseSourcePrefix(line string) (string, string) {
	for _, source := range []string{"editor", "runtime", "import", "test", "plugin", "bridge"} {
		bracketed := "[" + source + "]"
		if strings.HasPrefix(strings.ToLower(line), bracketed) {
			return source, strings.TrimSpace(line[len(bracketed):])
		}
		plain := source + ":"
		if strings.HasPrefix(strings.ToLower(line), plain) {
			return source, strings.TrimSpace(line[len(plain):])
		}
	}
	return "", line
}

func parseLevelPrefix(line string) (string, string) {
	type prefix struct {
		text  string
		level string
	}
	prefixes := []prefix{
		{text: "[critical]", level: "critical"},
		{text: "[error]", level: "error"},
		{text: "[warning]", level: "warning"},
		{text: "[warn]", level: "warning"},
		{text: "[info]", level: "info"},
		{text: "[debug]", level: "debug"},
		{text: "critical:", level: "critical"},
		{text: "fatal:", level: "critical"},
		{text: "script error:", level: "error"},
		{text: "error:", level: "error"},
		{text: "warning:", level: "warning"},
		{text: "warn:", level: "warning"},
		{text: "info:", level: "info"},
		{text: "debug:", level: "debug"},
	}
	lower := strings.ToLower(line)
	for _, item := range prefixes {
		if strings.HasPrefix(lower, item.text) {
			return item.level, strings.TrimSpace(line[len(item.text):])
		}
	}
	if strings.HasPrefix(line, "E ") {
		return "error", strings.TrimSpace(line[2:])
	}
	if strings.HasPrefix(line, "W ") {
		return "warning", strings.TrimSpace(line[2:])
	}
	if strings.HasPrefix(line, "I ") {
		return "info", strings.TrimSpace(line[2:])
	}
	if strings.HasPrefix(line, "D ") {
		return "debug", strings.TrimSpace(line[2:])
	}
	return "", line
}

func parseLineContext(message string) map[string]any {
	ctx := make(map[string]any)
	if strings.Contains(message, "res://") {
		start := strings.Index(message, "res://")
		end := strings.IndexAny(message[start:], " )]")
		if end == -1 {
			ctx["resource"] = message[start:]
		} else {
			ctx["resource"] = message[start : start+end]
		}
	}
	if strings.Contains(strings.ToLower(message), " at: ") {
		ctx["location"] = message
	}
	if len(ctx) == 0 {
		return nil
	}
	return ctx
}

func mergeContext(base map[string]any, extras map[string]any) map[string]any {
	if len(base) == 0 && len(extras) == 0 {
		return nil
	}
	merged := make(map[string]any, len(base)+len(extras))
	for key, value := range base {
		merged[key] = value
	}
	for key, value := range extras {
		merged[key] = value
	}
	return merged
}

func normalizeSource(source string) string {
	source = strings.ToLower(strings.TrimSpace(source))
	switch source {
	case "runtime", "import", "test", "plugin", "bridge":
		return source
	default:
		return "editor"
	}
}

func normalizeLevel(level string) string {
	level = strings.ToLower(strings.TrimSpace(level))
	switch level {
	case "debug", "info", "warning", "error", "critical":
		return level
	case "warn":
		return "warning"
	default:
		return "info"
	}
}

func levelRank(level string) int {
	switch normalizeLevel(level) {
	case "debug":
		return 0
	case "info":
		return 1
	case "warning":
		return 2
	case "error":
		return 3
	case "critical":
		return 4
	default:
		return 1
	}
}

func sortEntries(entries []Entry) {
	sort.Slice(entries, func(i, j int) bool {
		if entries[i].Timestamp == entries[j].Timestamp {
			if entries[i].Source == entries[j].Source {
				return entries[i].Message < entries[j].Message
			}
			return entries[i].Source < entries[j].Source
		}
		return entries[i].Timestamp < entries[j].Timestamp
	})
}

func looksBinary(sample []byte) bool {
	for _, b := range sample {
		if b == 0 {
			return true
		}
	}
	return false
}

func relPath(projectDir, path string) string {
	rel, err := filepath.Rel(projectDir, path)
	if err != nil {
		return filepath.ToSlash(path)
	}
	return filepath.ToSlash(rel)
}

func newBundleID() string {
	buf := make([]byte, 12)
	if _, err := rand.Read(buf); err != nil {
		return fmt.Sprintf("bundle-%d", time.Now().UTC().UnixNano())
	}
	return hex.EncodeToString(buf)
}

func normalizeNewlines(value string) string {
	value = strings.ReplaceAll(value, "\r\n", "\n")
	value = strings.ReplaceAll(value, "\r", "\n")
	return value
}

func unquoteScalar(value string) string {
	value = strings.TrimSpace(value)
	if len(value) >= 2 {
		if (value[0] == '\'' && value[len(value)-1] == '\'') || (value[0] == '"' && value[len(value)-1] == '"') {
			return value[1 : len(value)-1]
		}
	}
	return value
}
