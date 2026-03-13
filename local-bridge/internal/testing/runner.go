package testing

import (
	"bytes"
	"context"
	"encoding/json"
	"encoding/xml"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

const defaultTestTimeout = 2 * time.Minute

var packageLogger = slog.Default()

// Strategy defines a test plan that the bridge can execute locally.
type Strategy struct {
	ID          string `json:"id"`
	Kind        string `json:"kind"`
	Framework   string `json:"framework,omitempty"`
	Profile     string `json:"profile,omitempty"`
	Description string `json:"description,omitempty"`
}

// TestCase describes a single discovered test or runtime probe.
type TestCase struct {
	Name     string        `json:"name"`
	Suite    string        `json:"suite,omitempty"`
	Passed   bool          `json:"passed"`
	Duration time.Duration `json:"duration,omitempty"`
	Output   string        `json:"output,omitempty"`
	Error    string        `json:"error,omitempty"`
}

// RunResult captures the outcome of a test strategy run.
type RunResult struct {
	StrategyID string        `json:"strategy_id"`
	Passed     bool          `json:"passed"`
	Total      int           `json:"total"`
	Failed     int           `json:"failed"`
	Skipped    int           `json:"skipped"`
	Duration   time.Duration `json:"duration"`
	Cases      []TestCase    `json:"cases,omitempty"`
	Error      string        `json:"error,omitempty"`
}

// Error captures structured test loading and execution failures.
type Error struct {
	Op         string
	StrategyID string
	Err        error
	Output     string
}

func (e *Error) Error() string {
	if e == nil {
		return "testing: <nil>"
	}

	var parts []string
	if strings.TrimSpace(e.Op) != "" {
		parts = append(parts, e.Op)
	}
	if strings.TrimSpace(e.StrategyID) != "" {
		parts = append(parts, fmt.Sprintf("strategy=%q", e.StrategyID))
	}
	if strings.TrimSpace(e.Output) != "" {
		parts = append(parts, fmt.Sprintf("output=%q", truncate(e.Output, 240)))
	}
	if e.Err != nil {
		parts = append(parts, e.Err.Error())
	}

	return "testing: " + strings.Join(parts, ": ")
}

func (e *Error) Unwrap() error {
	if e == nil {
		return nil
	}
	return e.Err
}

// LoadStrategies loads a small YAML strategy list from .echothink/test_strategies.yaml.
func LoadStrategies(projectDir string) ([]Strategy, error) {
	projectDir, err := validateProjectDir(projectDir)
	if err != nil {
		return nil, err
	}

	path := filepath.Join(projectDir, ".echothink", "test_strategies.yaml")
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, &Error{Op: "load strategies", Err: fmt.Errorf("read %q: %w", path, err)}
	}
	data = bytes.TrimSpace(data)
	if len(data) == 0 {
		return nil, &Error{Op: "load strategies", Err: fmt.Errorf("strategy file %q is empty", path)}
	}

	var strategies []Strategy
	if data[0] == '{' || data[0] == '[' {
		strategies, err = parseStrategiesJSON(data)
	} else {
		strategies, err = parseStrategiesYAML(string(data))
	}
	if err != nil {
		return nil, &Error{Op: "load strategies", Err: err}
	}

	packageLogger.Debug("loaded test strategies", "project_dir", projectDir, "count", len(strategies))
	return strategies, nil
}

// RunStrategy routes execution to the configured runner for strategy.Kind.
func RunStrategy(ctx context.Context, projectDir string, strategy *Strategy) (*RunResult, error) {
	projectDir, err := validateProjectDir(projectDir)
	if err != nil {
		return nil, err
	}
	if ctx == nil {
		return nil, &Error{Op: "run strategy", Err: errors.New("context is nil")}
	}
	if err := validateStrategy(strategy); err != nil {
		return nil, err
	}

	kind := normalizeKind(strategy)
	switch kind {
	case "headless":
		return runHeadless(ctx, projectDir, strategy)
	case "gut":
		return runGUT(ctx, projectDir, strategy)
	default:
		return nil, &Error{Op: "run strategy", StrategyID: strategy.ID, Err: fmt.Errorf("unsupported strategy kind %q", strategy.Kind)}
	}
}

