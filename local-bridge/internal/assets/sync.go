package assets

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/echothink/godot-local-bridge/internal/gateway"
)

const (
	lockFileRelativePath = ".echothink/assets.lock"
	checksumDirName      = ".echothink/assets"
)

// AssetRef describes one synchronized asset.
type AssetRef struct {
	AssetID      string `json:"asset_id"`
	Repo         string `json:"repo"`
	Ref          string `json:"ref"`
	CommitID     string `json:"commit_id"`
	Tag          string `json:"tag"`
	ImportTarget string `json:"import_target"`
}

// LockFile stores the local asset lock state.
type LockFile struct {
	Assets map[string]*AssetRef `json:"assets"`
}

// DiffResult summarizes local-versus-remote asset drift.
type DiffResult struct {
	Added           []AssetRef `json:"added"`
	Modified        []AssetRef `json:"modified"`
	Deleted         []AssetRef `json:"deleted"`
	MetadataChanged []AssetRef `json:"metadata_changed"`
}

// PullResult captures the outcome of one asset pull.
type PullResult struct {
	AssetID         string `json:"asset_id"`
	Success         bool   `json:"success"`
	LocalPath       string `json:"local_path,omitempty"`
	Error           string `json:"error,omitempty"`
	BytesDownloaded int64  `json:"bytes_downloaded"`
}

// LoadLockFile reads .echothink/assets.lock from projectDir.
func LoadLockFile(projectDir string) (*LockFile, error) {
	lock := &LockFile{Assets: make(map[string]*AssetRef)}
	path, err := lockFilePath(projectDir)
	if err != nil {
		return nil, err
	}

	file, err := os.Open(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return lock, nil
		}
		return nil, fmt.Errorf("open asset lock file %q: %w", path, err)
	}
	defer file.Close()

	root, err := parseYAMLMap(file)
	if err != nil {
		return nil, fmt.Errorf("parse asset lock file %q: %w", path, err)
	}

	rawAssets, ok := root["assets"]
	if !ok {
		if len(root) == 0 {
			return lock, nil
		}
		rawAssets = root
	}

	assetsMap, ok := rawAssets.(map[string]any)
	if !ok {
		return nil, fmt.Errorf("asset lock file %q: assets must be a mapping", path)
	}

	for key, rawEntry := range assetsMap {
		entryMap, ok := rawEntry.(map[string]any)
		if !ok {
			return nil, fmt.Errorf("asset lock file %q: asset %q must be a mapping", path, key)
		}
		ref := &AssetRef{AssetID: strings.TrimSpace(key)}
		for field, rawValue := range entryMap {
			value, ok := rawValue.(string)
			if !ok {
				return nil, fmt.Errorf("asset lock file %q: asset %q field %q must be a scalar", path, key, field)
			}
			switch normalizeKey(field) {
			case "assetid", "id":
				ref.AssetID = strings.TrimSpace(value)
			case "repo":
				ref.Repo = strings.TrimSpace(value)
			case "ref":
				ref.Ref = strings.TrimSpace(value)
			case "commitid", "commit":
				ref.CommitID = strings.TrimSpace(value)
			case "tag":
				ref.Tag = strings.TrimSpace(value)
			case "importtarget", "path":
				ref.ImportTarget = strings.TrimSpace(value)
			}
		}
		if ref.AssetID == "" {
			return nil, fmt.Errorf("asset lock file %q: asset %q is missing asset_id", path, key)
		}
		lock.Assets[ref.AssetID] = cloneRef(ref)
	}

	return lock, nil
}

