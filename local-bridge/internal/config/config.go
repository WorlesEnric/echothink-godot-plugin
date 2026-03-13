package config

import (
	"bufio"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

const (
	defaultSocketPath      = "/tmp/echothink-bridge.sock"
	defaultLogLevel        = "info"
	defaultHealthPort      = 19821
	defaultMaxConcurrentOp = 4
)

// Config contains the runtime configuration for the local bridge daemon.
//
// The YAML loader intentionally supports a flat key/value document so the
// project can stay on the Go standard library until external dependencies are
// introduced.
type Config struct {
	SocketPath       string
	LogLevel         string
	GatewayURL       string
	GatewayToken     string
	ProjectDir       string
	WorkspaceID      string
	PolicyProfile    string
	HealthPort       int
	MaxConcurrentOps int
}

// Load reads a flat YAML configuration file from path.
//
// If path is empty, Load returns a configuration populated with built-in
// defaults. Supported keys are the snake_case form of the Config fields, such
// as socket_path and gateway_url.
func Load(path string) (*Config, error) {
	cfg := defaultConfig()
	if strings.TrimSpace(path) == "" {
		return cfg, nil
	}

	file, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open config file %q: %w", path, err)
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	lineNumber := 0
	for scanner.Scan() {
		lineNumber++
		line := stripInlineComment(strings.TrimSpace(scanner.Text()))
		if line == "" || line == "---" || line == "..." {
			continue
		}

		key, value, ok := strings.Cut(line, ":")
		if !ok {
			return nil, fmt.Errorf("parse config file %q: line %d is not a key/value mapping", path, lineNumber)
		}

		if err := applyKeyValue(cfg, strings.TrimSpace(key), strings.TrimSpace(value)); err != nil {
			return nil, fmt.Errorf("parse config file %q: line %d: %w", path, lineNumber, err)
		}
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("read config file %q: %w", path, err)
	}

	return cfg, nil
}

// LoadFromEnv reads configuration overrides from environment variables.
//
// Supported variables:
//   - ECHOTHINK_SOCKET_PATH
//   - ECHOTHINK_LOG_LEVEL
//   - ECHOTHINK_GATEWAY_URL
//   - ECHOTHINK_GATEWAY_TOKEN
//   - ECHOTHINK_PROJECT_DIR
//   - ECHOTHINK_WORKSPACE_ID
//   - ECHOTHINK_POLICY_PROFILE
//   - ECHOTHINK_HEALTH_PORT
//   - ECHOTHINK_MAX_CONCURRENT_OPS
//
// Integer parsing failures are surfaced by storing -1 so Validate can return a
// meaningful configuration error later.
func LoadFromEnv() *Config {
	cfg := &Config{}

	if value, ok := os.LookupEnv("ECHOTHINK_SOCKET_PATH"); ok {
		cfg.SocketPath = strings.TrimSpace(value)
	}
	if value, ok := os.LookupEnv("ECHOTHINK_LOG_LEVEL"); ok {
		cfg.LogLevel = strings.TrimSpace(value)
	}
	if value, ok := os.LookupEnv("ECHOTHINK_GATEWAY_URL"); ok {
		cfg.GatewayURL = strings.TrimSpace(value)
	}
	if value, ok := os.LookupEnv("ECHOTHINK_GATEWAY_TOKEN"); ok {
		cfg.GatewayToken = strings.TrimSpace(value)
	}
	if value, ok := os.LookupEnv("ECHOTHINK_PROJECT_DIR"); ok {
		cfg.ProjectDir = strings.TrimSpace(value)
	}
	if value, ok := os.LookupEnv("ECHOTHINK_WORKSPACE_ID"); ok {
		cfg.WorkspaceID = strings.TrimSpace(value)
	}
	if value, ok := os.LookupEnv("ECHOTHINK_POLICY_PROFILE"); ok {
		cfg.PolicyProfile = strings.TrimSpace(value)
	}
	if value, ok := os.LookupEnv("ECHOTHINK_HEALTH_PORT"); ok {
		cfg.HealthPort = parseEnvInt(value)
	}
	if value, ok := os.LookupEnv("ECHOTHINK_MAX_CONCURRENT_OPS"); ok {
		cfg.MaxConcurrentOps = parseEnvInt(value)
	}

	return cfg
}

// Validate normalizes and validates the configuration.
func (c *Config) Validate() error {
	if c == nil {
		return errors.New("config is nil")
	}

	var problems []string

	c.SocketPath = filepath.Clean(strings.TrimSpace(c.SocketPath))
	if c.SocketPath == "." || c.SocketPath == "" {
		problems = append(problems, "socket path is required")
	}

	c.LogLevel = strings.ToLower(strings.TrimSpace(c.LogLevel))
	switch c.LogLevel {
	case "debug", "info", "warn", "error":
	default:
		problems = append(problems, fmt.Sprintf("unsupported log level %q", c.LogLevel))
	}

	c.ProjectDir = filepath.Clean(strings.TrimSpace(c.ProjectDir))
	if c.ProjectDir == "." || c.ProjectDir == "" {
		problems = append(problems, "project directory is required")
	} else {
		info, err := os.Stat(c.ProjectDir)
		if err != nil {
			problems = append(problems, fmt.Sprintf("project directory %q is not accessible: %v", c.ProjectDir, err))
		} else if !info.IsDir() {
			problems = append(problems, fmt.Sprintf("project directory %q is not a directory", c.ProjectDir))
		}
	}

	if c.GatewayURL != "" {
		parsedURL, err := url.Parse(c.GatewayURL)
		if err != nil {
			problems = append(problems, fmt.Sprintf("gateway URL %q is invalid: %v", c.GatewayURL, err))
		} else if !parsedURL.IsAbs() {
			problems = append(problems, fmt.Sprintf("gateway URL %q must be absolute", c.GatewayURL))
		} else {
			scheme := strings.ToLower(parsedURL.Scheme)
			if scheme != "http" && scheme != "https" && scheme != "ws" && scheme != "wss" {
				problems = append(problems, fmt.Sprintf("gateway URL %q must use http, https, ws, or wss", c.GatewayURL))
			}
		}
	}

	if c.HealthPort <= 0 || c.HealthPort > 65535 {
		problems = append(problems, fmt.Sprintf("health port %d must be between 1 and 65535", c.HealthPort))
	}

	if c.MaxConcurrentOps <= 0 {
		problems = append(problems, fmt.Sprintf("max concurrent ops %d must be greater than zero", c.MaxConcurrentOps))
	}

	if len(problems) > 0 {
		return errors.New(strings.Join(problems, "; "))
	}

	return nil
}

func defaultConfig() *Config {
	return &Config{
		SocketPath:       defaultSocketPath,
		LogLevel:         defaultLogLevel,
		HealthPort:       defaultHealthPort,
		MaxConcurrentOps: defaultMaxConcurrentOp,
	}
}

func applyKeyValue(cfg *Config, key, value string) error {
	key = normalizeKey(key)
	value = unquoteYAMLScalar(value)

	switch key {
	case "socketpath":
		cfg.SocketPath = value
	case "loglevel":
		cfg.LogLevel = value
	case "gatewayurl":
		cfg.GatewayURL = value
	case "gatewaytoken":
		cfg.GatewayToken = value
	case "projectdir":
		cfg.ProjectDir = value
	case "workspaceid":
		cfg.WorkspaceID = value
	case "policyprofile":
		cfg.PolicyProfile = value
	case "healthport":
		parsed, err := strconv.Atoi(value)
		if err != nil {
			return fmt.Errorf("health_port must be an integer: %w", err)
		}
		cfg.HealthPort = parsed
	case "maxconcurrentops":
		parsed, err := strconv.Atoi(value)
		if err != nil {
			return fmt.Errorf("max_concurrent_ops must be an integer: %w", err)
		}
		cfg.MaxConcurrentOps = parsed
	default:
		return fmt.Errorf("unknown config key %q", key)
	}

	return nil
}

func normalizeKey(key string) string {
	replacer := strings.NewReplacer("_", "", "-", "", " ", "")
	return strings.ToLower(replacer.Replace(strings.TrimSpace(key)))
}

func unquoteYAMLScalar(value string) string {
	value = strings.TrimSpace(value)
	if len(value) >= 2 {
		if (value[0] == '\'' && value[len(value)-1] == '\'') || (value[0] == '"' && value[len(value)-1] == '"') {
			return value[1 : len(value)-1]
		}
	}
	return value
}

func stripInlineComment(line string) string {
	var (
		inSingleQuote bool
		inDoubleQuote bool
	)

	for i, r := range line {
		switch r {
		case '\'':
			if !inDoubleQuote {
				inSingleQuote = !inSingleQuote
			}
		case '"':
			if !inSingleQuote {
				inDoubleQuote = !inDoubleQuote
			}
		case '#':
			if !inSingleQuote && !inDoubleQuote {
				return strings.TrimSpace(line[:i])
			}
		}
	}

	return line
}

func parseEnvInt(value string) int {
	value = strings.TrimSpace(value)
	if value == "" {
		return -1
	}

	parsed, err := strconv.Atoi(value)
	if err != nil {
		return -1
	}

	return parsed
}
