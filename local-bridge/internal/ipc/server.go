package ipc

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"os"
	"path"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	unauthorizedCode = -32001
	streamModeJSON   = "json"
	streamModeSSE    = "sse"
	writeQueueDepth  = 64
	writeQueueWait   = 5 * time.Second
)

// MethodHandler handles a JSON-RPC method invocation.
type MethodHandler func(params json.RawMessage) (interface{}, error)

// Server implements a JSON-RPC 2.0 server over a Unix domain socket.
//
// Clients must authenticate with the built-in session.authenticate request or
// notification before invoking any registered methods. Once authenticated, the
// client can receive server notifications either as line-delimited JSON-RPC
// notifications or as SSE frames carrying a JSON-RPC notification payload.
type Server struct {
	socketPath string
	logger     *slog.Logger

	mu             sync.RWMutex
	methods        map[string]MethodHandler
	clients        map[*clientConn]struct{}
	listener       *net.UnixListener
	ctx            context.Context
	cancel         context.CancelFunc
	nonceValidator func(string) bool
	errCh          chan error

	wg       sync.WaitGroup
	startMux sync.Mutex
	started  bool
	stopped  bool
}

type clientConn struct {
	conn      net.Conn
	logger    *slog.Logger
	remote    string
	outbound  chan []byte
	done      chan struct{}
	closeOnce sync.Once

	mu            sync.RWMutex
	authenticated bool
	streamMode    string
}

type incomingEnvelope struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params"`
	Result  json.RawMessage `json:"result"`
	Error   *RPCError       `json:"error"`
}

type authParams struct {
	Nonce  string `json:"nonce"`
	Stream string `json:"stream,omitempty"`
}

// NewServer constructs a Server for the provided Unix domain socket path.
func NewServer(socketPath string, logger *slog.Logger) *Server {
	if logger == nil {
		logger = slog.Default()
	}

	return &Server{
		socketPath: strings.TrimSpace(socketPath),
		logger:     logger,
		methods:    make(map[string]MethodHandler),
		clients:    make(map[*clientConn]struct{}),
		errCh:      make(chan error, 1),
		nonceValidator: func(string) bool {
			return false
		},
	}
}