// SaveLockFile persists .echothink/assets.lock using an atomic replace.
func SaveLockFile(projectDir string, lock *LockFile) error {
	if lock == nil {
		lock = &LockFile{}
	}
	if lock.Assets == nil {
		lock.Assets = make(map[string]*AssetRef)
	}

	path, err := lockFilePath(projectDir)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("create asset lock directory: %w", err)
	}

	var builder strings.Builder
	builder.WriteString("assets:\n")
	for _, assetID := range sortedAssetIDs(lock.Assets) {
		ref := lock.Assets[assetID]
		if ref == nil {
			continue
		}
		builder.WriteString("  ")
		builder.WriteString(escapeYAMLScalar(assetID))
		builder.WriteString(":\n")
		writeLockField(&builder, "asset_id", firstNonEmpty(strings.TrimSpace(ref.AssetID), assetID))
		writeLockField(&builder, "repo", ref.Repo)
		writeLockField(&builder, "ref", ref.Ref)
		writeLockField(&builder, "commit_id", ref.CommitID)
		writeLockField(&builder, "tag", ref.Tag)
		writeLockField(&builder, "import_target", ref.ImportTarget)
	}

	payload := []byte(builder.String())
	tmpFile, err := os.CreateTemp(filepath.Dir(path), "assets-*.tmp")
	if err != nil {
		return fmt.Errorf("create asset lock temp file: %w", err)
	}
	tmpPath := tmpFile.Name()

	cleanup := func(cause error) error {
		_ = tmpFile.Close()
		_ = os.Remove(tmpPath)
		return cause
	}

	if _, err := tmpFile.Write(payload); err != nil {
		return cleanup(fmt.Errorf("write asset lock temp file: %w", err))
	}
	if err := tmpFile.Sync(); err != nil {
		return cleanup(fmt.Errorf("sync asset lock temp file: %w", err))
	}
	if err := tmpFile.Close(); err != nil {
		return cleanup(fmt.Errorf("close asset lock temp file: %w", err))
	}
	if err := os.Rename(tmpPath, path); err != nil {
		return cleanup(fmt.Errorf("replace asset lock file: %w", err))
	}

	dir, err := os.Open(filepath.Dir(path))
	if err == nil {
		_ = dir.Sync()
		_ = dir.Close()
	}

	return nil
}

// DiffWithRemote compares the current lock file with the gateway's remote state.
func DiffWithRemote(ctx context.Context, gw *gateway.Client, projectDir string, lock *LockFile) (*DiffResult, error) {
	if ctx == nil {
		return nil, errors.New("diff assets: context is nil")
	}
	if gw == nil {
		return nil, errors.New("diff assets: gateway client is nil")
	}
	if lock == nil {
		var err error
		lock, err = LoadLockFile(projectDir)
		if err != nil {
			return nil, err
		}
	}
	if lock.Assets == nil {
		lock.Assets = make(map[string]*AssetRef)
	}

	workspaceID := detectWorkspaceID(projectDir)
	remoteDocs, err := gw.ListAssets(ctx, workspaceID)
	if err != nil {
		return nil, fmt.Errorf("list remote assets: %w", err)
	}

	remoteAssets := make(map[string]AssetRef, len(remoteDocs))
	for _, raw := range remoteDocs {
		ref, err := assetRefFromRaw(raw)
		if err != nil {
			return nil, fmt.Errorf("parse remote asset state: %w", err)
		}
		remoteAssets[ref.AssetID] = ref
	}

	result := &DiffResult{
		Added:           make([]AssetRef, 0),
		Modified:        make([]AssetRef, 0),
		Deleted:         make([]AssetRef, 0),
		MetadataChanged: make([]AssetRef, 0),
	}

	for assetID, remote := range remoteAssets {
		local, ok := lock.Assets[assetID]
		if !ok || local == nil {
			result.Added = append(result.Added, remote)
			continue
		}
		if assetContentChanged(*local, remote) {
			result.Modified = append(result.Modified, remote)
			continue
		}
		if assetMetadataChanged(*local, remote) {
			result.MetadataChanged = append(result.MetadataChanged, remote)
		}
	}

	for assetID, local := range lock.Assets {
		if local == nil {
			continue
		}
		if _, ok := remoteAssets[assetID]; !ok {
			result.Deleted = append(result.Deleted, *cloneRef(local))
		}
	}

	sortRefs(result.Added)
	sortRefs(result.Modified)
	sortRefs(result.Deleted)
	sortRefs(result.MetadataChanged)
	return result, nil
}

