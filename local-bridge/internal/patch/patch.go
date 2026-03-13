package patch

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	bridgegit "github.com/echothink/godot-local-bridge/internal/git"
	"github.com/echothink/godot-local-bridge/internal/journal"
)

const missingHash = "missing"

var packageLogger = slog.Default()

// Operation describes a single proposal step.
type Operation struct {
	Type        string         `json:"type"`
	Action      string         `json:"action,omitempty"`
	Path        string         `json:"path,omitempty"`
	TargetPath  string         `json:"target_path,omitempty"`
	Content     string         `json:"content,omitempty"`
	Description string         `json:"description,omitempty"`
	Reversible  bool           `json:"reversible"`
	Params      map[string]any `json:"params,omitempty"`
}

// Proposal contains a list of structured operations to apply locally.
type Proposal struct {
	ProposalID string      `json:"proposal_id"`
	WorkItemID string      `json:"work_item_id"`
	TaskRunID  string      `json:"task_run_id,omitempty"`
	Operations []Operation `json:"operations"`
	RiskLevel  string      `json:"risk_level,omitempty"`
}

// PreflightResult captures proposal validation findings before mutation.
type PreflightResult struct {
	OK            bool     `json:"ok"`
	Warnings      []string `json:"warnings,omitempty"`
	Errors        []string `json:"errors,omitempty"`
	AffectedPaths []string `json:"affected_paths,omitempty"`
}

// ApplyResult summarizes proposal execution and journal tracking.
type ApplyResult struct {
	ChangesetID string   `json:"changeset_id,omitempty"`
	Applied     []string `json:"applied,omitempty"`
	Failed      []string `json:"failed,omitempty"`
	Error       string   `json:"error,omitempty"`
}

// Error captures validation and application failures with path context.
type Error struct {
	Op   string
	Type string
	Path string
	Err  error
}

func (e *Error) Error() string {
	if e == nil {
		return "patch: <nil>"
	}

	var parts []string
	if strings.TrimSpace(e.Op) != "" {
		parts = append(parts, e.Op)
	}
	if strings.TrimSpace(e.Type) != "" {
		parts = append(parts, fmt.Sprintf("type=%q", e.Type))
	}
	if strings.TrimSpace(e.Path) != "" {
		parts = append(parts, fmt.Sprintf("path=%q", e.Path))
	}
	if e.Err != nil {
		parts = append(parts, e.Err.Error())
	}

	return "patch: " + strings.Join(parts, ": ")
}

func (e *Error) Unwrap() error {
	if e == nil {
		return nil
	}
	return e.Err
}

// ParseProposal parses a JSON proposal payload into a validated Proposal.
func ParseProposal(data []byte) (*Proposal, error) {
	if len(bytes.TrimSpace(data)) == 0 {
		return nil, &Error{Op: "parse proposal", Err: errors.New("proposal data is required")}
	}

	type rawOperation struct {
		Type        string         `json:"type"`
		Action      string         `json:"action"`
		Path        string         `json:"path"`
		TargetPath  string         `json:"target_path"`
		Content     string         `json:"content"`
		Patch       string         `json:"patch"`
		Description string         `json:"description"`
		Reversible  *bool          `json:"reversible"`
		Params      map[string]any `json:"params"`
		Property    string         `json:"property"`
		Value       any            `json:"value"`
		Actions     []any          `json:"actions"`
	}

	type rawProposal struct {
		ProposalID string         `json:"proposal_id"`
		PatchID    string         `json:"patch_id"`
		WorkItemID string         `json:"work_item_id"`
		TaskRunID  string         `json:"task_run_id"`
		RiskLevel  string         `json:"risk_level"`
		RiskSummary string        `json:"risk_summary"`
		Operations []rawOperation `json:"operations"`
	}

	var raw rawProposal
	decoder := json.NewDecoder(bytes.NewReader(data))
	if err := decoder.Decode(&raw); err != nil {
		return nil, &Error{Op: "parse proposal", Err: err}
	}

	proposal := &Proposal{
		ProposalID: strings.TrimSpace(raw.ProposalID),
		WorkItemID: strings.TrimSpace(raw.WorkItemID),
		TaskRunID:  strings.TrimSpace(raw.TaskRunID),
		RiskLevel:  strings.TrimSpace(raw.RiskLevel),
		Operations: make([]Operation, 0, len(raw.Operations)),
	}
	if proposal.ProposalID == "" {
		proposal.ProposalID = strings.TrimSpace(raw.PatchID)
	}
	if proposal.RiskLevel == "" {
		proposal.RiskLevel = strings.TrimSpace(raw.RiskSummary)
	}

	for _, rawOp := range raw.Operations {
		params := cloneParams(rawOp.Params)
		if rawOp.Value != nil {
			params["value"] = rawOp.Value
		}
		if len(rawOp.Actions) > 0 {
			params["actions"] = rawOp.Actions
		}

		path := strings.TrimSpace(rawOp.Path)
		if path == "" {
			path = strings.TrimSpace(rawOp.Property)
		}

		op := Operation{
			Type:        strings.TrimSpace(rawOp.Type),
			Action:      strings.TrimSpace(rawOp.Action),
			Path:        path,
			TargetPath:  strings.TrimSpace(rawOp.TargetPath),
			Content:     rawOp.Content,
			Description: strings.TrimSpace(rawOp.Description),
			Params:      params,
		}
		if strings.TrimSpace(op.Content) == "" {
			op.Content = rawOp.Patch
		}
		if rawOp.Reversible != nil {
			op.Reversible = *rawOp.Reversible
		}

		proposal.Operations = append(proposal.Operations, op)
	}

	if err := validateProposal(proposal); err != nil {
		return nil, err
	}

	return proposal, nil
}