// runHeadless executes a short Godot headless smoke run.
func runHeadless(ctx context.Context, projectDir string, strategy *Strategy) (*RunResult, error) {
	if err := validateStrategy(strategy); err != nil {
		return nil, err
	}
	smokeScript, err := findSmokeScript(projectDir, strategy)
	if err != nil {
		return nil, &Error{Op: "run headless", StrategyID: strategy.ID, Err: err}
	}

	bin, err := findGodotBinary()
	if err != nil {
		return nil, &Error{Op: "run headless", StrategyID: strategy.ID, Err: err}
	}

	output, duration, runErr := runCommand(ctx, projectDir, bin, "--headless", "--quit-after", "10", "--script", smokeScript)
	cases := parseGodotOutput(output)
	if len(cases) == 0 {
		cases = []TestCase{{
			Name:     filepath.Base(smokeScript),
			Suite:    strategy.ID,
			Passed:   runErr == nil && !containsErrorIndicators(output),
			Duration: duration,
			Output:   output,
		}}
	}

	for idx := range cases {
		if cases[idx].Suite == "" {
			cases[idx].Suite = strategy.ID
		}
		if cases[idx].Duration == 0 {
			cases[idx].Duration = duration
		}
	}

	result := buildRunResult(strategy.ID, duration, cases)
	if runErr != nil {
		result.Passed = false
		result.Error = runErr.Error()
		return result, &Error{Op: "run headless", StrategyID: strategy.ID, Err: runErr, Output: output}
	}
	if containsErrorIndicators(output) {
		result.Passed = false
		result.Error = "Godot output reported errors"
	}

	return result, nil
}

// runGUT executes the GUT command-line runner and parses JUnit or text output.
func runGUT(ctx context.Context, projectDir string, strategy *Strategy) (*RunResult, error) {
	if err := validateStrategy(strategy); err != nil {
		return nil, err
	}

	gutScript := filepath.Join(projectDir, "addons", "gut", "gut_cmdln.gd")
	if _, err := os.Stat(gutScript); err != nil {
		return nil, &Error{Op: "run GUT", StrategyID: strategy.ID, Err: fmt.Errorf("missing GUT runner %q: %w", gutScript, err)}
	}

	bin, err := findGodotBinary()
	if err != nil {
		return nil, &Error{Op: "run GUT", StrategyID: strategy.ID, Err: err}
	}

	output, duration, runErr := runCommand(ctx, projectDir, bin, "--headless", "-s", filepath.ToSlash(filepath.Join("addons", "gut", "gut_cmdln.gd")))
	cases := parseGUTOutput(output)
	if len(cases) == 0 {
		cases = parseGodotOutput(output)
	}
	if len(cases) == 0 {
		cases = []TestCase{{
			Name:     strategy.ID,
			Suite:    "gut",
			Passed:   runErr == nil && !containsErrorIndicators(output),
			Duration: duration,
			Output:   output,
		}}
	}

	for idx := range cases {
		if cases[idx].Duration == 0 {
			cases[idx].Duration = duration
		}
	}

	result := buildRunResult(strategy.ID, duration, cases)
	if runErr != nil {
		result.Passed = false
		result.Error = runErr.Error()
		return result, &Error{Op: "run GUT", StrategyID: strategy.ID, Err: runErr, Output: output}
	}
	if containsErrorIndicators(output) {
		result.Passed = false
		if result.Error == "" {
			result.Error = "GUT reported errors"
		}
	}

	return result, nil
}

