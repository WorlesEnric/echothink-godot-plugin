package adapters

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/echothink/godot-local-bridge/internal/assets"
	"github.com/echothink/godot-local-bridge/internal/config"
	"github.com/echothink/godot-local-bridge/internal/gateway"
	"github.com/echothink/godot-local-bridge/internal/ipc"
	"github.com/echothink/godot-local-bridge/internal/journal"
	"github.com/echothink/godot-local-bridge/internal/session"
)

const (
	defaultHandlerTimeout = 60 * time.Second
	defaultSnapshotFiles  = 64
	defaultLogBytes       = 128 << 10
	rollbackRootDir       = ".echothink/rollback"
)

// RegisterAllHandlers wires all JSON-RPC methods to the local bridge subsystems.
func RegisterAllHandlers(server *ipc.Server, cfg *config.Config, sess *session.SessionManager, j *journal.Journal, gw *gateway.Client, logger *slog.Logger) {
	if server == nil {
		panic("adapters: IPC server is nil")
	}
	if logger == nil {
		logger = slog.Default()
	}

	register := func(name string, handler func(context.Context, json.RawMessage) (any, error)) {
		server.RegisterMethod(name, func(params json.RawMessage) (interface{}, error) {
			ctx, cancel := context.WithTimeout(context.Background(), defaultHandlerTimeout)
			defer cancel()

			startedAt := time.Now()
			result, err := handler(ctx, params)
			attrs := []any{"method", name, "duration_ms", time.Since(startedAt).Milliseconds()}
			if err != nil {
				logger.Warn("ipc handler failed", append(attrs, "error", err)...)
				return nil, toRPCError(err)
			}
			logger.Debug("ipc handler completed", attrs...)
			return result, nil
		})
	}

	register("session.bootstrap", func(ctx context.Context, params json.RawMessage) (any, error) {
		if sess == nil {
			return nil, rpcInternal("session manager is not configured", nil)
		}
		if hasParams(params) {
			var unused map[string]any
			if err := decodeParams(params, &unused); err != nil {
				return nil, err
			}
		}
		return sess.Bootstrap()
	})

	register("context.snapshot", func(ctx context.Context, params json.RawMessage) (any, error) {
		if cfg == nil {
			return nil, rpcInternal("config is not configured", nil)
		}
		if gw == nil {
			return nil, rpcInternal("gateway client is not configured", nil)
		}

		var req contextSnapshotParams
		if err := decodeParams(params, &req); err != nil {
			return nil, err
		}
		snapshot, err := captureContextSnapshot(cfg, sess, req)
		if err != nil {
			return nil, err
		}
		if err := gw.SubmitContext(ctx, snapshot); err != nil {
			return nil, err
		}
		return snapshot, nil
	})

	register("task.list", func(ctx context.Context, params json.RawMessage) (any, error) {
		if gw == nil {
			return nil, rpcInternal("gateway client is not configured", nil)
		}
		payload, err := decodeObjectParams(params)
		if err != nil {
			return nil, err
		}
		workspaceID := firstNonEmpty(stringFromMap(payload, "workspace_id", "workspaceID", "id"), valueFromConfig(cfg, func(c *config.Config) string { return c.WorkspaceID }))
		return gw.ListTasks(ctx, workspaceID)
	})

	register("task.details", func(ctx context.Context, params json.RawMessage) (any, error) {
		if gw == nil {
			return nil, rpcInternal("gateway client is not configured", nil)
		}
		payload, err := decodeObjectParams(params)
		if err != nil {
			return nil, err
		}
		taskID := stringFromMap(payload, "task_id", "taskID", "id")
		if strings.TrimSpace(taskID) == "" {
			return nil, rpcInvalidParams("task_id is required", nil)
		}
		return gw.GetTask(ctx, taskID)
	})

	register("task.request_plan", func(ctx context.Context, params json.RawMessage) (any, error) {
		if gw == nil {
			return nil, rpcInternal("gateway client is not configured", nil)
		}
		payload, err := decodeObjectParams(params)
		if err != nil {
			return nil, err
		}
		if _, ok := payload["workspace_id"]; !ok && cfg != nil && strings.TrimSpace(cfg.WorkspaceID) != "" {
			payload["workspace_id"] = strings.TrimSpace(cfg.WorkspaceID)
		}
		return gw.RequestPlan(ctx, payload)
	})

	register("task.accept_plan", func(ctx context.Context, params json.RawMessage) (any, error) {
		if gw == nil {
			return nil, rpcInternal("gateway client is not configured", nil)
		}
		payload, err := decodeObjectParams(params)
		if err != nil {
			return nil, err
		}
		planID := stringFromMap(payload, "plan_id", "planID", "id")
		if strings.TrimSpace(planID) == "" {
			return nil, rpcInvalidParams("plan_id is required", nil)
		}
		if err := gw.AcceptPlan(ctx, planID); err != nil {
			return nil, err
		}
		return map[string]any{"accepted": true, "plan_id": strings.TrimSpace(planID)}, nil
	})

	register("patch.preflight", func(ctx context.Context, params json.RawMessage) (any, error) {
		projectDir := valueFromConfig(cfg, func(c *config.Config) string { return c.ProjectDir })
		req, err := decodePatchRequest(params)
		if err != nil {
			return nil, err
		}
		return patchPreflight(projectDir, req)
	})

	register("patch.apply", func(ctx context.Context, params json.RawMessage) (any, error) {
		projectDir := valueFromConfig(cfg, func(c *config.Config) string { return c.ProjectDir })
		if j == nil {
			return nil, rpcInternal("journal is not configured", nil)
		}
		req, err := decodePatchRequest(params)
		if err != nil {
			return nil, err
		}
		return patchApply(ctx, projectDir, j, req)
	})

	register("patch.rollback", func(ctx context.Context, params json.RawMessage) (any, error) {
		projectDir := valueFromConfig(cfg, func(c *config.Config) string { return c.ProjectDir })
		if j == nil {
			return nil, rpcInternal("journal is not configured", nil)
		}
		var req rollbackParams
		if err := decodeParams(params, &req); err != nil {
			return nil, err
		}
		if strings.TrimSpace(req.ChangeSetID) == "" {
			return nil, rpcInvalidParams("change_set_id is required", nil)
		}
		return patchRollback(projectDir, j, req.ChangeSetID)
	})

	register("asset.search", func(ctx context.Context, params json.RawMessage) (any, error) {
		if gw == nil {
			return nil, rpcInternal("gateway client is not configured", nil)
		}
		payload, err := decodeObjectParams(params)
		if err != nil {
			return nil, err
		}
		workspaceID := firstNonEmpty(stringFromMap(payload, "workspace_id", "workspaceID", "id"), valueFromConfig(cfg, func(c *config.Config) string { return c.WorkspaceID }))
		return gw.ListAssets(ctx, workspaceID)
	})

	register("asset.diff", func(ctx context.Context, params json.RawMessage) (any, error) {
		if gw == nil {
			return nil, rpcInternal("gateway client is not configured", nil)
		}
		projectDir := valueFromConfig(cfg, func(c *config.Config) string { return c.ProjectDir })
		lock, err := assets.LoadLockFile(projectDir)
		if err != nil {
			return nil, err
		}
		if hasParams(params) {
			var unused map[string]any
			if err := decodeParams(params, &unused); err != nil {
				return nil, err
			}
		}
		return assets.DiffWithRemote(ctx, gw, projectDir, lock)
	})

	register("asset.pull", func(ctx context.Context, params json.RawMessage) (any, error) {
		if gw == nil {
			return nil, rpcInternal("gateway client is not configured", nil)
		}
		projectDir := valueFromConfig(cfg, func(c *config.Config) string { return c.ProjectDir })
		ref, lock, err := resolveAssetRequest(projectDir, params)
		if err != nil {
			return nil, err
		}
		result, err := assets.PullAsset(ctx, gw, projectDir, ref)
		if err != nil {
			return result, err
		}
		assets.UpdateLockEntry(lock, ref)
		if err := assets.SaveLockFile(projectDir, lock); err != nil {
			return result, err
		}
		_ = gw.UpdateLock(ctx, map[string]any{"assets": lock.Assets})
		return result, nil
	})

	register("asset.validate", func(ctx context.Context, params json.RawMessage) (any, error) {
		if gw == nil {
			return nil, rpcInternal("gateway client is not configured", nil)
		}
		projectDir := valueFromConfig(cfg, func(c *config.Config) string { return c.ProjectDir })
		ref, _, err := resolveAssetRequest(projectDir, params)
		if err != nil {
			return nil, err
		}
		if err := assets.ValidateImport(projectDir, ref); err != nil {
			return nil, err
		}
		validation := map[string]any{
			"asset_id":      ref.AssetID,
			"repo":          ref.Repo,
			"ref":           ref.Ref,
			"commit_id":     ref.CommitID,
			"tag":           ref.Tag,
			"import_target": ref.ImportTarget,
			"validated_at":  time.Now().UTC().Format(time.RFC3339Nano),
		}
		response, err := gw.ValidateAsset(ctx, ref.AssetID, validation)
		if err != nil {
			return nil, err
		}
		return map[string]any{"local_valid": true, "gateway": response}, nil
	})

	register("log.collect", func(ctx context.Context, params json.RawMessage) (any, error) {
		projectDir := valueFromConfig(cfg, func(c *config.Config) string { return c.ProjectDir })
		var req logCollectParams
		if err := decodeParams(params, &req); err != nil {
			return nil, err
		}
		return collectEditorLogs(projectDir, req)
	})

	register("log.submit_test", func(ctx context.Context, params json.RawMessage) (any, error) {
		if gw == nil {
			return nil, rpcInternal("gateway client is not configured", nil)
		}
		projectDir := valueFromConfig(cfg, func(c *config.Config) string { return c.ProjectDir })
		var req testRunParams
		if err := decodeParams(params, &req); err != nil {
			return nil, err
		}
		localResult, err := runTestStrategy(ctx, projectDir, req)
		if err != nil {
			return nil, err
		}
		gatewayResult, err := gw.SubmitTestRun(ctx, localResult)
		if err != nil {
			return nil, err
		}
		return map[string]any{"local": localResult, "gateway": gatewayResult}, nil
	})

	register("git.status", func(ctx context.Context, params json.RawMessage) (any, error) {
		projectDir := valueFromConfig(cfg, func(c *config.Config) string { return c.ProjectDir })
		if hasParams(params) {
			var unused map[string]any
			if err := decodeParams(params, &unused); err != nil {
				return nil, err
			}
		}
		return gitStatus(ctx, projectDir)
	})

	register("git.diff", func(ctx context.Context, params json.RawMessage) (any, error) {
		projectDir := valueFromConfig(cfg, func(c *config.Config) string { return c.ProjectDir })
		var req gitDiffParams
		if err := decodeParams(params, &req); err != nil {
			return nil, err
		}
		return gitDiff(ctx, projectDir, req)
	})

	register("git.branches", func(ctx context.Context, params json.RawMessage) (any, error) {
		projectDir := valueFromConfig(cfg, func(c *config.Config) string { return c.ProjectDir })
		if hasParams(params) {
			var unused map[string]any
			if err := decodeParams(params, &unused); err != nil {
				return nil, err
			}
		}
		return gitBranches(ctx, projectDir)
	})

	register("changeset.list", func(ctx context.Context, params json.RawMessage) (any, error) {
		if j == nil {
			return nil, rpcInternal("journal is not configured", nil)
		}
		if hasParams(params) {
			var unused map[string]any
			if err := decodeParams(params, &unused); err != nil {
				return nil, err
			}
		}
		return j.ListAll()
	})

	register("changeset.get", func(ctx context.Context, params json.RawMessage) (any, error) {
		if j == nil {
			return nil, rpcInternal("journal is not configured", nil)
		}
		payload, err := decodeObjectParams(params)
		if err != nil {
			return nil, err
		}
		changeSetID := stringFromMap(payload, "change_set_id", "changeSetID", "id")
		if strings.TrimSpace(changeSetID) == "" {
			return nil, rpcInvalidParams("change_set_id is required", nil)
		}
		return j.GetByID(changeSetID)
	})
}