// Preflight validates operations, touched paths, and simple filesystem safety.
func Preflight(ctx context.Context, projectDir string, proposal *Proposal) (*PreflightResult, error) {
	projectDir, err := validateProjectDir(projectDir)
	if err != nil {
		return nil, err
	}
	if ctx == nil {
		return nil, &Error{Op: "preflight", Err: errors.New("context is nil")}
	}
	if err := validateProposal(proposal); err != nil {
		return nil, err
	}

	result := &PreflightResult{}
	paths := make(map[string]struct{})
	if risk := strings.TrimSpace(proposal.RiskLevel); risk != "" && !strings.EqualFold(risk, "low") {
		result.Warnings = append(result.Warnings, fmt.Sprintf("proposal risk level is %q", risk))
	}

	for idx := range proposal.Operations {
		if err := ctx.Err(); err != nil {
			return nil, &Error{Op: "preflight", Err: err}
		}

		op := proposal.Operations[idx]
		warnings, failures, affected, err := preflightOperation(projectDir, &op)
		if err != nil {
			return nil, err
		}
		result.Warnings = append(result.Warnings, warnings...)
		result.Errors = append(result.Errors, failures...)
		for _, path := range affected {
			if path == "" {
				continue
			}
			paths[path] = struct{}{}
		}
	}

	for path := range paths {
		result.AffectedPaths = append(result.AffectedPaths, path)
	}
	sort.Strings(result.Warnings)
	sort.Strings(result.Errors)
	sort.Strings(result.AffectedPaths)
	result.OK = len(result.Errors) == 0

	packageLogger.Debug("proposal preflight completed",
		"project_dir", projectDir,
		"proposal_id", proposal.ProposalID,
		"ok", result.OK,
		"warnings", len(result.Warnings),
		"errors", len(result.Errors),
	)

	return result, nil
}