// parseGodotOutput extracts coarse test cases from headless or text runner output.
func parseGodotOutput(output string) []TestCase {
	passLine := regexp.MustCompile(`(?i)^\s*(?:\[)?pass(?:ed)?(?:\])?[:\s-]+(.+)$`)
	failLine := regexp.MustCompile(`(?i)^\s*(?:\[)?fail(?:ed)?(?:\])?[:\s-]+(.+)$`)
	skipLine := regexp.MustCompile(`(?i)^\s*(?:\[)?skip(?:ped)?(?:\])?[:\s-]+(.+)$`)
	inlineResult := regexp.MustCompile(`(?i)^\s*([A-Za-z0-9_./:-]+)\s+.*\b(PASS|FAIL|SKIP(?:PED)?)\b`)
	runtimeError := regexp.MustCompile(`(?i)^(?:script\s+)?error:\s*(.+)$`)

	var cases []TestCase
	currentSuite := ""
	for _, rawLine := range strings.Split(normalizeNewlines(output), "\n") {
		line := strings.TrimSpace(rawLine)
		if line == "" {
			continue
		}

		if strings.HasPrefix(line, "res://") || strings.HasSuffix(line, ".gd") || strings.HasSuffix(line, ".tscn") {
			currentSuite = line
		}

		if matches := passLine.FindStringSubmatch(line); len(matches) == 2 {
			cases = append(cases, TestCase{Name: strings.TrimSpace(matches[1]), Suite: currentSuite, Passed: true, Output: line})
			continue
		}
		if matches := failLine.FindStringSubmatch(line); len(matches) == 2 {
			cases = append(cases, TestCase{Name: strings.TrimSpace(matches[1]), Suite: currentSuite, Passed: false, Output: line, Error: line})
			continue
		}
		if matches := skipLine.FindStringSubmatch(line); len(matches) == 2 {
			cases = append(cases, TestCase{Name: strings.TrimSpace(matches[1]), Suite: currentSuite, Passed: true, Output: line, Error: "skipped"})
			continue
		}
		if matches := inlineResult.FindStringSubmatch(line); len(matches) == 3 {
			status := strings.ToUpper(matches[2])
			cases = append(cases, TestCase{
				Name:   strings.TrimSpace(matches[1]),
				Suite:  currentSuite,
				Passed: strings.HasPrefix(status, "PASS"),
				Output: line,
				Error:  inlineCaseError(status, line),
			})
			continue
		}
		if matches := runtimeError.FindStringSubmatch(line); len(matches) == 2 {
			cases = append(cases, TestCase{Name: "runtime_error", Suite: currentSuite, Passed: false, Output: line, Error: strings.TrimSpace(matches[1])})
			continue
		}
		if looksLikeGodotError(line) {
			cases = append(cases, TestCase{Name: "runtime_error", Suite: currentSuite, Passed: false, Output: line, Error: line})
		}
	}

	return mergeCases(cases)
}

type junitSuites struct {
	XMLName xml.Name    `xml:"testsuites"`
	Suites  []junitSuite `xml:"testsuite"`
}

type junitSuite struct {
	Name  string      `xml:"name,attr"`
	Cases []junitCase `xml:"testcase"`
}

type junitCase struct {
	Name      string        `xml:"name,attr"`
	ClassName string        `xml:"classname,attr"`
	Time      string        `xml:"time,attr"`
	Failure   *junitFailure `xml:"failure"`
	Skipped   *struct{}     `xml:"skipped"`
	SystemOut string        `xml:"system-out"`
	SystemErr string        `xml:"system-err"`
}

type junitFailure struct {
	Message string `xml:"message,attr"`
	Body    string `xml:",chardata"`
}

func parseGUTOutput(output string) []TestCase {
	trimmed := strings.TrimSpace(output)
	if trimmed == "" {
		return nil
	}

	if strings.Contains(trimmed, "<testsuite") || strings.Contains(trimmed, "<testsuites") {
		if cases := parseJUnitXML(trimmed); len(cases) > 0 {
			return cases
		}
	}

	return parseGodotOutput(output)
}

func parseJUnitXML(output string) []TestCase {
	var suites junitSuites
	if err := xml.Unmarshal([]byte(output), &suites); err == nil && len(suites.Suites) > 0 {
		return junitCases(suites.Suites)
	}

	var suite junitSuite
	if err := xml.Unmarshal([]byte(output), &suite); err == nil && len(suite.Cases) > 0 {
		return junitCases([]junitSuite{suite})
	}

	return nil
}