type contextSnapshotParams struct {
	IncludeFiles bool           `json:"include_files"`
	MaxFiles     int            `json:"max_files"`
	Metadata     map[string]any `json:"metadata"`
}

type rollbackParams struct {
	ChangeSetID string `json:"change_set_id"`
}

type logCollectParams struct {
	Paths    []string `json:"paths"`
	MaxBytes int64    `json:"max_bytes"`
}

type testRunParams struct {
	Strategy       string         `json:"strategy"`
	Command        []string       `json:"command"`
	TimeoutSeconds int            `json:"timeout_seconds"`
	Env            map[string]string `json:"env"`
	Metadata       map[string]any `json:"metadata"`
}

type gitDiffParams struct {
	Base   string   `json:"base"`
	Head   string   `json:"head"`
	Paths  []string `json:"paths"`
	Staged bool     `json:"staged"`
}

type patchRequest struct {
	WorkItemID string           `json:"work_item_id"`
	TaskRunID  string           `json:"task_run_id"`
	Operations []patchOperation `json:"operations"`
}

type patchOperation struct {
	Type        string `json:"type"`
	Path        string `json:"path"`
	OldPath     string `json:"old_path"`
	Content     string `json:"content"`
	Encoding    string `json:"encoding"`
	Description string `json:"description"`
}