// Apply executes a proposal against projectDir and records hashes in journal.
func Apply(ctx context.Context, projectDir string, proposal *Proposal, jrnl *journal.Journal) (*ApplyResult, error) {
	projectDir, err := validateProjectDir(projectDir)
	if err != nil {
		return nil, err
	}
	if ctx == nil {
		return nil, &Error{Op: "apply", Err: errors.New("context is nil")}
	}
	if err := validateProposal(proposal); err != nil {
		return nil, err
	}
	if jrnl == nil {
		return nil, &Error{Op: "apply", Err: errors.New("journal is required")}
	}

	preflight, err := Preflight(ctx, projectDir, proposal)
	if err != nil {
		return nil, err
	}
	if !preflight.OK {
		applyErr := &Error{Op: "apply", Err: fmt.Errorf("preflight failed: %s", strings.Join(preflight.Errors, "; "))}
		return &ApplyResult{Error: applyErr.Error()}, applyErr
	}

	entry, err := jrnl.Begin(proposal.WorkItemID, proposal.TaskRunID)
	if err != nil {
		return nil, &Error{Op: "apply", Err: err}
	}

	result := &ApplyResult{ChangesetID: entry.ID}

	for idx := range proposal.Operations {
		if err := ctx.Err(); err != nil {
			result.Error = err.Error()
			markErr := jrnl.MarkFailed(entry.ID, result.Error)
			return result, errors.Join(&Error{Op: "apply", Err: err}, markErr)
		}

		op := proposal.Operations[idx]
		normalizedType := normalizeType(op.Type)
		action, _ := normalizeAction(projectDir, normalizedType, &op)
		prePath, postPath, displayPath, err := operationPaths(projectDir, normalizedType, action, &op)
		if err != nil {
			result.Failed = append(result.Failed, displayPath)
			result.Error = err.Error()
			markErr := jrnl.MarkFailed(entry.ID, result.Error)
			return result, errors.Join(err, markErr)
		}

		description := strings.TrimSpace(op.Description)
		if description == "" {
			description = fmt.Sprintf("%s %s", action, displayPath)
		}

		if err := jrnl.AddOperation(entry.ID, journal.OperationEntry{
			Type:        normalizedType,
			Path:        displayPath,
			Description: description,
			Reversible:  op.Reversible,
		}); err != nil {
			result.Failed = append(result.Failed, displayPath)
			result.Error = err.Error()
			markErr := jrnl.MarkFailed(entry.ID, result.Error)
			return result, errors.Join(&Error{Op: "apply", Type: normalizedType, Path: displayPath, Err: err}, markErr)
		}

		if prePath != "" {
			preHash, hashErr := fileHashOrMissing(prePath)
			if hashErr != nil {
				result.Failed = append(result.Failed, displayPath)
				result.Error = hashErr.Error()
				markErr := jrnl.MarkFailed(entry.ID, result.Error)
				return result, errors.Join(hashErr, markErr)
			}
			if err := jrnl.SetPreimage(entry.ID, journalPath(projectDir, prePath), preHash); err != nil {
				result.Failed = append(result.Failed, displayPath)
				result.Error = err.Error()
				markErr := jrnl.MarkFailed(entry.ID, result.Error)
				return result, errors.Join(err, markErr)
			}
		}

		applyErr := applyOperation(ctx, projectDir, normalizedType, &op)
		if applyErr != nil {
			result.Failed = append(result.Failed, displayPath)
			result.Error = applyErr.Error()
			markErr := jrnl.MarkFailed(entry.ID, result.Error)
			return result, errors.Join(applyErr, markErr)
		}

		if postPath != "" {
			postHash, hashErr := fileHashOrMissing(postPath)
			if hashErr != nil {
				result.Failed = append(result.Failed, displayPath)
				result.Error = hashErr.Error()
				markErr := jrnl.MarkFailed(entry.ID, result.Error)
				return result, errors.Join(hashErr, markErr)
			}
			if err := jrnl.SetPostimage(entry.ID, journalPath(projectDir, postPath), postHash); err != nil {
				result.Failed = append(result.Failed, displayPath)
				result.Error = err.Error()
				markErr := jrnl.MarkFailed(entry.ID, result.Error)
				return result, errors.Join(err, markErr)
			}
		}

		result.Applied = append(result.Applied, displayPath)
	}

	if err := jrnl.Complete(entry.ID); err != nil {
		result.Error = err.Error()
		return result, &Error{Op: "apply", Err: err}
	}

	packageLogger.Info("proposal applied",
		"project_dir", projectDir,
		"proposal_id", proposal.ProposalID,
		"changeset_id", entry.ID,
		"operations", len(proposal.Operations),
	)

	return result, nil
}

// applyTextPatch applies text file mutations or unified patches.
func applyTextPatch(ctx context.Context, projectDir string, op *Operation) error {
	return applyFileOperation(ctx, projectDir, normalizeType(op.Type), op, false)
}

// applySceneOp applies scene-file mutations for .tscn and .scn files.
func applySceneOp(ctx context.Context, projectDir string, op *Operation) error {
	if err := validateExtension(op.Path, op.TargetPath, map[string]struct{}{".tscn": {}, ".scn": {}}); err != nil {
		return &Error{Op: "apply scene op", Type: normalizeType(op.Type), Path: op.Path, Err: err}
	}
	return applyFileOperation(ctx, projectDir, normalizeType(op.Type), op, false)
}

// applyResourceOp applies resource-file mutations for common Godot resource types.
func applyResourceOp(ctx context.Context, projectDir string, op *Operation) error {
	allowed := map[string]struct{}{
		".res": {}, ".tres": {}, ".shader": {}, ".gdshader": {}, ".material": {}, ".theme": {},
	}
	if err := validateExtension(op.Path, op.TargetPath, allowed); err != nil {
		return &Error{Op: "apply resource op", Type: normalizeType(op.Type), Path: op.Path, Err: err}
	}
	return applyFileOperation(ctx, projectDir, normalizeType(op.Type), op, false)
}

// applyAssetImport applies binary or text asset file mutations.
func applyAssetImport(ctx context.Context, projectDir string, op *Operation) error {
	return applyFileOperation(ctx, projectDir, normalizeType(op.Type), op, true)
}

