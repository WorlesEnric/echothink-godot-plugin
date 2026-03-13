package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/echothink/godot-local-bridge/internal/config"
	"github.com/echothink/godot-local-bridge/internal/ipc"
	"github.com/echothink/godot-local-bridge/internal/session"
)

const shutdownTimeout = 10 * time.Second

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintf(os.Stderr, "echothink-bridge: %v\n", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	fs := flag.NewFlagSet("echothink-bridge", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)

	var (
		configPath string
		socketPath string
		logLevel   string
	)

	fs.StringVar(&configPath, "config", "", "Path to a YAML configuration file")
	fs.StringVar(&socketPath, "socket", "/tmp/echothink-bridge.sock", "Unix domain socket path")
	fs.StringVar(&logLevel, "log-level", "info", "Log level: debug, info, warn, error")

	if err := fs.Parse(args); err != nil {
		return err
	}

	explicitFlags := map[string]bool{}
	fs.Visit(func(f *flag.Flag) {
		explicitFlags[f.Name] = true
	})

	cfg, err := config.Load(configPath)
	if err != nil {
		return err
	}
	mergeConfig(cfg, config.LoadFromEnv())
	if explicitFlags["socket"] {
		cfg.SocketPath = socketPath
	}
	if explicitFlags["log-level"] {
		cfg.LogLevel = logLevel
	}

	if err := cfg.Validate(); err != nil {
		return fmt.Errorf("invalid configuration: %w", err)
	}

	logger, err := newLogger(cfg.LogLevel)
	if err != nil {
		return err
	}
	logger.Info("starting EchoThink local bridge", "socket_path", cfg.SocketPath, "health_port", cfg.HealthPort)

	componentCtx, cancel := context.WithCancel(context.Background())
	defer cancel()

	signalCtx, stopSignals := signalContext()
	defer stopSignals()

	sessionManager := session.NewSessionManager(cfg, logger.With("component", "session"))
	sessionInfo, err := sessionManager.Bootstrap()
	if err != nil {
		return err
	}

	ipcServer := ipc.NewServer(cfg.SocketPath, logger.With("component", "ipc"))
	ipcServer.SetNonceValidator(sessionManager.ValidateNonce)
	ipcServer.RegisterMethod("system.ping", func(params json.RawMessage) (interface{}, error) {
		return map[string]string{"status": "ok"}, nil
	})
	ipcServer.RegisterMethod("session.info", func(params json.RawMessage) (interface{}, error) {
		return sessionManager.GetSessionInfo(), nil
	})

	if err := ipcServer.Start(componentCtx); err != nil {
		return err
	}

	gatewayClient := newGatewayClient(cfg, logger.With("component", "gateway"))
	if err := gatewayClient.Start(componentCtx); err != nil {
		cancel()
		_ = ipcServer.Stop()
		return err
	}

	healthServer, healthListener, err := newHealthServer(cfg, logger, sessionManager, gatewayClient)
	if err != nil {
		cancel()
		_ = gatewayClient.Stop(context.Background())
		_ = ipcServer.Stop()
		return err
	}

	healthErrCh := make(chan error, 1)
	go func() {
		if serveErr := healthServer.Serve(healthListener); serveErr != nil && !errors.Is(serveErr, http.ErrServerClosed) {
			healthErrCh <- fmt.Errorf("health server failed: %w", serveErr)
		}
	}()

	logger.Info(
		"bridge services started",
		"session_id", sessionInfo.SessionID,
		"workspace_id", sessionInfo.WorkspaceID,
		"project_valid", sessionInfo.ProjectValid,
		"health_address", healthListener.Addr().String(),
	)

	var runErr error
	select {
	case <-signalCtx.Done():
		logger.Info("shutdown signal received")
	case err := <-ipcServer.Errors():
		runErr = err
		logger.Error("IPC server terminated unexpectedly", "error", err)
	case err := <-healthErrCh:
		runErr = err
		logger.Error("health server terminated unexpectedly", "error", err)
	}

	cancel()
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), shutdownTimeout)
	defer shutdownCancel()

	var shutdownErr error
	if err := healthServer.Shutdown(shutdownCtx); err != nil && !errors.Is(err, http.ErrServerClosed) {
		shutdownErr = errors.Join(shutdownErr, fmt.Errorf("shutdown health server: %w", err))
	}
	if err := gatewayClient.Stop(shutdownCtx); err != nil {
		shutdownErr = errors.Join(shutdownErr, fmt.Errorf("shutdown gateway client: %w", err))
	}
	if err := ipcServer.Stop(); err != nil {
		shutdownErr = errors.Join(shutdownErr, fmt.Errorf("shutdown IPC server: %w", err))
	}

	if runErr != nil || shutdownErr != nil {
		return errors.Join(runErr, shutdownErr)
	}

	logger.Info("EchoThink local bridge stopped")
	return nil
}