// PullAsset downloads one asset into its import target.
func PullAsset(ctx context.Context, gw *gateway.Client, projectDir string, ref *AssetRef) (*PullResult, error) {
	if ctx == nil {
		return nil, errors.New("pull asset: context is nil")
	}
	if gw == nil {
		return nil, errors.New("pull asset: gateway client is nil")
	}
	if ref == nil {
		return nil, errors.New("pull asset: asset reference is nil")
	}

	assetID := strings.TrimSpace(ref.AssetID)
	if assetID == "" {
		return nil, errors.New("pull asset: asset ID is required")
	}
	localPath, err := resolveImportPath(projectDir, ref.ImportTarget)
	if err != nil {
		result := &PullResult{AssetID: assetID, Error: err.Error()}
		return result, err
	}

	result := &PullResult{AssetID: assetID, LocalPath: localPath}
	if err := os.MkdirAll(filepath.Dir(localPath), 0o755); err != nil {
		result.Error = err.Error()
		return result, fmt.Errorf("create asset directory: %w", err)
	}

	metadataRaw, metadataErr := gw.GetAsset(ctx, assetID)
	expectedChecksum := ""
	if metadataErr == nil {
		expectedChecksum = extractChecksumFromRaw(metadataRaw)
	}
	if expectedChecksum == "" {
		expectedChecksum = extractChecksumFromRef(ref)
	}

	stream, expectedBytes, err := gw.PullAsset(ctx, assetID, preferredRemoteRef(ref))
	if err != nil {
		result.Error = err.Error()
		return result, fmt.Errorf("download asset %q: %w", assetID, err)
	}
	defer stream.Close()

	if checksumProvider, ok := stream.(interface{ ExpectedChecksum() string }); ok && expectedChecksum == "" {
		expectedChecksum = normalizeChecksum(checksumProvider.ExpectedChecksum())
	}

	tmpFile, err := os.CreateTemp(filepath.Dir(localPath), ".asset-*.tmp")
	if err != nil {
		result.Error = err.Error()
		return result, fmt.Errorf("create temp asset file: %w", err)
	}
	tmpPath := tmpFile.Name()
	replaced := false

	cleanup := func(cause error) (*PullResult, error) {
		_ = tmpFile.Close()
		if replaced {
			_ = os.Remove(localPath)
		} else {
			_ = os.Remove(tmpPath)
		}
		result.Error = cause.Error()
		return result, cause
	}

	hasher := sha256.New()
	written, err := io.Copy(io.MultiWriter(tmpFile, hasher), stream)
	if err != nil {
		return cleanup(fmt.Errorf("write asset data: %w", err))
	}
	if expectedBytes >= 0 && written != expectedBytes {
		return cleanup(fmt.Errorf("asset download size mismatch: expected %d bytes, wrote %d bytes", expectedBytes, written))
	}
	if err := tmpFile.Sync(); err != nil {
		return cleanup(fmt.Errorf("sync temp asset file: %w", err))
	}
	if err := tmpFile.Close(); err != nil {
		return cleanup(fmt.Errorf("close temp asset file: %w", err))
	}

	actualChecksum := hex.EncodeToString(hasher.Sum(nil))
	if expectedChecksum != "" && actualChecksum != expectedChecksum {
		return cleanup(fmt.Errorf("asset checksum mismatch: expected %s, got %s", expectedChecksum, actualChecksum))
	}

	if err := os.Rename(tmpPath, localPath); err != nil {
		return cleanup(fmt.Errorf("replace asset file: %w", err))
	}
	replaced = true
	if err := os.Chmod(localPath, 0o644); err != nil {
		return cleanup(fmt.Errorf("set asset permissions: %w", err))
	}
	if expectedChecksum != "" {
		if err := saveChecksumMarker(projectDir, assetID, expectedChecksum); err != nil {
			return cleanup(fmt.Errorf("persist asset checksum marker: %w", err))
		}
	}

	result.Success = true
	result.Error = ""
	result.BytesDownloaded = written
	return result, nil
}

// ValidateImport verifies that the imported asset exists and matches recorded integrity data.
func ValidateImport(projectDir string, ref *AssetRef) error {
	if ref == nil {
		return errors.New("validate asset import: asset reference is nil")
	}
	localPath, err := resolveImportPath(projectDir, ref.ImportTarget)
	if err != nil {
		return err
	}

	info, err := os.Stat(localPath)
	if err != nil {
		return fmt.Errorf("stat imported asset %q: %w", localPath, err)
	}
	if info.IsDir() {
		return fmt.Errorf("imported asset %q is a directory", localPath)
	}

	file, err := os.Open(localPath)
	if err != nil {
		return fmt.Errorf("open imported asset %q: %w", localPath, err)
	}
	defer file.Close()

	hasher := sha256.New()
	if _, err := io.Copy(hasher, file); err != nil {
		return fmt.Errorf("read imported asset %q: %w", localPath, err)
	}

	expectedChecksum := extractChecksumFromRef(ref)
	if expectedChecksum == "" {
		expectedChecksum, _ = loadChecksumMarker(projectDir, ref.AssetID)
	}
	if expectedChecksum == "" {
		return nil
	}

	actualChecksum := hex.EncodeToString(hasher.Sum(nil))
	if actualChecksum != expectedChecksum {
		return fmt.Errorf("imported asset checksum mismatch for %q: expected %s, got %s", localPath, expectedChecksum, actualChecksum)
	}
	return nil
}