type rollbackManifest struct {
	ChangeSetID string           `json:"change_set_id"`
	Entries     []rollbackRecord `json:"entries"`
}

type rollbackRecord struct {
	Type       string `json:"type"`
	Path       string `json:"path"`
	OldPath    string `json:"old_path,omitempty"`
	BackupPath string `json:"backup_path,omitempty"`
	Existed    bool   `json:"existed"`
	Created    bool   `json:"created"`
}

func captureContextSnapshot(cfg *config.Config, sess *session.SessionManager, req contextSnapshotParams) (map[string]any, error) {
	projectDir := valueFromConfig(cfg, func(c *config.Config) string { return c.ProjectDir })
	workspaceID := valueFromConfig(cfg, func(c *config.Config) string { return c.WorkspaceID })
	snapshot := map[string]any{
		"captured_at":    time.Now().UTC().Format(time.RFC3339Nano),
		"project_dir":    projectDir,
		"workspace_id":   workspaceID,
		"policy_profile": valueFromConfig(cfg, func(c *config.Config) string { return c.PolicyProfile }),
	}
	if sess != nil {
		snapshot["session"] = sess.GetSessionInfo()
	}
	if len(req.Metadata) > 0 {
		snapshot["metadata"] = req.Metadata
	}
	if req.IncludeFiles {
		limit := req.MaxFiles
		if limit <= 0 {
			limit = defaultSnapshotFiles
		}
		files, err := collectProjectFiles(projectDir, limit)
		if err != nil {
			return nil, err
		}
		snapshot["files"] = files
	}
	return snapshot, nil
}