// applyProjectSetting mutates key/value entries in project.godot.
func applyProjectSetting(ctx context.Context, projectDir string, op *Operation) error {
	if err := ctx.Err(); err != nil {
		return &Error{Op: "apply project setting", Type: normalizeType(op.Type), Path: op.Path, Err: err}
	}

	projectDir, err := validateProjectDir(projectDir)
	if err != nil {
		return err
	}
	if op == nil {
		return &Error{Op: "apply project setting", Err: errors.New("operation is nil")}
	}

	settingPath := settingIdentifier(op)
	section, key, err := splitProjectSetting(settingPath)
	if err != nil {
		return &Error{Op: "apply project setting", Type: normalizeType(op.Type), Path: settingPath, Err: err}
	}

	projectFile := filepath.Join(projectDir, "project.godot")
	data, err := os.ReadFile(projectFile)
	if err != nil {
		return &Error{Op: "apply project setting", Type: normalizeType(op.Type), Path: projectFile, Err: err}
	}

	action, _ := normalizeAction(projectDir, normalizeType(op.Type), op)
	lines := strings.Split(normalizeNewlines(string(data)), "\n")
	sectionHeader := "[" + section + "]"
	sectionStart, sectionEnd := findSectionBounds(lines, sectionHeader)

	keyLinePrefix := key + "="
	updated := false
	result := make([]string, 0, len(lines)+3)

	if action == "remove" {
		if sectionStart == -1 {
			return nil
		}
		for idx, line := range lines {
			if idx > sectionStart && idx < sectionEnd && strings.HasPrefix(strings.TrimSpace(line), keyLinePrefix) {
				updated = true
				continue
			}
			result = append(result, line)
		}
		if !updated {
			return nil
		}
		return writeFileAtomic(projectFile, []byte(strings.Join(trimTrailingBlankLines(result), "\n")+"\n"), 0o644)
	}

	valueExpr, err := projectSettingValue(op)
	if err != nil {
		return &Error{Op: "apply project setting", Type: normalizeType(op.Type), Path: settingPath, Err: err}
	}
	targetLine := keyLinePrefix + valueExpr

	if sectionStart == -1 {
		result = append(result, lines...)
		if len(result) > 0 && strings.TrimSpace(result[len(result)-1]) != "" {
			result = append(result, "")
		}
		result = append(result, sectionHeader, targetLine)
		return writeFileAtomic(projectFile, []byte(strings.Join(trimTrailingBlankLines(result), "\n")+"\n"), 0o644)
	}

	for idx, line := range lines {
		if idx > sectionStart && idx < sectionEnd && strings.HasPrefix(strings.TrimSpace(line), keyLinePrefix) {
			result = append(result, targetLine)
			updated = true
			continue
		}
		result = append(result, line)
		if idx == sectionEnd-1 && !updated {
			result = append(result, targetLine)
			updated = true
		}
	}

	if !updated {
		result = append(result, targetLine)
	}

	return writeFileAtomic(projectFile, []byte(strings.Join(trimTrailingBlankLines(result), "\n")+"\n"), 0o644)
}

// computeFileHash calculates the SHA256 of a file's current contents.
func computeFileHash(path string) (string, error) {
	path = filepath.Clean(strings.TrimSpace(path))
	if path == "" || path == "." {
		return "", &Error{Op: "compute file hash", Err: errors.New("path is required")}
	}

	file, err := os.Open(path)
	if err != nil {
		return "", &Error{Op: "compute file hash", Path: path, Err: err}
	}
	defer file.Close()

	hasher := sha256.New()
	if _, err := bufio.NewReader(file).WriteTo(hasher); err != nil {
		return "", &Error{Op: "compute file hash", Path: path, Err: err}
	}

	return hex.EncodeToString(hasher.Sum(nil)), nil
}

func validateProposal(proposal *Proposal) error {
	if proposal == nil {
		return &Error{Op: "validate proposal", Err: errors.New("proposal is nil")}
	}
	if strings.TrimSpace(proposal.ProposalID) == "" {
		return &Error{Op: "validate proposal", Err: errors.New("proposal ID is required")}
	}
	if strings.TrimSpace(proposal.WorkItemID) == "" {
		return &Error{Op: "validate proposal", Err: errors.New("work item ID is required")}
	}
	if len(proposal.Operations) == 0 {
		return &Error{Op: "validate proposal", Err: errors.New("at least one operation is required")}
	}

	for _, op := range proposal.Operations {
		normalizedType := normalizeType(op.Type)
		if normalizedType == "" {
			return &Error{Op: "validate proposal", Path: op.Path, Err: errors.New("operation type is required")}
		}
		if _, ok := allowedTypes()[normalizedType]; !ok {
			return &Error{Op: "validate proposal", Type: op.Type, Path: op.Path, Err: fmt.Errorf("unsupported operation type %q", op.Type)}
		}
		if normalizedType != "project_setting" && strings.TrimSpace(op.Path) == "" {
			return &Error{Op: "validate proposal", Type: normalizedType, Err: errors.New("operation path is required")}
		}
	}

	return nil
}