func junitCases(suites []junitSuite) []TestCase {
	var cases []TestCase
	for _, suite := range suites {
		for _, test := range suite.Cases {
			cases = append(cases, TestCase{
				Name:     strings.TrimSpace(test.Name),
				Suite:    firstNonEmpty(test.ClassName, suite.Name),
				Passed:   test.Failure == nil,
				Duration: parseSeconds(test.Time),
				Output:   firstNonEmpty(strings.TrimSpace(test.SystemOut), strings.TrimSpace(test.SystemErr)),
				Error:    junitError(test),
			})
		}
	}
	return mergeCases(cases)
}

func parseStrategiesJSON(data []byte) ([]Strategy, error) {
	var wrapper struct {
		Strategies []Strategy `json:"strategies"`
	}
	if err := json.Unmarshal(data, &wrapper); err == nil && len(wrapper.Strategies) > 0 {
		return validateStrategies(wrapper.Strategies)
	}

	var strategies []Strategy
	if err := json.Unmarshal(data, &strategies); err != nil {
		return nil, err
	}
	return validateStrategies(strategies)
}

func parseStrategiesYAML(data string) ([]Strategy, error) {
	lines := strings.Split(normalizeNewlines(data), "\n")
	strategies := make([]Strategy, 0)
	var current *Strategy
	insideList := false

	flushCurrent := func() error {
		if current == nil {
			return nil
		}
		strategies = append(strategies, *current)
		current = nil
		return nil
	}

	for lineNo, raw := range lines {
		line := stripInlineComment(strings.TrimRight(raw, "\r"))
		trimmed := strings.TrimSpace(line)
		if trimmed == "" {
			continue
		}

		if trimmed == "strategies:" {
			insideList = true
			continue
		}
		if !insideList && !strings.HasPrefix(trimmed, "-") {
			return nil, fmt.Errorf("line %d must start with \"strategies:\" or a list item", lineNo+1)
		}
		insideList = true

		if strings.HasPrefix(strings.TrimSpace(trimmed), "-") {
			if err := flushCurrent(); err != nil {
				return nil, err
			}
			current = &Strategy{}
			rest := strings.TrimSpace(strings.TrimPrefix(trimmed, "-"))
			if rest == "" {
				continue
			}
			if err := applyStrategyField(current, rest); err != nil {
				return nil, fmt.Errorf("line %d: %w", lineNo+1, err)
			}
			continue
		}

		if current == nil {
			return nil, fmt.Errorf("line %d is outside a strategy item", lineNo+1)
		}
		if err := applyStrategyField(current, trimmed); err != nil {
			return nil, fmt.Errorf("line %d: %w", lineNo+1, err)
		}
	}

	if err := flushCurrent(); err != nil {
		return nil, err
	}

	return validateStrategies(strategies)
}

func applyStrategyField(strategy *Strategy, line string) error {
	key, value, ok := strings.Cut(line, ":")
	if !ok {
		return fmt.Errorf("invalid field %q", line)
	}
	key = strings.ToLower(strings.TrimSpace(key))
	value = unquoteScalar(strings.TrimSpace(value))

	switch key {
	case "id":
		strategy.ID = value
	case "kind":
		strategy.Kind = value
	case "framework":
		strategy.Framework = value
	case "profile":
		strategy.Profile = value
	case "description":
		strategy.Description = value
	default:
		return fmt.Errorf("unknown strategy field %q", key)
	}
	return nil
}

func validateStrategies(strategies []Strategy) ([]Strategy, error) {
	if len(strategies) == 0 {
		return nil, errors.New("no strategies found")
	}
	seen := make(map[string]struct{}, len(strategies))
	for idx := range strategies {
		if err := validateStrategy(&strategies[idx]); err != nil {
			return nil, err
		}
		if _, ok := seen[strategies[idx].ID]; ok {
			return nil, fmt.Errorf("duplicate strategy ID %q", strategies[idx].ID)
		}
		seen[strategies[idx].ID] = struct{}{}
	}
	sort.Slice(strategies, func(i, j int) bool { return strategies[i].ID < strategies[j].ID })
	return strategies, nil
}