func collectProjectFiles(projectDir string, limit int) ([]map[string]any, error) {
	projectDir = filepath.Clean(strings.TrimSpace(projectDir))
	if projectDir == "" || projectDir == "." {
		return nil, rpcInternal("project directory is required", nil)
	}
	files := make([]map[string]any, 0, limit)
	err := filepath.WalkDir(projectDir, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if path == projectDir {
			return nil
		}
		rel, relErr := filepath.Rel(projectDir, path)
		if relErr != nil {
			return relErr
		}
		if strings.HasPrefix(rel, ".git") || strings.HasPrefix(rel, ".echothink") {
			if d.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		if d.IsDir() {
			return nil
		}
		info, err := d.Info()
		if err != nil {
			return err
		}
		files = append(files, map[string]any{
			"path":         filepath.ToSlash(rel),
			"size":         info.Size(),
			"modified_time": info.ModTime().UTC().Format(time.RFC3339Nano),
		})
		if len(files) >= limit {
			return io.EOF
		}
		return nil
	})
	if err != nil && !errors.Is(err, io.EOF) {
		return nil, rpcInternal("collect project files failed", err)
	}
	sort.Slice(files, func(i, j int) bool { return files[i]["path"].(string) < files[j]["path"].(string) })
	return files, nil
}

func resolveAssetRequest(projectDir string, params json.RawMessage) (*assets.AssetRef, *assets.LockFile, error) {
	payload, err := decodeObjectParams(params)
	if err != nil {
		return nil, nil, err
	}
	ref := assets.AssetRef{
		AssetID:      stringFromMap(payload, "asset_id", "assetID", "id"),
		Repo:         stringFromMap(payload, "repo", "repository"),
		Ref:          stringFromMap(payload, "ref", "branch"),
		CommitID:     stringFromMap(payload, "commit_id", "commitID", "commit"),
		Tag:          stringFromMap(payload, "tag"),
		ImportTarget: stringFromMap(payload, "import_target", "importTarget", "path"),
	}
	lock, err := assets.LoadLockFile(projectDir)
	if err != nil {
		return nil, nil, err
	}
	if lock.Assets == nil {
		lock.Assets = make(map[string]*assets.AssetRef)
	}
	if strings.TrimSpace(ref.AssetID) != "" {
		if existing, ok := lock.Assets[strings.TrimSpace(ref.AssetID)]; ok && existing != nil {
			merged := *existing
			if strings.TrimSpace(ref.Repo) != "" {
				merged.Repo = strings.TrimSpace(ref.Repo)
			}
			if strings.TrimSpace(ref.Ref) != "" {
				merged.Ref = strings.TrimSpace(ref.Ref)
			}
			if strings.TrimSpace(ref.CommitID) != "" {
				merged.CommitID = strings.TrimSpace(ref.CommitID)
			}
			if strings.TrimSpace(ref.Tag) != "" {
				merged.Tag = strings.TrimSpace(ref.Tag)
			}
			if strings.TrimSpace(ref.ImportTarget) != "" {
				merged.ImportTarget = strings.TrimSpace(ref.ImportTarget)
			}
			ref = merged
		}
	}
	if strings.TrimSpace(ref.AssetID) == "" {
		return nil, nil, rpcInvalidParams("asset_id is required", nil)
	}
	if strings.TrimSpace(ref.ImportTarget) == "" {
		return nil, nil, rpcInvalidParams("import_target is required", nil)
	}
	return &ref, lock, nil
}

func patchPreflight(projectDir string, req patchRequest) (map[string]any, error) {
	validated, err := validatePatchRequest(projectDir, req)
	if err != nil {
		return nil, err
	}
	paths := make([]string, 0, len(validated))
	for _, op := range validated {
		paths = append(paths, op.Path)
		if op.OldPath != "" {
			paths = append(paths, op.OldPath)
		}
	}
	sort.Strings(paths)
	return map[string]any{"valid": true, "operation_count": len(validated), "paths": paths}, nil
}

func patchApply(ctx context.Context, projectDir string, j *journal.Journal, req patchRequest) (map[string]any, error) {
	validated, err := validatePatchRequest(projectDir, req)
	if err != nil {
		return nil, err
	}
	entry, err := j.Begin(req.WorkItemID, req.TaskRunID)
	if err != nil {
		return nil, rpcInternal("begin journal entry failed", err)
	}
	manifest := rollbackManifest{ChangeSetID: entry.ID, Entries: make([]rollbackRecord, 0, len(validated))}
	backupDir := filepath.Join(projectDir, rollbackRootDir, entry.ID)
	if err := os.MkdirAll(backupDir, 0o755); err != nil {
		_ = j.MarkFailed(entry.ID, err.Error())
		return nil, rpcInternal("create rollback directory failed", err)
	}

	for idx, op := range validated {
		select {
		case <-ctx.Done():
			_ = j.MarkFailed(entry.ID, ctx.Err().Error())
			return nil, rpcInternal("patch apply canceled", ctx.Err())
		default:
		}

		if preimage, ok := hashFileIfExists(resolveProjectPath(projectDir, op.Path)); ok {
			_ = j.SetPreimage(entry.ID, op.Path, preimage)
		}
		if op.OldPath != "" {
			if preimage, ok := hashFileIfExists(resolveProjectPath(projectDir, op.OldPath)); ok {
				_ = j.SetPreimage(entry.ID, op.OldPath, preimage)
			}
		}

		record, err := executePatchOperation(projectDir, backupDir, idx, op)
		if err != nil {
			_ = j.MarkFailed(entry.ID, err.Error())
			return nil, err
		}
		manifest.Entries = append(manifest.Entries, record)
		if err := persistRollbackManifest(backupDir, manifest); err != nil {
			_ = j.MarkFailed(entry.ID, err.Error())
			return nil, rpcInternal("persist rollback manifest failed", err)
		}
		if err := j.AddOperation(entry.ID, journal.OperationEntry{Type: op.Type, Path: op.Path, Description: op.Description, Reversible: true}); err != nil {
			_ = j.MarkFailed(entry.ID, err.Error())
			return nil, rpcInternal("record journal operation failed", err)
		}
		if postimage, ok := hashFileIfExists(resolveProjectPath(projectDir, op.Path)); ok {
			_ = j.SetPostimage(entry.ID, op.Path, postimage)
		}
		if op.OldPath != "" {
			if postimage, ok := hashFileIfExists(resolveProjectPath(projectDir, op.OldPath)); ok {
				_ = j.SetPostimage(entry.ID, op.OldPath, postimage)
			}
		}
	}

	if err := j.Complete(entry.ID); err != nil {
		return nil, rpcInternal("complete journal entry failed", err)
	}
	return map[string]any{"change_set_id": entry.ID, "applied": true, "operation_count": len(validated)}, nil
}