// UpdateLockEntry inserts or replaces one lock entry in memory.
func UpdateLockEntry(lock *LockFile, ref *AssetRef) {
	if lock == nil || ref == nil {
		return
	}
	if lock.Assets == nil {
		lock.Assets = make(map[string]*AssetRef)
	}
	assetID := strings.TrimSpace(ref.AssetID)
	if assetID == "" {
		return
	}
	cloned := cloneRef(ref)
	cloned.AssetID = assetID
	lock.Assets[assetID] = cloned
}

func lockFilePath(projectDir string) (string, error) {
	projectDir = filepath.Clean(strings.TrimSpace(projectDir))
	if projectDir == "" || projectDir == "." {
		return "", errors.New("project directory is required")
	}
	return filepath.Join(projectDir, lockFileRelativePath), nil
}

func resolveImportPath(projectDir, importTarget string) (string, error) {
	projectDir = filepath.Clean(strings.TrimSpace(projectDir))
	if projectDir == "" || projectDir == "." {
		return "", errors.New("project directory is required")
	}
	projectAbs, err := filepath.Abs(projectDir)
	if err != nil {
		return "", fmt.Errorf("resolve project directory: %w", err)
	}

	importTarget = strings.TrimSpace(importTarget)
	if importTarget == "" {
		return "", errors.New("import target is required")
	}
	if filepath.IsAbs(importTarget) {
		return "", errors.New("import target must be relative to the project directory")
	}

	resolved := filepath.Clean(filepath.Join(projectAbs, importTarget))
	rel, err := filepath.Rel(projectAbs, resolved)
	if err != nil {
		return "", fmt.Errorf("validate import target %q: %w", importTarget, err)
	}
	rel = filepath.Clean(rel)
	if rel == ".." || strings.HasPrefix(rel, ".."+string(os.PathSeparator)) {
		return "", errors.New("import target escapes the project directory")
	}
	return resolved, nil
}

func saveChecksumMarker(projectDir, assetID, checksum string) error {
	checksum = normalizeChecksum(checksum)
	if checksum == "" || strings.TrimSpace(assetID) == "" {
		return nil
	}
	path, err := checksumMarkerPath(projectDir, assetID)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("create checksum directory: %w", err)
	}
	return os.WriteFile(path, []byte(checksum+"\n"), 0o644)
}

func loadChecksumMarker(projectDir, assetID string) (string, error) {
	path, err := checksumMarkerPath(projectDir, assetID)
	if err != nil {
		return "", err
	}
	data, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return "", nil
		}
		return "", fmt.Errorf("read checksum marker: %w", err)
	}
	return normalizeChecksum(string(data)), nil
}

func checksumMarkerPath(projectDir, assetID string) (string, error) {
	projectDir = filepath.Clean(strings.TrimSpace(projectDir))
	if projectDir == "" || projectDir == "." {
		return "", errors.New("project directory is required")
	}
	if strings.TrimSpace(assetID) == "" {
		return "", errors.New("asset ID is required")
	}
	hash := sha256.Sum256([]byte(assetID))
	fileName := hex.EncodeToString(hash[:]) + ".sha256"
	return filepath.Join(projectDir, checksumDirName, fileName), nil
}

func preferredRemoteRef(ref *AssetRef) string {
	if ref == nil {
		return ""
	}
	return firstNonEmpty(ref.Ref, ref.Tag, ref.CommitID)
}

func extractChecksumFromRef(ref *AssetRef) string {
	if ref == nil {
		return ""
	}
	for _, candidate := range []string{ref.Tag, ref.CommitID, ref.Ref} {
		if checksum := normalizeChecksum(candidate); checksum != "" {
			return checksum
		}
		candidate = strings.TrimSpace(candidate)
		candidate = strings.TrimPrefix(strings.ToLower(candidate), "sha256:")
		if checksum := normalizeChecksum(candidate); checksum != "" {
			return checksum
		}
	}
	return ""
}