func preflightOperation(projectDir string, op *Operation) ([]string, []string, []string, error) {
	if op == nil {
		return nil, nil, nil, &Error{Op: "preflight operation", Err: errors.New("operation is nil")}
	}

	normalizedType := normalizeType(op.Type)
	action, err := normalizeAction(projectDir, normalizedType, op)
	if err != nil {
		return nil, nil, nil, &Error{Op: "preflight operation", Type: normalizedType, Path: op.Path, Err: err}
	}
	if _, ok := allowedActions(normalizedType)[action]; !ok {
		return nil, []string{fmt.Sprintf("unsupported action %q for %s", action, normalizedType)}, nil, nil
	}

	warnings := make([]string, 0)
	failures := make([]string, 0)
	affected := make([]string, 0, 2)

	switch normalizedType {
	case "text_patch", "scene_op", "resource_op", "asset_import":
		if normalizedType == "scene_op" {
			if err := validateExtension(op.Path, op.TargetPath, map[string]struct{}{".tscn": {}, ".scn": {}}); err != nil {
				failures = append(failures, err.Error())
			}
		}
		if normalizedType == "resource_op" {
			if err := validateExtension(op.Path, op.TargetPath, map[string]struct{}{".res": {}, ".tres": {}, ".shader": {}, ".gdshader": {}, ".material": {}, ".theme": {}}); err != nil {
				failures = append(failures, err.Error())
			}
		}

		primary, err := resolveProjectPath(projectDir, op.Path)
		if err != nil {
			failures = append(failures, err.Error())
			return warnings, failures, affected, nil
		}
		affected = append(affected, journalPath(projectDir, primary))

		var target string
		if strings.TrimSpace(op.TargetPath) != "" {
			target, err = resolveProjectPath(projectDir, op.TargetPath)
			if err != nil {
				failures = append(failures, err.Error())
				return warnings, failures, affected, nil
			}
			affected = append(affected, journalPath(projectDir, target))
		}

		exists := pathExists(primary)
		switch action {
		case "modify", "replace", "delete", "rename", "append":
			if !exists && action != "replace" {
				failures = append(failures, fmt.Sprintf("path %q does not exist", op.Path))
			}
		case "create":
			if exists {
				failures = append(failures, fmt.Sprintf("path %q already exists", op.Path))
			}
		case "apply_patch":
			if strings.TrimSpace(op.Content) == "" {
				failures = append(failures, "patch content is required")
			}
			if !exists {
				warnings = append(warnings, fmt.Sprintf("patch target %q does not exist before apply", op.Path))
			}
		}

		if action == "rename" && target == "" {
			failures = append(failures, "target_path is required for rename operations")
		}
		if action == "rename" && target != "" && pathExists(target) {
			failures = append(failures, fmt.Sprintf("target path %q already exists", op.TargetPath))
		}

		if err := checkWritableForAction(primary, target, action); err != nil {
			failures = append(failures, err.Error())
		}
	case "project_setting":
		settingPath := settingIdentifier(op)
		if _, _, err := splitProjectSetting(settingPath); err != nil {
			failures = append(failures, err.Error())
		}
		projectFile := filepath.Join(projectDir, "project.godot")
		affected = append(affected, journalPath(projectDir, projectFile))
		if err := checkWritableForAction(projectFile, "", action); err != nil {
			failures = append(failures, err.Error())
		}
	default:
		failures = append(failures, fmt.Sprintf("unsupported operation type %q", op.Type))
	}

	if !op.Reversible {
		warnings = append(warnings, fmt.Sprintf("operation on %q is marked non-reversible", coalesce(op.Path, settingIdentifier(op))))
	}
	if strings.EqualFold(strings.TrimSpace(op.Action), "delete") || action == "delete" {
		warnings = append(warnings, fmt.Sprintf("delete operation will remove %q", op.Path))
	}
	if strings.EqualFold(strings.TrimSpace(op.TargetPath), "") == false && action == "rename" {
		warnings = append(warnings, fmt.Sprintf("rename operation will move %q to %q", op.Path, op.TargetPath))
	}

	return uniqueSorted(warnings), uniqueSorted(failures), uniqueSorted(affected), nil
}

func applyOperation(ctx context.Context, projectDir, normalizedType string, op *Operation) error {
	switch normalizedType {
	case "text_patch":
		return applyTextPatch(ctx, projectDir, op)
	case "scene_op":
		return applySceneOp(ctx, projectDir, op)
	case "resource_op":
		return applyResourceOp(ctx, projectDir, op)
	case "asset_import":
		return applyAssetImport(ctx, projectDir, op)
	case "project_setting":
		return applyProjectSetting(ctx, projectDir, op)
	default:
		return &Error{Op: "apply operation", Type: normalizedType, Path: op.Path, Err: fmt.Errorf("unsupported operation type %q", normalizedType)}
	}
}