func mergeConfig(dst, src *config.Config) {
	if dst == nil || src == nil {
		return
	}

	if src.SocketPath != "" {
		dst.SocketPath = src.SocketPath
	}
	if src.LogLevel != "" {
		dst.LogLevel = src.LogLevel
	}
	if src.GatewayURL != "" {
		dst.GatewayURL = src.GatewayURL
	}
	if src.GatewayToken != "" {
		dst.GatewayToken = src.GatewayToken
	}
	if src.ProjectDir != "" {
		dst.ProjectDir = src.ProjectDir
	}
	if src.WorkspaceID != "" {
		dst.WorkspaceID = src.WorkspaceID
	}
	if src.PolicyProfile != "" {
		dst.PolicyProfile = src.PolicyProfile
	}
	if src.HealthPort != 0 {
		dst.HealthPort = src.HealthPort
	}
	if src.MaxConcurrentOps != 0 {
		dst.MaxConcurrentOps = src.MaxConcurrentOps
	}
}

func newLogger(levelName string) (*slog.Logger, error) {
	level, err := parseLogLevel(levelName)
	if err != nil {
		return nil, err
	}

	handler := slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: level})
	return slog.New(handler), nil
}

func parseLogLevel(levelName string) (slog.Level, error) {
	switch strings.ToLower(strings.TrimSpace(levelName)) {
	case "debug":
		return slog.LevelDebug, nil
	case "info":
		return slog.LevelInfo, nil
	case "warn", "warning":
		return slog.LevelWarn, nil
	case "error":
		return slog.LevelError, nil
	default:
		return 0, fmt.Errorf("unsupported log level %q", levelName)
	}
}

func signalContext() (context.Context, context.CancelFunc) {
	return signalNotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
}

var signalNotifyContext = func(parent context.Context, signals ...os.Signal) (context.Context, context.CancelFunc) {
	return signal.NotifyContext(parent, signals...)
}

type gatewayClient struct {
	config  *config.Config
	logger  *slog.Logger
	mu      sync.Mutex
	started bool
}

func newGatewayClient(cfg *config.Config, logger *slog.Logger) *gatewayClient {
	if logger == nil {
		logger = slog.Default()
	}
	return &gatewayClient{config: cfg, logger: logger}
}

func (g *gatewayClient) Start(ctx context.Context) error {
	g.mu.Lock()
	defer g.mu.Unlock()

	if g.started {
		return errors.New("gateway client already started")
	}
	g.started = true

	if g.config.GatewayURL == "" {
		g.logger.Info("gateway client placeholder started without configured gateway URL")
	} else {
		g.logger.Info("gateway client placeholder started", "gateway_url", g.config.GatewayURL)
	}

	go func() {
		<-ctx.Done()
		g.logger.Info("gateway client placeholder context canceled")
	}()

	return nil
}

func (g *gatewayClient) Stop(ctx context.Context) error {
	g.mu.Lock()
	defer g.mu.Unlock()

	if !g.started {
		return nil
	}
	g.started = false

	select {
	case <-ctx.Done():
		return ctx.Err()
	default:
	}

	g.logger.Info("gateway client placeholder stopped")
	return nil
}

func (g *gatewayClient) Ready() bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.started
}

func newHealthServer(cfg *config.Config, logger *slog.Logger, sm *session.SessionManager, gateway *gatewayClient) (*http.Server, net.Listener, error) {
	mux := http.NewServeMux()
	healthHandler := func(w http.ResponseWriter, r *http.Request) {
		info := sm.GetSessionInfo()
		status := http.StatusOK
		body := map[string]interface{}{
			"status":            "ok",
			"time":              time.Now().UTC().Format(time.RFC3339Nano),
			"gateway_ready":     gateway.Ready(),
			"gateway_configured": cfg.GatewayURL != "",
		}
		if info != nil {
			body["session_id"] = info.SessionID
			body["workspace_id"] = info.WorkspaceID
			body["project_valid"] = info.ProjectValid
			body["current_branch"] = info.CurrentBranch
		}

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		if err := json.NewEncoder(w).Encode(body); err != nil {
			logger.Warn("failed to write health response", "error", err)
		}
	}
	mux.HandleFunc("/health", healthHandler)
	mux.HandleFunc("/healthz", healthHandler)

	addr := fmt.Sprintf("127.0.0.1:%d", cfg.HealthPort)
	listener, err := net.Listen("tcp", addr)
	if err != nil {
		return nil, nil, fmt.Errorf("listen on health endpoint %q: %w", addr, err)
	}

	server := &http.Server{
		Addr:              addr,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	return server, listener, nil
}