func extractChecksumFromRaw(raw json.RawMessage) string {
	var document map[string]any
	if err := json.Unmarshal(raw, &document); err != nil {
		return ""
	}
	for _, candidate := range candidateMaps(document) {
		for _, key := range []string{"checksum", "sha256", "content_sha256", "contentSha256", "digest"} {
			if value := stringValue(candidate[key]); value != "" {
				if checksum := normalizeChecksum(value); checksum != "" {
					return checksum
				}
				if strings.HasPrefix(strings.ToLower(strings.TrimSpace(value)), "sha256:") {
					if checksum := normalizeChecksum(strings.TrimSpace(strings.TrimPrefix(strings.ToLower(value), "sha256:"))); checksum != "" {
						return checksum
					}
				}
			}
		}
	}
	return ""
}

func assetRefFromRaw(raw json.RawMessage) (AssetRef, error) {
	var document map[string]any
	if err := json.Unmarshal(raw, &document); err != nil {
		return AssetRef{}, fmt.Errorf("decode asset JSON: %w", err)
	}

	ref := AssetRef{}
	for _, candidate := range candidateMaps(document) {
		if ref.AssetID == "" {
			ref.AssetID = firstNonEmpty(stringValue(candidate["asset_id"]), stringValue(candidate["assetID"]), stringValue(candidate["id"]))
		}
		if ref.Repo == "" {
			ref.Repo = firstNonEmpty(stringValue(candidate["repo"]), stringValue(candidate["repository"]))
		}
		if ref.Ref == "" {
			ref.Ref = firstNonEmpty(stringValue(candidate["ref"]), stringValue(candidate["branch"]))
		}
		if ref.CommitID == "" {
			ref.CommitID = firstNonEmpty(stringValue(candidate["commit_id"]), stringValue(candidate["commitID"]), stringValue(candidate["commit"]))
		}
		if ref.Tag == "" {
			ref.Tag = stringValue(candidate["tag"])
		}
		if ref.ImportTarget == "" {
			ref.ImportTarget = firstNonEmpty(stringValue(candidate["import_target"]), stringValue(candidate["importTarget"]), stringValue(candidate["path"]))
		}
	}
	if ref.AssetID == "" {
		return AssetRef{}, errors.New("asset document is missing asset ID")
	}
	return ref, nil
}

func candidateMaps(root map[string]any) []map[string]any {
	if root == nil {
		return nil
	}
	out := []map[string]any{root}
	for _, key := range []string{"asset", "data", "result", "state", "metadata", "lock"} {
		if nested, ok := root[key].(map[string]any); ok {
			out = append(out, nested)
		}
	}
	return out
}

func assetContentChanged(local, remote AssetRef) bool {
	return strings.TrimSpace(local.Repo) != strings.TrimSpace(remote.Repo) ||
		strings.TrimSpace(local.Ref) != strings.TrimSpace(remote.Ref) ||
		strings.TrimSpace(local.CommitID) != strings.TrimSpace(remote.CommitID)
}

func assetMetadataChanged(local, remote AssetRef) bool {
	return strings.TrimSpace(local.Tag) != strings.TrimSpace(remote.Tag) ||
		strings.TrimSpace(local.ImportTarget) != strings.TrimSpace(remote.ImportTarget)
}

func sortRefs(refs []AssetRef) {
	sort.Slice(refs, func(i, j int) bool {
		if refs[i].AssetID == refs[j].AssetID {
			return refs[i].ImportTarget < refs[j].ImportTarget
		}
		return refs[i].AssetID < refs[j].AssetID
	})
}