func applyFileOperation(ctx context.Context, projectDir, normalizedType string, op *Operation, binary bool) error {
	if err := ctx.Err(); err != nil {
		return &Error{Op: "apply file operation", Type: normalizedType, Path: op.Path, Err: err}
	}
	projectDir, err := validateProjectDir(projectDir)
	if err != nil {
		return err
	}
	if op == nil {
		return &Error{Op: "apply file operation", Type: normalizedType, Err: errors.New("operation is nil")}
	}

	action, err := normalizeAction(projectDir, normalizedType, op)
	if err != nil {
		return &Error{Op: "apply file operation", Type: normalizedType, Path: op.Path, Err: err}
	}
	primary, err := resolveProjectPath(projectDir, op.Path)
	if err != nil {
		return &Error{Op: "apply file operation", Type: normalizedType, Path: op.Path, Err: err}
	}

	switch action {
	case "apply_patch":
		return bridgegit.ApplyPatch(ctx, projectDir, []byte(op.Content))
	case "create":
		if pathExists(primary) {
			return &Error{Op: "apply file operation", Type: normalizedType, Path: op.Path, Err: fmt.Errorf("path %q already exists", op.Path)}
		}
		payload, err := opContentBytes(op, binary)
		if err != nil {
			return &Error{Op: "apply file operation", Type: normalizedType, Path: op.Path, Err: err}
		}
		return writeFileAtomic(primary, payload, 0o644)
	case "write", "replace", "modify":
		payload, err := transformedContent(primary, op, binary)
		if err != nil {
			return &Error{Op: "apply file operation", Type: normalizedType, Path: op.Path, Err: err}
		}
		return writeFileAtomic(primary, payload, 0o644)
	case "append":
		payload, err := opContentBytes(op, binary)
		if err != nil {
			return &Error{Op: "apply file operation", Type: normalizedType, Path: op.Path, Err: err}
		}
		current, err := os.ReadFile(primary)
		if err != nil {
			return &Error{Op: "apply file operation", Type: normalizedType, Path: op.Path, Err: err}
		}
		return writeFileAtomic(primary, append(current, payload...), 0o644)
	case "delete":
		if err := os.Remove(primary); err != nil {
			return &Error{Op: "apply file operation", Type: normalizedType, Path: op.Path, Err: err}
		}
		return nil
	case "rename":
		target, err := resolveProjectPath(projectDir, op.TargetPath)
		if err != nil {
			return &Error{Op: "apply file operation", Type: normalizedType, Path: op.TargetPath, Err: err}
		}
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			return &Error{Op: "apply file operation", Type: normalizedType, Path: op.TargetPath, Err: err}
		}
		if err := os.Rename(primary, target); err != nil {
			return &Error{Op: "apply file operation", Type: normalizedType, Path: op.Path, Err: err}
		}
		return nil
	default:
		return &Error{Op: "apply file operation", Type: normalizedType, Path: op.Path, Err: fmt.Errorf("unsupported action %q", action)}
	}
}

func allowedTypes() map[string]struct{} {
	return map[string]struct{}{
		"text_patch":      {},
		"scene_op":        {},
		"resource_op":     {},
		"asset_import":    {},
		"project_setting": {},
	}
}

func allowedActions(normalizedType string) map[string]struct{} {
	switch normalizedType {
	case "project_setting":
		return map[string]struct{}{"set": {}, "remove": {}}
	case "asset_import":
		return map[string]struct{}{"create": {}, "write": {}, "modify": {}, "replace": {}, "delete": {}, "rename": {}, "append": {}}
	default:
		return map[string]struct{}{"create": {}, "write": {}, "modify": {}, "replace": {}, "append": {}, "delete": {}, "rename": {}, "apply_patch": {}}
	}
}

func normalizeType(value string) string {
	value = strings.ToLower(strings.TrimSpace(value))
	switch value {
	case "project_setting_set", "project_setting":
		return "project_setting"
	default:
		return value
	}
}

func normalizeAction(projectDir, normalizedType string, op *Operation) (string, error) {
	action := strings.ToLower(strings.TrimSpace(op.Action))
	switch action {
	case "remove":
		action = "delete"
	case "move":
		action = "rename"
	case "update":
		action = "modify"
	}

	if action != "" {
		if normalizedType == "project_setting" && action == "delete" {
			return "remove", nil
		}
		return action, nil
	}

	if normalizedType == "project_setting" {
		return "set", nil
	}
	if strings.TrimSpace(op.TargetPath) != "" {
		return "rename", nil
	}
	if strings.TrimSpace(op.Content) == "" && !hasFindReplace(op) {
		return "delete", nil
	}

	primary, err := resolveProjectPath(projectDir, op.Path)
	if err != nil {
		return "", err
	}
	if pathExists(primary) {
		return "modify", nil
	}
	return "create", nil
}