func validateStrategy(strategy *Strategy) error {
	if strategy == nil {
		return &Error{Op: "validate strategy", Err: errors.New("strategy is nil")}
	}
	strategy.ID = strings.TrimSpace(strategy.ID)
	strategy.Kind = strings.TrimSpace(strategy.Kind)
	strategy.Framework = strings.TrimSpace(strategy.Framework)
	strategy.Profile = strings.TrimSpace(strategy.Profile)
	strategy.Description = strings.TrimSpace(strategy.Description)

	if strategy.ID == "" {
		return &Error{Op: "validate strategy", Err: errors.New("strategy ID is required")}
	}
	if normalizeKind(strategy) == "" {
		return &Error{Op: "validate strategy", StrategyID: strategy.ID, Err: errors.New("strategy kind is required")}
	}
	return nil
}

func normalizeKind(strategy *Strategy) string {
	if strategy == nil {
		return ""
	}
	kind := strings.ToLower(strings.TrimSpace(strategy.Kind))
	framework := strings.ToLower(strings.TrimSpace(strategy.Framework))
	if kind == "" {
		kind = framework
	}
	if framework == "gut" || kind == "gut" {
		return "gut"
	}
	if kind == "headless" || framework == "godot" {
		return "headless"
	}
	return kind
}

func validateProjectDir(projectDir string) (string, error) {
	projectDir = filepath.Clean(strings.TrimSpace(projectDir))
	if projectDir == "" || projectDir == "." {
		return "", &Error{Op: "validate project dir", Err: errors.New("project directory is required")}
	}
	info, err := os.Stat(projectDir)
	if err != nil {
		return "", &Error{Op: "validate project dir", Err: err}
	}
	if !info.IsDir() {
		return "", &Error{Op: "validate project dir", Err: errors.New("project path is not a directory")}
	}
	return projectDir, nil
}

func findSmokeScript(projectDir string, strategy *Strategy) (string, error) {
	candidates := []string{}
	if strategy != nil {
		if strategy.Profile != "" {
			candidates = append(candidates,
				filepath.Join(projectDir, ".echothink", strategy.Profile+"_smoke.gd"),
				filepath.Join(projectDir, ".echothink", "smoke_"+strategy.Profile+".gd"),
			)
		}
		if strategy.ID != "" {
			candidates = append(candidates, filepath.Join(projectDir, ".echothink", strategy.ID+".gd"))
		}
	}
	candidates = append(candidates,
		filepath.Join(projectDir, ".echothink", "smoke_test.gd"),
		filepath.Join(projectDir, ".echothink", "smoke.gd"),
		filepath.Join(projectDir, "tests", "smoke.gd"),
	)

	for _, candidate := range candidates {
		if info, err := os.Stat(candidate); err == nil && !info.IsDir() {
			return candidate, nil
		}
	}

	return "", errors.New("no smoke script found in .echothink or tests")
}

func findGodotBinary() (string, error) {
	var candidates []string
	if env := strings.TrimSpace(os.Getenv("GODOT_BIN")); env != "" {
		candidates = append(candidates, env)
	}
	candidates = append(candidates, "godot", "godot4", "godot.exe")

	for _, candidate := range candidates {
		path, err := exec.LookPath(candidate)
		if err == nil {
			return path, nil
		}
	}

	return "", errors.New("godot executable not found in PATH")
}

func runCommand(ctx context.Context, projectDir, bin string, args ...string) (string, time.Duration, error) {
	cmdCtx, cancel := context.WithTimeout(ctx, defaultTestTimeout)
	defer cancel()

	start := time.Now()
	cmd := exec.CommandContext(cmdCtx, bin, args...)
	cmd.Dir = projectDir
	cmd.Env = os.Environ()
	output, err := cmd.CombinedOutput()
	duration := time.Since(start)

	text := normalizeNewlines(string(output))
	if err != nil {
		if cmdCtx.Err() != nil {
			return text, duration, cmdCtx.Err()
		}
		return text, duration, err
	}
	return text, duration, nil
}