func patchRollback(projectDir string, j *journal.Journal, changeSetID string) (map[string]any, error) {
	entry, err := j.GetByID(changeSetID)
	if err != nil {
		return nil, err
	}
	backupDir := filepath.Join(projectDir, rollbackRootDir, changeSetID)
	manifest, err := loadRollbackManifest(backupDir)
	if err != nil {
		return nil, err
	}

	for idx := len(manifest.Entries) - 1; idx >= 0; idx-- {
		record := manifest.Entries[idx]
		if err := rollbackRecordEntry(projectDir, record); err != nil {
			_ = j.MarkFailed(changeSetID, err.Error())
			return nil, err
		}
	}
	if err := j.MarkRolledBack(changeSetID); err != nil {
		return nil, rpcInternal("mark journal rolled back failed", err)
	}
	return map[string]any{"change_set_id": entry.ID, "rolled_back": true}, nil
}

func executePatchOperation(projectDir, backupDir string, idx int, op patchOperation) (rollbackRecord, error) {
	targetPath := resolveProjectPath(projectDir, op.Path)
	record := rollbackRecord{Type: op.Type, Path: op.Path}
	info, err := os.Stat(targetPath)
	if err == nil {
		record.Existed = true
		if !info.IsDir() {
			backupPath := filepath.Join(backupDir, fmt.Sprintf("%03d.bak", idx))
			if err := copyFile(targetPath, backupPath); err != nil {
				return rollbackRecord{}, rpcInternal("backup existing file failed", err)
			}
			record.BackupPath = backupPath
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return rollbackRecord{}, rpcInternal("inspect patch target failed", err)
	}

	switch op.Type {
	case "write", "create":
		content, err := decodePatchContent(op)
		if err != nil {
			return rollbackRecord{}, err
		}
		if err := os.MkdirAll(filepath.Dir(targetPath), 0o755); err != nil {
			return rollbackRecord{}, rpcInternal("create patch target directory failed", err)
		}
		if err := os.WriteFile(targetPath, content, 0o644); err != nil {
			return rollbackRecord{}, rpcInternal("write patch target failed", err)
		}
		record.Created = !record.Existed
	case "append":
		content, err := decodePatchContent(op)
		if err != nil {
			return rollbackRecord{}, err
		}
		if err := os.MkdirAll(filepath.Dir(targetPath), 0o755); err != nil {
			return rollbackRecord{}, rpcInternal("create patch target directory failed", err)
		}
		file, err := os.OpenFile(targetPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
		if err != nil {
			return rollbackRecord{}, rpcInternal("open patch append target failed", err)
		}
		if _, err := file.Write(content); err != nil {
			_ = file.Close()
			return rollbackRecord{}, rpcInternal("append patch content failed", err)
		}
		if err := file.Close(); err != nil {
			return rollbackRecord{}, rpcInternal("close patch append target failed", err)
		}
		record.Created = !record.Existed
	case "delete":
		if err := os.Remove(targetPath); err != nil && !errors.Is(err, os.ErrNotExist) {
			return rollbackRecord{}, rpcInternal("delete patch target failed", err)
		}
	case "rename":
		oldPath := resolveProjectPath(projectDir, op.OldPath)
		if _, err := os.Stat(oldPath); err != nil {
			return rollbackRecord{}, rpcInternal("rename source does not exist", err)
		}
		if _, err := os.Stat(targetPath); err == nil {
			return rollbackRecord{}, rpcInvalidParams("rename destination already exists", map[string]any{"path": op.Path})
		}
		if err := os.MkdirAll(filepath.Dir(targetPath), 0o755); err != nil {
			return rollbackRecord{}, rpcInternal("create rename destination directory failed", err)
		}
		if err := os.Rename(oldPath, targetPath); err != nil {
			return rollbackRecord{}, rpcInternal("rename patch target failed", err)
		}
		record.OldPath = op.OldPath
	case "mkdir":
		if err := os.MkdirAll(targetPath, 0o755); err != nil {
			return rollbackRecord{}, rpcInternal("create directory failed", err)
		}
		record.Created = !record.Existed
	default:
		return rollbackRecord{}, rpcInvalidParams("unsupported patch operation type", map[string]any{"type": op.Type})
	}
	return record, nil
}

func rollbackRecordEntry(projectDir string, record rollbackRecord) error {
	targetPath := resolveProjectPath(projectDir, record.Path)
	switch record.Type {
	case "write", "create", "append":
		if record.Existed && record.BackupPath != "" {
			return copyFile(record.BackupPath, targetPath)
		}
		if record.Created {
			if err := os.Remove(targetPath); err != nil && !errors.Is(err, os.ErrNotExist) {
				return rpcInternal("remove created patch target failed", err)
			}
		}
	case "delete":
		if record.BackupPath != "" {
			return copyFile(record.BackupPath, targetPath)
		}
	case "rename":
		oldPath := resolveProjectPath(projectDir, record.OldPath)
		if err := os.MkdirAll(filepath.Dir(oldPath), 0o755); err != nil {
			return rpcInternal("create rollback rename directory failed", err)
		}
		if err := os.Rename(targetPath, oldPath); err != nil {
			return rpcInternal("restore renamed file failed", err)
		}
	case "mkdir":
		if record.Created {
			if err := os.Remove(targetPath); err != nil && !errors.Is(err, os.ErrNotExist) {
				return rpcInternal("remove created directory failed", err)
			}
		}
	}
	return nil
}

func validatePatchRequest(projectDir string, req patchRequest) ([]patchOperation, error) {
	projectDir = filepath.Clean(strings.TrimSpace(projectDir))
	if projectDir == "" || projectDir == "." {
		return nil, rpcInternal("project directory is required", nil)
	}
	if len(req.Operations) == 0 {
		return nil, rpcInvalidParams("at least one patch operation is required", nil)
	}
	validated := make([]patchOperation, 0, len(req.Operations))
	for idx, op := range req.Operations {
		op.Type = strings.ToLower(strings.TrimSpace(op.Type))
		op.Path = strings.TrimSpace(op.Path)
		op.OldPath = strings.TrimSpace(op.OldPath)
		if op.Type == "" {
			return nil, rpcInvalidParams("patch operation type is required", map[string]any{"index": idx})
		}
		if op.Type != "rename" && op.Path == "" {
			return nil, rpcInvalidParams("patch operation path is required", map[string]any{"index": idx})
		}
		if op.Path != "" {
			if _, err := secureProjectPath(projectDir, op.Path); err != nil {
				return nil, rpcInvalidParams("invalid patch path", map[string]any{"index": idx, "path": op.Path, "error": err.Error()})
			}
		}
		if op.Type == "rename" {
			if op.OldPath == "" || op.Path == "" {
				return nil, rpcInvalidParams("rename requires old_path and path", map[string]any{"index": idx})
			}
			if _, err := secureProjectPath(projectDir, op.OldPath); err != nil {
				return nil, rpcInvalidParams("invalid rename source path", map[string]any{"index": idx, "path": op.OldPath, "error": err.Error()})
			}
		}
		validated = append(validated, op)
	}
	return validated, nil
}

func decodePatchRequest(params json.RawMessage) (patchRequest, error) {
	var req patchRequest
	if err := decodeParams(params, &req); err != nil {
		return patchRequest{}, err
	}
	return req, nil
}

func decodePatchContent(op patchOperation) ([]byte, error) {
	if strings.EqualFold(strings.TrimSpace(op.Encoding), "base64") {
		payload, err := base64.StdEncoding.DecodeString(op.Content)
		if err != nil {
			return nil, rpcInvalidParams("invalid base64 patch content", err.Error())
		}
		return payload, nil
	}
	return []byte(op.Content), nil
}

func persistRollbackManifest(backupDir string, manifest rollbackManifest) error {
	payload, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return err
	}
	payload = append(payload, '\n')
	return os.WriteFile(filepath.Join(backupDir, "manifest.json"), payload, 0o644)
}

func loadRollbackManifest(backupDir string) (rollbackManifest, error) {
	data, err := os.ReadFile(filepath.Join(backupDir, "manifest.json"))
	if err != nil {
		return rollbackManifest{}, rpcInternal("read rollback manifest failed", err)
	}
	var manifest rollbackManifest
	if err := json.Unmarshal(data, &manifest); err != nil {
		return rollbackManifest{}, rpcInternal("parse rollback manifest failed", err)
	}
	return manifest, nil
}

func collectEditorLogs(projectDir string, req logCollectParams) (map[string]any, error) {
	maxBytes := req.MaxBytes
	if maxBytes <= 0 {
		maxBytes = defaultLogBytes
	}
	paths := make([]string, 0, len(req.Paths)+3)
	for _, path := range req.Paths {
		if strings.TrimSpace(path) != "" {
			paths = append(paths, strings.TrimSpace(path))
		}
	}
	for _, candidate := range []string{
		filepath.Join(projectDir, ".godot", "editor", "editor.log"),
		filepath.Join(projectDir, ".godot", "logs", "editor.log"),
		filepath.Join(projectDir, ".echothink", "bridge.log"),
	} {
		paths = append(paths, candidate)
	}

	entries := make([]map[string]any, 0)
	seen := make(map[string]struct{})
	for _, path := range paths {
		if path == "" {
			continue
		}
		resolved := path
		if !filepath.IsAbs(resolved) {
			resolved = filepath.Join(projectDir, resolved)
		}
		resolved = filepath.Clean(resolved)
		if _, ok := seen[resolved]; ok {
			continue
		}
		seen[resolved] = struct{}{}
		entry, ok, err := readLogEntry(resolved, maxBytes)
		if err != nil {
			return nil, err
		}
		if ok {
			entries = append(entries, entry)
		}
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i]["path"].(string) < entries[j]["path"].(string) })
	return map[string]any{"collected_at": time.Now().UTC().Format(time.RFC3339Nano), "logs": entries}, nil
}

