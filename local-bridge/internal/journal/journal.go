package journal

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

const (
	journalFileName   = "journal.json"
	statusInProgress  = "in_progress"
	statusCompleted   = "completed"
	statusFailed      = "failed"
	statusRolledBack  = "rolled_back"
	journalFileFormat = 1
)

// OperationEntry describes a single filesystem or workspace operation.
type OperationEntry struct {
	Type        string `json:"type"`
	Path        string `json:"path"`
	Description string `json:"description"`
	Reversible  bool   `json:"reversible"`
}

// ChangeSetEntry records the state of one change set execution.
type ChangeSetEntry struct {
	ID           string            `json:"id"`
	WorkItemID   string            `json:"work_item_id"`
	TaskRunID    string            `json:"task_run_id"`
	Timestamp    string            `json:"timestamp"`
	Operations   []OperationEntry  `json:"operations"`
	Preimages    map[string]string `json:"preimages"`
	Postimages   map[string]string `json:"postimages"`
	Status       string            `json:"status"`
	ErrorMessage string            `json:"error_message,omitempty"`
}

// Journal persists change sets to a local JSON file.
type Journal struct {
	path   string
	logger *slog.Logger

	mu      sync.Mutex
	entries map[string]*ChangeSetEntry
}

type journalFile struct {
	Version int               `json:"version"`
	Entries []*ChangeSetEntry `json:"entries"`
}

// NewJournal opens or creates a journal in dir.
func NewJournal(dir string, logger *slog.Logger) (*Journal, error) {
	if strings.TrimSpace(dir) == "" {
		return nil, errors.New("journal directory is required")
	}
	if logger == nil {
		logger = slog.Default()
	}

	dir = filepath.Clean(dir)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, fmt.Errorf("create journal directory %q: %w", dir, err)
	}

	j := &Journal{
		path:    filepath.Join(dir, journalFileName),
		logger:  logger,
		entries: make(map[string]*ChangeSetEntry),
	}

	if err := j.load(); err != nil {
		return nil, err
	}

	if _, err := os.Stat(j.path); errors.Is(err, os.ErrNotExist) {
		j.mu.Lock()
		persistErr := j.persistLocked()
		j.mu.Unlock()
		if persistErr != nil {
			return nil, persistErr
		}
	} else if err != nil {
		return nil, fmt.Errorf("stat journal file %q: %w", j.path, err)
	}

	return j, nil
}

// Begin creates a new in-progress change set.
func (j *Journal) Begin(workItemID, taskRunID string) (*ChangeSetEntry, error) {
	entryID, err := newID(16)
	if err != nil {
		return nil, fmt.Errorf("begin journal entry: %w", err)
	}

	entry := &ChangeSetEntry{
		ID:         entryID,
		WorkItemID: strings.TrimSpace(workItemID),
		TaskRunID:  strings.TrimSpace(taskRunID),
		Timestamp:  time.Now().UTC().Format(time.RFC3339Nano),
		Operations: make([]OperationEntry, 0),
		Preimages:  make(map[string]string),
		Postimages: make(map[string]string),
		Status:     statusInProgress,
	}

	j.mu.Lock()
	defer j.mu.Unlock()

	j.entries[entry.ID] = entry
	if err := j.persistLocked(); err != nil {
		delete(j.entries, entry.ID)
		return nil, err
	}

	return cloneEntry(entry), nil
}

// AddOperation appends an operation to an existing change set.
func (j *Journal) AddOperation(id string, op OperationEntry) error {
	if strings.TrimSpace(op.Type) == "" {
		return errors.New("operation type is required")
	}
	if strings.TrimSpace(op.Path) == "" {
		return errors.New("operation path is required")
	}

	j.mu.Lock()
	defer j.mu.Unlock()

	entry, err := j.requireEntryLocked(id)
	if err != nil {
		return err
	}
	entry.Operations = append(entry.Operations, op)
	return j.persistLocked()
}

// SetPreimage records the content hash observed before a change.
func (j *Journal) SetPreimage(id, path, hash string) error {
	return j.setImage(id, path, hash, true)
}

// SetPostimage records the content hash observed after a change.
func (j *Journal) SetPostimage(id, path, hash string) error {
	return j.setImage(id, path, hash, false)
}

// Complete marks a change set as completed.
func (j *Journal) Complete(id string) error {
	j.mu.Lock()
	defer j.mu.Unlock()

	entry, err := j.requireEntryLocked(id)
	if err != nil {
		return err
	}
	entry.Status = statusCompleted
	entry.ErrorMessage = ""
	return j.persistLocked()
}

// MarkFailed marks a change set as failed and stores an error message.
func (j *Journal) MarkFailed(id, errMsg string) error {
	j.mu.Lock()
	defer j.mu.Unlock()

	entry, err := j.requireEntryLocked(id)
	if err != nil {
		return err
	}
	entry.Status = statusFailed
	entry.ErrorMessage = strings.TrimSpace(errMsg)
	return j.persistLocked()
}

// MarkRolledBack marks a change set as rolled back.
func (j *Journal) MarkRolledBack(id string) error {
	j.mu.Lock()
	defer j.mu.Unlock()

	entry, err := j.requireEntryLocked(id)
	if err != nil {
		return err
	}
	entry.Status = statusRolledBack
	entry.ErrorMessage = ""
	return j.persistLocked()
}

// GetPending returns all unresolved change sets.
func (j *Journal) GetPending() ([]*ChangeSetEntry, error) {
	j.mu.Lock()
	defer j.mu.Unlock()

	entries := make([]*ChangeSetEntry, 0)
	for _, entry := range j.entries {
		if entry.Status != statusCompleted && entry.Status != statusRolledBack {
			entries = append(entries, cloneEntry(entry))
		}
	}
	sortEntries(entries)
	return entries, nil
}