func sortedAssetIDs(values map[string]*AssetRef) []string {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

func cloneRef(ref *AssetRef) *AssetRef {
	if ref == nil {
		return nil
	}
	cloned := *ref
	return &cloned
}

func writeLockField(builder *strings.Builder, key, value string) {
	builder.WriteString("    ")
	builder.WriteString(key)
	builder.WriteString(": ")
	builder.WriteString(escapeYAMLScalar(value))
	builder.WriteByte('\n')
}

func escapeYAMLScalar(value string) string {
	if value == "" {
		return `""`
	}
	requiresQuotes := strings.ContainsAny(value, ":#{}[]&,*!?|>'\"%@`") || strings.TrimSpace(value) != value || strings.ContainsRune(value, '\t')
	if !requiresQuotes {
		return value
	}
	replacer := strings.NewReplacer(`\\`, `\\\\`, `"`, `\\"`, "\n", `\\n`)
	return `"` + replacer.Replace(value) + `"`
}

func parseYAMLMap(r io.Reader) (map[string]any, error) {
	root := make(map[string]any)
	stack := []yamlFrame{{indent: -2, node: root}}

	scanner := bufio.NewScanner(r)
	lineNumber := 0
	for scanner.Scan() {
		lineNumber++
		line := stripInlineComment(scanner.Text())
		if strings.TrimSpace(line) == "" {
			continue
		}
		trimmed := strings.TrimSpace(line)
		if trimmed == "---" || trimmed == "..." {
			continue
		}

		indent := len(line) - len(strings.TrimLeft(line, " "))
		if indent%2 != 0 {
			return nil, fmt.Errorf("line %d: indentation must use multiples of two spaces", lineNumber)
		}

		for len(stack) > 1 && indent <= stack[len(stack)-1].indent {
			stack = stack[:len(stack)-1]
		}
		if indent > stack[len(stack)-1].indent+2 {
			return nil, fmt.Errorf("line %d: indentation jumps more than one level", lineNumber)
		}

		key, value, ok := strings.Cut(strings.TrimSpace(line), ":")
		if !ok {
			return nil, fmt.Errorf("line %d: expected key: value mapping", lineNumber)
		}
		key = strings.TrimSpace(key)
		if key == "" {
			return nil, fmt.Errorf("line %d: empty mapping key", lineNumber)
		}

		parent := stack[len(stack)-1].node
		value = strings.TrimSpace(value)
		if value == "" {
			child := make(map[string]any)
			parent[key] = child
			stack = append(stack, yamlFrame{indent: indent, node: child})
			continue
		}
		parent[key] = unquoteYAMLScalar(value)
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	return root, nil
}

type yamlFrame struct {
	indent int
	node   map[string]any
}

func stripInlineComment(line string) string {
	var inSingle, inDouble bool
	for idx, r := range line {
		switch r {
		case '\'':
			if !inDouble {
				inSingle = !inSingle
			}
		case '"':
			if !inSingle {
				inDouble = !inDouble
			}
		case '#':
			if !inSingle && !inDouble {
				return strings.TrimRight(line[:idx], " ")
			}
		}
	}
	return line
}

func unquoteYAMLScalar(value string) string {
	value = strings.TrimSpace(value)
	if len(value) >= 2 {
		if value[0] == '"' && value[len(value)-1] == '"' {
			replacer := strings.NewReplacer(`\\n`, "\n", `\\"`, `"`, `\\\\`, `\\`)
			return replacer.Replace(value[1 : len(value)-1])
		}
		if value[0] == '\'' && value[len(value)-1] == '\'' {
			return strings.ReplaceAll(value[1:len(value)-1], `''`, `'`)
		}
	}
	return value
}

func normalizeKey(key string) string {
	replacer := strings.NewReplacer("_", "", "-", "", " ", "")
	return strings.ToLower(replacer.Replace(strings.TrimSpace(key)))
}

func detectWorkspaceID(projectDir string) string {
	for _, envKey := range []string{"ECHOTHINK_WORKSPACE_ID", "ECHOTHINK_WORKSPACEID"} {
		if value := strings.TrimSpace(os.Getenv(envKey)); value != "" {
			return value
		}
	}
	for _, candidate := range []string{
		filepath.Join(projectDir, ".echothink", "workspace_id"),
		filepath.Join(projectDir, ".echothink", "workspace-id"),
		filepath.Join(projectDir, ".echothink", "workspace.json"),
	} {
		data, err := os.ReadFile(candidate)
		if err != nil {
			continue
		}
		if filepath.Ext(candidate) == ".json" {
			var envelope map[string]any
			if json.Unmarshal(data, &envelope) == nil {
				if value := firstNonEmpty(stringValue(envelope["workspace_id"]), stringValue(envelope["workspaceID"]), stringValue(envelope["id"])); value != "" {
					return value
				}
			}
			continue
		}
		if value := strings.TrimSpace(string(data)); value != "" {
			return value
		}
	}
	return ""
}

func stringValue(value any) string {
	switch typed := value.(type) {
	case string:
		return strings.TrimSpace(typed)
	case fmt.Stringer:
		return strings.TrimSpace(typed.String())
	default:
		return ""
	}
}

func normalizeChecksum(value string) string {
	value = strings.ToLower(strings.TrimSpace(value))
	value = strings.TrimPrefix(value, "sha256:")
	if len(value) != 64 {
		return ""
	}
	for _, r := range value {
		if (r < '0' || r > '9') && (r < 'a' || r > 'f') {
			return ""
		}
	}
	return value
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return strings.TrimSpace(value)
		}
	}
	return ""
}