func operationPaths(projectDir, normalizedType, action string, op *Operation) (string, string, string, error) {
	if normalizedType == "project_setting" {
		projectFile := filepath.Join(projectDir, "project.godot")
		return projectFile, projectFile, "project.godot", nil
	}

	primary, err := resolveProjectPath(projectDir, op.Path)
	if err != nil {
		return "", "", "", err
	}
	displayPath := journalPath(projectDir, primary)
	switch action {
	case "rename":
		target, err := resolveProjectPath(projectDir, op.TargetPath)
		if err != nil {
			return "", "", displayPath, err
		}
		return primary, target, journalPath(projectDir, target), nil
	case "delete":
		return primary, primary, displayPath, nil
	default:
		return primary, primary, displayPath, nil
	}
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

func resolveProjectPath(projectDir, value string) (string, error) {
	value = strings.TrimSpace(value)
	value = strings.TrimPrefix(value, "res://")
	value = filepath.Clean(value)
	if value == "" || value == "." || value == string(filepath.Separator) {
		return "", errors.New("operation path is required")
	}

	var abs string
	if filepath.IsAbs(value) {
		abs = filepath.Clean(value)
	} else {
		abs = filepath.Join(projectDir, value)
	}

	rel, err := filepath.Rel(projectDir, abs)
	if err != nil {
		return "", err
	}
	if rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return "", fmt.Errorf("path %q escapes project directory", value)
	}

	return abs, nil
}

func validateExtension(path, target string, allowed map[string]struct{}) error {
	for _, candidate := range []string{path, target} {
		candidate = strings.TrimSpace(candidate)
		if candidate == "" {
			continue
		}
		ext := strings.ToLower(filepath.Ext(strings.TrimPrefix(candidate, "res://")))
		if _, ok := allowed[ext]; !ok {
			return fmt.Errorf("path %q uses unsupported extension %q", candidate, ext)
		}
	}
	return nil
}

func checkWritableForAction(primary, target, action string) error {
	switch action {
	case "create":
		return checkWritablePath(primary, false)
	case "rename":
		if err := checkWritablePath(primary, true); err != nil {
			return err
		}
		return checkWritablePath(target, false)
	case "delete", "modify", "replace", "write", "append":
		return checkWritablePath(primary, action != "write")
	case "set", "remove":
		return checkWritablePath(primary, true)
	case "apply_patch":
		return nil
	default:
		return nil
	}
}

func checkWritablePath(path string, mustExist bool) error {
	info, err := os.Stat(path)
	if err == nil {
		if info.IsDir() {
			return fmt.Errorf("path %q is a directory", path)
		}
		if info.Mode().Perm()&0o222 == 0 {
			return fmt.Errorf("path %q is read-only", path)
		}
		return nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if mustExist {
		return fmt.Errorf("path %q does not exist", path)
	}

	parent := filepath.Dir(path)
	parentInfo, err := os.Stat(parent)
	if err != nil {
		return err
	}
	if !parentInfo.IsDir() {
		return fmt.Errorf("parent path %q is not a directory", parent)
	}
	if parentInfo.Mode().Perm()&0o222 == 0 {
		return fmt.Errorf("parent directory %q is read-only", parent)
	}
	return nil
}

func opContentBytes(op *Operation, binary bool) ([]byte, error) {
	if op == nil {
		return nil, errors.New("operation is nil")
	}
	encoding, _ := stringParam(op.Params, "encoding")
	if binary && strings.EqualFold(strings.TrimSpace(encoding), "base64") {
		decoded, err := base64.StdEncoding.DecodeString(strings.TrimSpace(op.Content))
		if err != nil {
			return nil, fmt.Errorf("decode base64 content: %w", err)
		}
		return decoded, nil
	}
	return []byte(op.Content), nil
}

func transformedContent(path string, op *Operation, binary bool) ([]byte, error) {
	if binary {
		return opContentBytes(op, true)
	}

	findValue, hasFind := stringParam(op.Params, "find")
	replaceValue, hasReplace := stringParam(op.Params, "replace")
	if hasFind && hasReplace {
		current, err := os.ReadFile(path)
		if err != nil {
			return nil, err
		}
		text := string(current)
		if !strings.Contains(text, findValue) {
			return nil, fmt.Errorf("pattern %q not found in %q", findValue, path)
		}
		replaceAll, _ := boolParam(op.Params, "replace_all")
		count := 1
		if replaceAll {
			count = -1
		}
		return []byte(strings.Replace(text, findValue, replaceValue, count)), nil
	}

	if strings.TrimSpace(op.Content) == "" {
		return nil, errors.New("content is required")
	}
	return []byte(op.Content), nil
}

func writeFileAtomic(path string, data []byte, fallbackMode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}

	mode := fallbackMode
	if info, err := os.Stat(path); err == nil {
		mode = info.Mode().Perm()
	}
	if mode == 0 {
		mode = 0o644
	}

	tmp, err := os.CreateTemp(filepath.Dir(path), ".patch-*.tmp")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()

	cleanup := func(cause error) error {
		_ = tmp.Close()
		_ = os.Remove(tmpPath)
		return cause
	}

	if _, err := tmp.Write(data); err != nil {
		return cleanup(err)
	}
	if err := tmp.Chmod(mode); err != nil {
		return cleanup(err)
	}
	if err := tmp.Sync(); err != nil {
		return cleanup(err)
	}
	if err := tmp.Close(); err != nil {
		return cleanup(err)
	}
	if err := os.Rename(tmpPath, path); err != nil {
		return cleanup(err)
	}

	dir, err := os.Open(filepath.Dir(path))
	if err == nil {
		_ = dir.Sync()
		_ = dir.Close()
	}

	return nil
}