// SetNonceValidator configures the validator used by session.authenticate.
func (s *Server) SetNonceValidator(validator func(string) bool) {
	if validator == nil {
		validator = func(string) bool { return false }
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	s.nonceValidator = validator
}

// Errors returns a channel that receives fatal server errors after Start.
func (s *Server) Errors() <-chan error {
	return s.errCh
}

// RegisterMethod registers a JSON-RPC method handler.
func (s *Server) RegisterMethod(name string, handler MethodHandler) {
	name = strings.TrimSpace(name)
	if name == "" {
		panic("ipc: method name must not be empty")
	}
	if handler == nil {
		panic("ipc: method handler must not be nil")
	}
	if name == "session.authenticate" {
		panic("ipc: session.authenticate is reserved")
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	s.methods[name] = handler
}

// Start starts listening on the Unix domain socket and returns once the accept
// loop is running.
func (s *Server) Start(ctx context.Context) error {
	if ctx == nil {
		return errors.New("start ipc server: context is nil")
	}

	s.startMux.Lock()
	defer s.startMux.Unlock()

	if s.started {
		return errors.New("start ipc server: server already started")
	}
	if s.stopped {
		return errors.New("start ipc server: server already stopped")
	}

	if err := prepareSocketPath(s.socketPath); err != nil {
		return fmt.Errorf("start ipc server: %w", err)
	}

	addr := &net.UnixAddr{Name: s.socketPath, Net: "unix"}
	listener, err := net.ListenUnix("unix", addr)
	if err != nil {
		return fmt.Errorf("start ipc server: listen on %q: %w", s.socketPath, err)
	}
	if err := os.Chmod(s.socketPath, 0o600); err != nil {
		listener.Close()
		_ = os.Remove(s.socketPath)
		return fmt.Errorf("start ipc server: chmod socket %q: %w", s.socketPath, err)
	}

	s.ctx, s.cancel = context.WithCancel(ctx)
	s.listener = listener
	s.started = true

	s.wg.Add(1)
	go s.acceptLoop()

	go func() {
		<-s.ctx.Done()
		_ = s.Stop()
	}()

	s.logger.Info("ipc server started", "socket_path", s.socketPath)
	return nil
}

// Stop gracefully stops the IPC server and disconnects active clients.
func (s *Server) Stop() error {
	s.startMux.Lock()
	if s.stopped {
		s.startMux.Unlock()
		return nil
	}
	s.stopped = true
	listener := s.listener
	s.listener = nil
	if s.cancel != nil {
		s.cancel()
	}
	clients := s.snapshotClients()
	s.startMux.Unlock()

	var stopErr error
	if listener != nil {
		if err := listener.Close(); err != nil && !errors.Is(err, net.ErrClosed) {
			stopErr = errors.Join(stopErr, fmt.Errorf("close listener: %w", err))
		}
	}

	for _, client := range clients {
		if err := client.close(); err != nil && !errors.Is(err, net.ErrClosed) {
			stopErr = errors.Join(stopErr, fmt.Errorf("close client %s: %w", client.remote, err))
		}
	}

	s.wg.Wait()

	if err := os.Remove(s.socketPath); err != nil && !errors.Is(err, os.ErrNotExist) {
		stopErr = errors.Join(stopErr, fmt.Errorf("remove socket %q: %w", s.socketPath, err))
	}

	s.logger.Info("ipc server stopped", "socket_path", s.socketPath)
	return stopErr
}

// BroadcastNotification sends a notification to all authenticated clients.
func (s *Server) BroadcastNotification(method string, params interface{}) error {
	notification := NewNotification(method, params)
	clients := s.snapshotClients()
	var notifyErr error

	for _, client := range clients {
		authenticated, streamMode := client.state()
		if !authenticated {
			continue
		}

		if err := s.queueNotification(client, notification, streamMode); err != nil {
			notifyErr = errors.Join(notifyErr, fmt.Errorf("notify client %s: %w", client.remote, err))
		}
	}

	return notifyErr
}

func (s *Server) acceptLoop() {
	defer s.wg.Done()

	for {
		conn, err := s.listener.Accept()
		if err != nil {
			select {
			case <-s.ctx.Done():
				return
			default:
			}

			if netErr, ok := err.(net.Error); ok && netErr.Temporary() {
				s.logger.Warn("temporary IPC accept failure", "error", err)
				time.Sleep(100 * time.Millisecond)
				continue
			}

			s.reportFatal(fmt.Errorf("accept IPC connection: %w", err))
			s.logger.Error("IPC accept loop stopped", "error", err)
			return
		}

		client := &clientConn{
			conn:     conn,
			logger:   s.logger.With("client", conn.RemoteAddr().String()),
			remote:   conn.RemoteAddr().String(),
			outbound: make(chan []byte, writeQueueDepth),
			done:     make(chan struct{}),
			streamMode: streamModeJSON,
		}

		s.mu.Lock()
		s.clients[client] = struct{}{}
		s.mu.Unlock()

		s.wg.Add(1)
		go s.handleClient(client)
	}
}

func (s *Server) handleClient(client *clientConn) {
	defer s.wg.Done()
	defer s.unregisterClient(client)
	defer client.close()

	writerErrCh := make(chan error, 1)
	go s.writeLoop(client, writerErrCh)

	decoder := json.NewDecoder(client.conn)
	for {
		var raw json.RawMessage
		if err := decoder.Decode(&raw); err != nil {
			if errors.Is(err, io.EOF) || errors.Is(err, net.ErrClosed) {
				return
			}

			client.logger.Warn("failed to decode message", "error", err)
			_ = s.queueJSON(client, NewErrorResponse(nil, ParseError, "invalid JSON payload"))
			return
		}

		if err := s.handleRawMessage(client, raw); err != nil {
			client.logger.Warn("failed to handle message", "error", err)
			return
		}

		select {
		case err := <-writerErrCh:
			if err != nil {
				client.logger.Warn("client writer failed", "error", err)
			}
			return
		default:
		}
	}
}

func (s *Server) writeLoop(client *clientConn, errCh chan<- error) {
	for {
		select {
		case payload := <-client.outbound:
			if err := writeAll(client.conn, payload); err != nil {
				errCh <- err
				_ = client.close()
				return
			}
		case <-client.done:
			return
		case <-s.ctx.Done():
			return
		}
	}
}

func (s *Server) handleRawMessage(client *clientConn, raw json.RawMessage) error {
	var envelope incomingEnvelope
	if err := json.Unmarshal(raw, &envelope); err != nil {
		_ = s.queueJSON(client, NewErrorResponse(nil, InvalidRequest, "payload must be a JSON object"))
		return fmt.Errorf("unmarshal envelope: %w", err)
	}

	if envelope.JSONRPC != "2.0" {
		response := NewErrorResponse(idFromRaw(envelope.ID), InvalidRequest, "jsonrpc must be \"2.0\"")
		if err := s.queueJSON(client, response); err != nil {
			return err
		}
		return nil
	}

	id := idFromRaw(envelope.ID)
	hasID := len(bytes.TrimSpace(envelope.ID)) > 0 && string(bytes.TrimSpace(envelope.ID)) != "null"

	if envelope.Method != "" {
		request := Request{
			JSONRPC: envelope.JSONRPC,
			ID:      id,
			Method:  envelope.Method,
			Params:  envelope.Params,
		}
		if hasID {
			return s.handleRequest(client, request)
		}
		return s.handleNotification(client, request)
	}

	if len(envelope.Result) > 0 || envelope.Error != nil {
		client.logger.Debug("received client response", "id", id)
		return nil
	}

	if hasID {
		return s.queueJSON(client, NewErrorResponse(id, InvalidRequest, "invalid JSON-RPC message"))
	}

	return errors.New("invalid JSON-RPC message")
}

func (s *Server) handleRequest(client *clientConn, request Request) error {
	if !client.isAuthenticated() {
		if request.Method != "session.authenticate" {
			response := NewErrorResponse(request.ID, unauthorizedCode, "session authentication required")
			if err := s.queueJSON(client, response); err != nil {
				return err
			}
			return errors.New("unauthenticated request received")
		}

		result, rpcErr := s.handleAuthentication(client, request.Params)
		response := NewResponse(request.ID, result)
		if rpcErr != nil {
			response = &Response{JSONRPC: "2.0", ID: request.ID, Error: rpcErr}
		}
		return s.queueJSON(client, response)
	}

	if request.Method == "session.authenticate" {
		return s.queueJSON(client, NewErrorResponse(request.ID, InvalidRequest, "session already authenticated"))
	}

	handler, ok := s.lookupMethod(request.Method)
	if !ok {
		return s.queueJSON(client, NewErrorResponse(request.ID, MethodNotFound, fmt.Sprintf("method %q not found", request.Method)))
	}

	result, err := handler(request.Params)
	if err != nil {
		response := &Response{JSONRPC: "2.0", ID: request.ID, Error: rpcErrorFrom(err)}
		return s.queueJSON(client, response)
	}

	return s.queueJSON(client, NewResponse(request.ID, result))
}

func (s *Server) handleNotification(client *clientConn, request Request) error {
	if !client.isAuthenticated() {
		if request.Method != "session.authenticate" {
			return errors.New("unauthenticated notification received")
		}

		_, rpcErr := s.handleAuthentication(client, request.Params)
		if rpcErr != nil {
			return rpcErr
		}
		return nil
	}

	if request.Method == "session.authenticate" {
		return &RPCError{Code: InvalidRequest, Message: "session already authenticated"}
	}

	handler, ok := s.lookupMethod(request.Method)
	if !ok {
		return &RPCError{Code: MethodNotFound, Message: fmt.Sprintf("method %q not found", request.Method)}
	}

	_, err := handler(request.Params)
	if err != nil {
		return rpcErrorFrom(err)
	}

	return nil
}

func (s *Server) handleAuthentication(client *clientConn, params json.RawMessage) (interface{}, *RPCError) {
	var auth authParams
	if len(bytes.TrimSpace(params)) == 0 {
		return nil, &RPCError{Code: InvalidParams, Message: "authentication params are required"}
	}
	if err := json.Unmarshal(params, &auth); err != nil {
		return nil, &RPCError{Code: InvalidParams, Message: "authentication params are invalid", Data: err.Error()}
	}

	auth.Nonce = strings.TrimSpace(auth.Nonce)
	streamMode := strings.ToLower(strings.TrimSpace(auth.Stream))
	if streamMode == "" {
		streamMode = streamModeJSON
	}
	if streamMode != streamModeJSON && streamMode != streamModeSSE {
		return nil, &RPCError{Code: InvalidParams, Message: fmt.Sprintf("unsupported stream mode %q", auth.Stream)}
	}
	if auth.Nonce == "" {
		return nil, &RPCError{Code: InvalidParams, Message: "nonce is required"}
	}

	validator := s.currentNonceValidator()
	if !validator(auth.Nonce) {
		return nil, &RPCError{Code: unauthorizedCode, Message: "invalid session nonce"}
	}

	client.setAuthenticated(streamMode)
	client.logger.Info("client authenticated", "stream_mode", streamMode)

	return map[string]interface{}{
		"authenticated": true,
		"stream":        streamMode,
		"server_time":   time.Now().UTC().Format(time.RFC3339Nano),
	}, nil
}

func (s *Server) queueJSON(client *clientConn, payload interface{}) error {
	encoded, err := json.Marshal(payload)
	if err != nil {
		return fmt.Errorf("marshal JSON payload: %w", err)
	}
	encoded = append(encoded, '\n')
	return s.queuePayload(client, encoded)
}

func (s *Server) queueNotification(client *clientConn, notification *Notification, streamMode string) error {
	switch streamMode {
	case streamModeSSE:
		payload, err := encodeSSE(notification)
		if err != nil {
			return err
		}
		return s.queuePayload(client, payload)
	default:
		return s.queueJSON(client, notification)
	}
}

func (s *Server) queuePayload(client *clientConn, payload []byte) error {
	select {
	case <-client.done:
		return net.ErrClosed
	case client.outbound <- payload:
		return nil
	case <-time.After(writeQueueWait):
		_ = client.close()
		return fmt.Errorf("timed out queueing payload for client %s", client.remote)
	case <-s.ctx.Done():
		return s.ctx.Err()
	}
}

func (s *Server) lookupMethod(name string) (MethodHandler, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	handler, ok := s.methods[name]
	return handler, ok
}

func (s *Server) currentNonceValidator() func(string) bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.nonceValidator
}

func (s *Server) snapshotClients() []*clientConn {
	s.mu.RLock()
	defer s.mu.RUnlock()

	clients := make([]*clientConn, 0, len(s.clients))
	for client := range s.clients {
		clients = append(clients, client)
	}
	return clients
}

func (s *Server) unregisterClient(client *clientConn) {
	s.mu.Lock()
	delete(s.clients, client)
	s.mu.Unlock()
}

func (s *Server) reportFatal(err error) {
	select {
	case s.errCh <- err:
	default:
	}
}

func (c *clientConn) close() error {
	var err error
	c.closeOnce.Do(func() {
		close(c.done)
		err = c.conn.Close()
	})
	return err
}

func (c *clientConn) isAuthenticated() bool {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.authenticated
}

func (c *clientConn) setAuthenticated(streamMode string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.authenticated = true
	c.streamMode = streamMode
}

func (c *clientConn) state() (bool, string) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.authenticated, c.streamMode
}