func readLogEntry(path string, maxBytes int64) (map[string]any, bool, error) {
	info, err := os.Stat(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, false, nil
		}
		return nil, false, rpcInternal("inspect log file failed", err)
	}
	if info.IsDir() {
		return nil, false, nil
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, false, rpcInternal("open log file failed", err)
	}
	defer file.Close()

	truncated := false
	if info.Size() > maxBytes {
		truncated = true
		if _, err := file.Seek(info.Size()-maxBytes, io.SeekStart); err != nil {
			return nil, false, rpcInternal("seek log file failed", err)
		}
	}
	data, err := io.ReadAll(io.LimitReader(file, maxBytes))
	if err != nil {
		return nil, false, rpcInternal("read log file failed", err)
	}
	return map[string]any{
		"path":      path,
		"size":      info.Size(),
		"truncated": truncated,
		"content":   string(data),
	}, true, nil
}

func runTestStrategy(ctx context.Context, projectDir string, req testRunParams) (map[string]any, error) {
	command := req.Command
	strategy := strings.ToLower(strings.TrimSpace(req.Strategy))
	if len(command) == 0 {
		switch strategy {
		case "", "go_test":
			command = []string{"go", "test", "./..."}
		default:
			return nil, rpcInvalidParams("command is required for the requested test strategy", map[string]any{"strategy": req.Strategy})
		}
	}
	if len(command) == 0 {
		return nil, rpcInvalidParams("test command is required", nil)
	}

	testCtx := ctx
	if req.TimeoutSeconds > 0 {
		var cancel context.CancelFunc
		testCtx, cancel = context.WithTimeout(ctx, time.Duration(req.TimeoutSeconds)*time.Second)
		defer cancel()
	}

	startedAt := time.Now()
	stdout, stderr, exitCode, err := runCommand(testCtx, projectDir, req.Env, command...)
	result := map[string]any{
		"strategy":        firstNonEmpty(req.Strategy, "go_test"),
		"command":         command,
		"project_dir":     projectDir,
		"started_at":      startedAt.UTC().Format(time.RFC3339Nano),
		"duration_ms":     time.Since(startedAt).Milliseconds(),
		"exit_code":       exitCode,
		"success":         err == nil,
		"stdout":          stdout,
		"stderr":          stderr,
		"metadata":        req.Metadata,
	}
	if err != nil {
		result["error"] = err.Error()
	}
	return result, nil
}