func projectSettingValue(op *Operation) (string, error) {
	if op == nil {
		return "", errors.New("operation is nil")
	}
	if value, ok := op.Params["value"]; ok {
		return formatGodotValue(value), nil
	}
	content := strings.TrimSpace(op.Content)
	if content == "" {
		return "", errors.New("setting value is required")
	}
	return content, nil
}

func formatGodotValue(value any) string {
	switch typed := value.(type) {
	case nil:
		return "null"
	case string:
		return strconv.Quote(typed)
	case bool:
		if typed {
			return "true"
		}
		return "false"
	case json.Number:
		return typed.String()
	case float64:
		if math.Trunc(typed) == typed {
			return strconv.FormatInt(int64(typed), 10)
		}
		return strconv.FormatFloat(typed, 'f', -1, 64)
	case float32:
		f := float64(typed)
		if math.Trunc(f) == f {
			return strconv.FormatInt(int64(f), 10)
		}
		return strconv.FormatFloat(f, 'f', -1, 32)
	case int, int8, int16, int32, int64:
		return fmt.Sprintf("%d", typed)
	case uint, uint8, uint16, uint32, uint64:
		return fmt.Sprintf("%d", typed)
	default:
		payload, err := json.Marshal(typed)
		if err != nil {
			return strconv.Quote(fmt.Sprint(typed))
		}
		return string(payload)
	}
}

func settingIdentifier(op *Operation) string {
	if op == nil {
		return ""
	}
	if value := strings.TrimSpace(op.Path); value != "" {
		return strings.Trim(value, "/")
	}
	if value, ok := stringParam(op.Params, "setting"); ok {
		return strings.Trim(value, "/")
	}
	if value, ok := stringParam(op.Params, "property"); ok {
		return strings.Trim(value, "/")
	}
	return ""
}

func splitProjectSetting(path string) (string, string, error) {
	path = strings.Trim(strings.TrimSpace(path), "/")
	if path == "" {
		return "", "", errors.New("project setting path is required")
	}
	section, key, ok := strings.Cut(path, "/")
	if !ok || strings.TrimSpace(section) == "" || strings.TrimSpace(key) == "" {
		return "", "", fmt.Errorf("project setting path %q must look like section/key", path)
	}
	return section, key, nil
}

func findSectionBounds(lines []string, header string) (int, int) {
	start := -1
	end := len(lines)
	for idx, line := range lines {
		trimmed := strings.TrimSpace(line)
		if trimmed == header {
			start = idx
			continue
		}
		if start != -1 && strings.HasPrefix(trimmed, "[") && strings.HasSuffix(trimmed, "]") {
			end = idx
			break
		}
	}
	return start, end
}

func trimTrailingBlankLines(lines []string) []string {
	end := len(lines)
	for end > 0 && strings.TrimSpace(lines[end-1]) == "" {
		end--
	}
	return append([]string(nil), lines[:end]...)
}

func normalizeNewlines(value string) string {
	value = strings.ReplaceAll(value, "\r\n", "\n")
	value = strings.ReplaceAll(value, "\r", "\n")
	return value
}

func journalPath(projectDir, path string) string {
	rel, err := filepath.Rel(projectDir, path)
	if err != nil {
		return filepath.ToSlash(filepath.Clean(path))
	}
	return filepath.ToSlash(rel)
}

func fileHashOrMissing(path string) (string, error) {
	if !pathExists(path) {
		return missingHash, nil
	}
	return computeFileHash(path)
}

func pathExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func cloneParams(params map[string]any) map[string]any {
	if len(params) == 0 {
		return map[string]any{}
	}
	clone := make(map[string]any, len(params))
	for key, value := range params {
		clone[key] = value
	}
	return clone
}

func stringParam(params map[string]any, key string) (string, bool) {
	if len(params) == 0 {
		return "", false
	}
	value, ok := params[key]
	if !ok || value == nil {
		return "", false
	}
	text, ok := value.(string)
	if !ok {
		return "", false
	}
	return text, true
}

func boolParam(params map[string]any, key string) (bool, bool) {
	if len(params) == 0 {
		return false, false
	}
	value, ok := params[key]
	if !ok || value == nil {
		return false, false
	}
	b, ok := value.(bool)
	return b, ok
}

func hasFindReplace(op *Operation) bool {
	if op == nil {
		return false
	}
	_, hasFind := stringParam(op.Params, "find")
	_, hasReplace := stringParam(op.Params, "replace")
	return hasFind && hasReplace
}

func coalesce(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}

func uniqueSorted(values []string) []string {
	if len(values) == 0 {
		return nil
	}
	seen := make(map[string]struct{}, len(values))
	result := make([]string, 0, len(values))
	for _, value := range values {
		value = strings.TrimSpace(value)
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