func prepareSocketPath(socketPath string) error {
	if strings.TrimSpace(socketPath) == "" {
		return errors.New("socket path is required")
	}

	if err := os.MkdirAll(filepath.Dir(socketPath), 0o755); err != nil {
		return fmt.Errorf("create socket directory: %w", err)
	}

	info, err := os.Stat(socketPath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return fmt.Errorf("stat socket path %q: %w", socketPath, err)
	}

	if info.Mode()&os.ModeSocket == 0 {
		return fmt.Errorf("socket path %q exists and is not a Unix socket", socketPath)
	}

	conn, dialErr := net.DialTimeout("unix", socketPath, 200*time.Millisecond)
	if dialErr == nil {
		_ = conn.Close()
		return fmt.Errorf("socket path %q is already in use", socketPath)
	}
	if !isStaleSocketError(dialErr) {
		return fmt.Errorf("probe socket path %q: %w", socketPath, dialErr)
	}

	if err := os.Remove(socketPath); err != nil {
		return fmt.Errorf("remove stale socket %q: %w", socketPath, err)
	}

	return nil
}

func isStaleSocketError(err error) bool {
	return errors.Is(err, syscall.ENOENT) || errors.Is(err, syscall.ECONNREFUSED) || errors.Is(err, syscall.ECONNRESET)
}

func encodeSSE(notification *Notification) ([]byte, error) {
	payload, err := json.Marshal(notification)
	if err != nil {
		return nil, fmt.Errorf("marshal notification: %w", err)
	}

	var builder strings.Builder
	builder.WriteString("event: ")
	builder.WriteString(path.Clean(notification.Method))
	builder.WriteByte('\n')
	builder.WriteString("data: ")
	builder.Write(payload)
	builder.WriteString("\n\n")

	return []byte(builder.String()), nil
}

func idFromRaw(raw json.RawMessage) interface{} {
	raw = bytes.TrimSpace(raw)
	if len(raw) == 0 || string(raw) == "null" {
		return nil
	}

	var id interface{}
	if err := json.Unmarshal(raw, &id); err != nil {
		return nil
	}
	return id
}

func rpcErrorFrom(err error) *RPCError {
	var rpcErr *RPCError
	if errors.As(err, &rpcErr) {
		return rpcErr
	}

	return &RPCError{
		Code:    InternalError,
		Message: err.Error(),
	}
}

func writeAll(conn net.Conn, payload []byte) error {
	for len(payload) > 0 {
		n, err := conn.Write(payload)
		if err != nil {
			return err
		}
		payload = payload[n:]
	}
	return nil
}