func gitStatus(ctx context.Context, projectDir string) (map[string]any, error) {
	stdout, stderr, exitCode, err := runCommand(ctx, projectDir, nil, "git", "-C", projectDir, "status", "--short", "--branch")
	if err != nil {
		return nil, rpcInternal("git status failed", fmt.Errorf("%w: %s", err, strings.TrimSpace(stderr)))
	}
	lines := splitNonEmptyLines(stdout)
	branch := ""
	if len(lines) > 0 && strings.HasPrefix(lines[0], "##") {
		branch = strings.TrimSpace(strings.TrimPrefix(lines[0], "##"))
	}
	clean := len(lines) == 0 || (len(lines) == 1 && strings.HasPrefix(lines[0], "##"))
	return map[string]any{"branch": branch, "lines": lines, "clean": clean, "exit_code": exitCode}, nil
}

func gitDiff(ctx context.Context, projectDir string, req gitDiffParams) (map[string]any, error) {
	args := []string{"git", "-C", projectDir, "diff"}
	if req.Staged {
		args = append(args, "--cached")
	}
	if strings.TrimSpace(req.Base) != "" {
		args = append(args, strings.TrimSpace(req.Base))
	}
	if strings.TrimSpace(req.Head) != "" {
		args = append(args, strings.TrimSpace(req.Head))
	}
	if len(req.Paths) > 0 {
		args = append(args, "--")
		args = append(args, req.Paths...)
	}
	stdout, stderr, exitCode, err := runCommand(ctx, projectDir, nil, args...)
	if err != nil {
		return nil, rpcInternal("git diff failed", fmt.Errorf("%w: %s", err, strings.TrimSpace(stderr)))
	}
	return map[string]any{"diff": stdout, "exit_code": exitCode}, nil
}

func gitBranches(ctx context.Context, projectDir string) (map[string]any, error) {
	stdout, stderr, exitCode, err := runCommand(ctx, projectDir, nil, "git", "-C", projectDir, "branch", "--list", "--format=%(HEAD) %(refname:short)")
	if err != nil {
		return nil, rpcInternal("git branch listing failed", fmt.Errorf("%w: %s", err, strings.TrimSpace(stderr)))
	}
	branches := make([]map[string]any, 0)
	for _, line := range splitNonEmptyLines(stdout) {
		current := strings.HasPrefix(line, "*")
		name := strings.TrimSpace(strings.TrimPrefix(line, "*"))
		if name == line {
			name = strings.TrimSpace(strings.TrimPrefix(line, " "))
		}
		branches = append(branches, map[string]any{"name": name, "current": current})
	}
	return map[string]any{"branches": branches, "exit_code": exitCode}, nil
}