func buildRunResult(strategyID string, duration time.Duration, cases []TestCase) *RunResult {
	result := &RunResult{
		StrategyID: strategyID,
		Duration:   duration,
		Cases:      append([]TestCase(nil), cases...),
		Passed:     true,
		Total:      len(cases),
	}
	for _, testCase := range cases {
		if isSkipped(testCase) {
			result.Skipped++
		}
		if !testCase.Passed {
			result.Failed++
			result.Passed = false
		}
	}
	return result
}

func isSkipped(testCase TestCase) bool {
	value := strings.ToLower(strings.TrimSpace(testCase.Error + " " + testCase.Output))
	return strings.Contains(value, "skip")
}

func mergeCases(cases []TestCase) []TestCase {
	if len(cases) == 0 {
		return nil
	}
	merged := make([]TestCase, 0, len(cases))
	seen := make(map[string]int, len(cases))
	for _, testCase := range cases {
		key := firstNonEmpty(testCase.Suite, "global") + "::" + firstNonEmpty(testCase.Name, "unnamed")
		if idx, ok := seen[key]; ok {
			merged[idx].Output = strings.TrimSpace(strings.TrimSpace(merged[idx].Output) + "\n" + strings.TrimSpace(testCase.Output))
			if !testCase.Passed {
				merged[idx].Passed = false
				merged[idx].Error = firstNonEmpty(testCase.Error, merged[idx].Error)
			}
			if testCase.Duration > merged[idx].Duration {
				merged[idx].Duration = testCase.Duration
			}
			continue
		}
		seen[key] = len(merged)
		merged = append(merged, testCase)
	}
	return merged
}

func parseSeconds(value string) time.Duration {
	if strings.TrimSpace(value) == "" {
		return 0
	}
	seconds, err := strconv.ParseFloat(strings.TrimSpace(value), 64)
	if err != nil {
		return 0
	}
	return time.Duration(seconds * float64(time.Second))
}

func junitError(test junitCase) string {
	if test.Skipped != nil {
		return "skipped"
	}
	if test.Failure == nil {
		return ""
	}
	return firstNonEmpty(strings.TrimSpace(test.Failure.Message), strings.TrimSpace(test.Failure.Body), strings.TrimSpace(test.SystemErr))
}

func inlineCaseError(status, line string) string {
	status = strings.ToUpper(status)
	if strings.HasPrefix(status, "PASS") {
		return ""
	}
	if strings.HasPrefix(status, "SKIP") {
		return "skipped"
	}
	return line
}

func looksLikeGodotError(line string) bool {
	lower := strings.ToLower(strings.TrimSpace(line))
	if strings.HasPrefix(lower, "error:") || strings.HasPrefix(lower, "script error:") {
		return true
	}
	if strings.HasPrefix(line, "E ") {
		return true
	}
	return strings.Contains(lower, "assertion failed")
}

func containsErrorIndicators(output string) bool {
	for _, line := range strings.Split(normalizeNewlines(output), "\n") {
		if looksLikeGodotError(strings.TrimSpace(line)) {
			return true
		}
	}
	return false
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return strings.TrimSpace(value)
		}
	}
	return ""
}

func stripInlineComment(line string) string {
	var singleQuoted bool
	var doubleQuoted bool
	for idx, r := range line {
		switch r {
		case '\'':
			if !doubleQuoted {
				singleQuoted = !singleQuoted
			}
		case '"':
			if !singleQuoted {
				doubleQuoted = !doubleQuoted
			}
		case '#':
			if !singleQuoted && !doubleQuoted {
				return strings.TrimSpace(line[:idx])
			}
		}
	}
	return line
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

func normalizeNewlines(value string) string {
	value = strings.ReplaceAll(value, "\r\n", "\n")
	value = strings.ReplaceAll(value, "\r", "\n")
	return value
}

func truncate(value string, limit int) string {
	if limit <= 0 || len(value) <= limit {
		return value
	}
	return value[:limit] + "..."
}