// GetByID returns the change set with the provided ID.
func (j *Journal) GetByID(id string) (*ChangeSetEntry, error) {
	j.mu.Lock()
	defer j.mu.Unlock()

	entry, err := j.requireEntryLocked(id)
	if err != nil {
		return nil, err
	}
	return cloneEntry(entry), nil
}

// ListAll returns every change set sorted by timestamp.
func (j *Journal) ListAll() ([]*ChangeSetEntry, error) {
	j.mu.Lock()
	defer j.mu.Unlock()

	entries := make([]*ChangeSetEntry, 0, len(j.entries))
	for _, entry := range j.entries {
		entries = append(entries, cloneEntry(entry))
	}
	sortEntries(entries)
	return entries, nil
}

func (j *Journal) load() error {
	data, err := os.ReadFile(j.path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return fmt.Errorf("read journal file %q: %w", j.path, err)
	}
	if len(strings.TrimSpace(string(data))) == 0 {
		return nil
	}

	var persisted journalFile
	if err := json.Unmarshal(data, &persisted); err != nil {
		return fmt.Errorf("parse journal file %q: %w", j.path, err)
	}
	if persisted.Version != 0 && persisted.Version != journalFileFormat {
		return fmt.Errorf("unsupported journal file version %d", persisted.Version)
	}

	for _, entry := range persisted.Entries {
		if entry == nil || strings.TrimSpace(entry.ID) == "" {
			continue
		}
		if entry.Preimages == nil {
			entry.Preimages = make(map[string]string)
		}
		if entry.Postimages == nil {
			entry.Postimages = make(map[string]string)
		}
		j.entries[entry.ID] = cloneEntry(entry)
	}

	return nil
}

func (j *Journal) setImage(id, path, hash string, preimage bool) error {
	path = filepath.Clean(strings.TrimSpace(path))
	hash = strings.TrimSpace(hash)
	if path == "" || path == "." {
		return errors.New("image path is required")
	}
	if hash == "" {
		return errors.New("image hash is required")
	}

	j.mu.Lock()
	defer j.mu.Unlock()

	entry, err := j.requireEntryLocked(id)
	if err != nil {
		return err
	}
	if preimage {
		entry.Preimages[path] = hash
	} else {
		entry.Postimages[path] = hash
	}
	return j.persistLocked()
}

func (j *Journal) requireEntryLocked(id string) (*ChangeSetEntry, error) {
	id = strings.TrimSpace(id)
	if id == "" {
		return nil, errors.New("entry ID is required")
	}
	entry, ok := j.entries[id]
	if !ok {
		return nil, fmt.Errorf("journal entry %q not found", id)
	}
	return entry, nil
}

func (j *Journal) persistLocked() error {
	entries := make([]*ChangeSetEntry, 0, len(j.entries))
	for _, entry := range j.entries {
		entries = append(entries, cloneEntry(entry))
	}
	sortEntries(entries)

	persisted := journalFile{
		Version: journalFileFormat,
		Entries: entries,
	}

	payload, err := json.MarshalIndent(persisted, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal journal file: %w", err)
	}
	payload = append(payload, '\n')

	tmpFile, err := os.CreateTemp(filepath.Dir(j.path), "journal-*.tmp")
	if err != nil {
		return fmt.Errorf("create journal temp file: %w", err)
	}
	tmpPath := tmpFile.Name()

	cleanup := func(cause error) error {
		_ = tmpFile.Close()
		_ = os.Remove(tmpPath)
		return cause
	}

	if _, err := tmpFile.Write(payload); err != nil {
		return cleanup(fmt.Errorf("write journal temp file: %w", err))
	}
	if err := tmpFile.Sync(); err != nil {
		return cleanup(fmt.Errorf("sync journal temp file: %w", err))
	}
	if err := tmpFile.Close(); err != nil {
		return cleanup(fmt.Errorf("close journal temp file: %w", err))
	}
	if err := os.Rename(tmpPath, j.path); err != nil {
		return cleanup(fmt.Errorf("replace journal file: %w", err))
	}

	dir, err := os.Open(filepath.Dir(j.path))
	if err == nil {
		if syncErr := dir.Sync(); syncErr != nil {
			j.logger.Warn("failed to sync journal directory", "dir", filepath.Dir(j.path), "error", syncErr)
		}
		_ = dir.Close()
	} else {
		j.logger.Warn("failed to open journal directory for sync", "dir", filepath.Dir(j.path), "error", err)
	}

	return nil
}

func cloneEntry(entry *ChangeSetEntry) *ChangeSetEntry {
	if entry == nil {
		return nil
	}

	cloned := *entry
	cloned.Operations = append([]OperationEntry(nil), entry.Operations...)
	cloned.Preimages = cloneMap(entry.Preimages)
	cloned.Postimages = cloneMap(entry.Postimages)
	return &cloned
}

func cloneMap(values map[string]string) map[string]string {
	if values == nil {
		return map[string]string{}
	}
	cloned := make(map[string]string, len(values))
	for key, value := range values {
		cloned[key] = value
	}
	return cloned
}

func sortEntries(entries []*ChangeSetEntry) {
	sort.Slice(entries, func(i, j int) bool {
		if entries[i].Timestamp == entries[j].Timestamp {
			return entries[i].ID < entries[j].ID
		}
		return entries[i].Timestamp < entries[j].Timestamp
	})
}

func newID(size int) (string, error) {
	buf := make([]byte, size)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return hex.EncodeToString(buf), nil
}