func runCommand(ctx context.Context, dir string, env map[string]string, args ...string) (string, string, int, error) {
	if len(args) == 0 {
		return "", "", -1, errors.New("command is required")
	}
	cmd := exec.CommandContext(ctx, args[0], args[1:]...)
	cmd.Dir = dir
	cmd.Env = os.Environ()
	for key, value := range env {
		cmd.Env = append(cmd.Env, key+"="+value)
	}
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	if err == nil {
		return stdout.String(), stderr.String(), 0, nil
	}
	exitCode := -1
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		return stdout.String(), stderr.String(), exitErr.ExitCode(), err
	}
	return stdout.String(), stderr.String(), exitCode, err
}

func hashFileIfExists(path string) (string, bool) {
	file, err := os.Open(path)
	if err != nil {
		return "", false
	}
	defer file.Close()
	hasher := sha256.New()
	if _, err := io.Copy(hasher, file); err != nil {
		return "", false
	}
	return hex.EncodeToString(hasher.Sum(nil)), true
}

func copyFile(src, dst string) error {
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	info, err := in.Stat()
	if err != nil {
		return err
	}
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer out.Close()
	if _, err := io.Copy(out, in); err != nil {
		return err
	}
	if err := out.Chmod(info.Mode()); err != nil {
		return err
	}
	return out.Close()
}

func decodeParams(params json.RawMessage, dst any) error {
	if dst == nil {
		return rpcInternal("decode destination is nil", nil)
	}
	if !hasParams(params) {
		return nil
	}
	if err := json.Unmarshal(params, dst); err != nil {
		return rpcInvalidParams("params are invalid JSON", err.Error())
	}
	return nil
}

func decodeObjectParams(params json.RawMessage) (map[string]any, error) {
	if !hasParams(params) {
		return map[string]any{}, nil
	}
	var payload map[string]any
	if err := decodeParams(params, &payload); err != nil {
		return nil, err
	}
	if payload == nil {
		payload = map[string]any{}
	}
	return payload, nil
}

func stringFromMap(values map[string]any, keys ...string) string {
	for _, key := range keys {
		if values == nil {
			break
		}
		if raw, ok := values[key]; ok {
			switch typed := raw.(type) {
			case string:
				if strings.TrimSpace(typed) != "" {
					return strings.TrimSpace(typed)
				}
			}
		}
	}
	return ""
}

func hasParams(params json.RawMessage) bool {
	trimmed := strings.TrimSpace(string(params))
	return trimmed != "" && trimmed != "null"
}

func secureProjectPath(projectDir, rel string) (string, error) {
	projectDir = filepath.Clean(strings.TrimSpace(projectDir))
	if projectDir == "" || projectDir == "." {
		return "", errors.New("project directory is required")
	}
	rel = strings.TrimSpace(rel)
	if rel == "" {
		return "", errors.New("path is required")
	}
	if filepath.IsAbs(rel) {
		return "", errors.New("path must be relative")
	}
	resolved := filepath.Clean(filepath.Join(projectDir, rel))
	base := filepath.Clean(projectDir)
	back, err := filepath.Rel(base, resolved)
	if err != nil {
		return "", err
	}
	if back == ".." || strings.HasPrefix(back, ".."+string(os.PathSeparator)) {
		return "", errors.New("path escapes project directory")
	}
	return resolved, nil
}

func resolveProjectPath(projectDir, rel string) string {
	path, err := secureProjectPath(projectDir, rel)
	if err != nil {
		return filepath.Join(projectDir, rel)
	}
	return path
}

func splitNonEmptyLines(value string) []string {
	lines := strings.Split(strings.ReplaceAll(value, "\r\n", "\n"), "\n")
	out := make([]string, 0, len(lines))
	for _, line := range lines {
		line = strings.TrimRight(line, " ")
		if strings.TrimSpace(line) != "" {
			out = append(out, line)
		}
	}
	return out
}

func valueFromConfig(cfg *config.Config, get func(*config.Config) string) string {
	if cfg == nil || get == nil {
		return ""
	}
	return strings.TrimSpace(get(cfg))
}

func toRPCError(err error) error {
	var rpcErr *ipc.RPCError
	if errors.As(err, &rpcErr) {
		return rpcErr
	}
	var apiErr *gateway.APIError
	if errors.As(err, &apiErr) {
		return &ipc.RPCError{Code: ipc.InternalError, Message: apiErr.Message, Data: map[string]any{"status_code": apiErr.StatusCode}}
	}
	return &ipc.RPCError{Code: ipc.InternalError, Message: err.Error()}
}

func rpcInvalidParams(message string, data any) *ipc.RPCError {
	return &ipc.RPCError{Code: ipc.InvalidParams, Message: message, Data: data}
}

func rpcInternal(message string, cause error) *ipc.RPCError {
	if cause == nil {
		return &ipc.RPCError{Code: ipc.InternalError, Message: message}
	}
	return &ipc.RPCError{Code: ipc.InternalError, Message: message, Data: cause.Error()}
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return strings.TrimSpace(value)
		}
	}
	return ""
}
