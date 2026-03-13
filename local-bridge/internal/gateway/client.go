package gateway

import (
	"bytes"
	"bufio"
	"context"
	"crypto/rand"
	"crypto/sha1"
	"crypto/tls"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	apiPrefix           = "/api/editor/v1"
	defaultUserAgent    = "echothink-bridge/1.0"
	maxJSONResponseSize = 16 << 20
	wsGUID              = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
	defaultBufferEvents = 64
)

// Client provides access to the Editor Gateway REST and WebSocket APIs.
type Client struct {
	baseURL    string
	token      string
	httpClient *http.Client
	logger     *slog.Logger
	wsConn     net.Conn
	events     chan Event

	mu          sync.Mutex
	wsReader    *bufio.Reader
	closeOnce   sync.Once
	eventsOnce  sync.Once
	readLoopWG  sync.WaitGroup
	wsConnected bool
	closed      bool
}

// Event represents one gateway event delivered over the WebSocket stream.
type Event struct {
	Type    string          `json:"type"`
	Payload json.RawMessage `json:"payload"`
}

// APIError is returned when the gateway responds with a non-2xx status code.
type APIError struct {
	StatusCode int    `json:"status_code"`
	Message    string `json:"message"`
}

// Error implements the error interface.
func (e *APIError) Error() string {
	if e == nil {
		return "<nil>"
	}
	if e.Message == "" {
		return fmt.Sprintf("gateway API returned HTTP %d", e.StatusCode)
	}
	return fmt.Sprintf("gateway API returned HTTP %d: %s", e.StatusCode, e.Message)
}

type pullStream struct {
	io.ReadCloser
	checksum string
}

func (p *pullStream) ExpectedChecksum() string {
	return p.checksum
}

// NewClient constructs a gateway client.
func NewClient(baseURL, token string, logger *slog.Logger) *Client {
	if logger == nil {
		logger = slog.Default()
	}

	transport := &http.Transport{
		Proxy: http.ProxyFromEnvironment,
		DialContext: (&net.Dialer{
			Timeout:   10 * time.Second,
			KeepAlive: 30 * time.Second,
		}).DialContext,
		ForceAttemptHTTP2:     true,
		MaxIdleConns:          16,
		IdleConnTimeout:       90 * time.Second,
		TLSHandshakeTimeout:   10 * time.Second,
		ExpectContinueTimeout: 1 * time.Second,
		ResponseHeaderTimeout: 15 * time.Second,
	}

	return &Client{
		baseURL: strings.TrimSpace(baseURL),
		token:   strings.TrimSpace(token),
		logger:  logger,
		httpClient: &http.Client{
			Transport: transport,
		},
		events: make(chan Event, defaultBufferEvents),
	}
}

// ListAssets returns the remote asset catalog for a workspace.
func (c *Client) ListAssets(ctx context.Context, workspaceID string) ([]json.RawMessage, error) {
	values := url.Values{}
	if workspaceID = strings.TrimSpace(workspaceID); workspaceID != "" {
		values.Set("workspace_id", workspaceID)
	}
	path := "assets"
	if encoded := values.Encode(); encoded != "" {
		path += "?" + encoded
	}
	return c.getJSONArray(ctx, http.MethodGet, []string{path}, nil)
}

// GetAsset returns the raw asset document for assetID.
func (c *Client) GetAsset(ctx context.Context, assetID string) (json.RawMessage, error) {
	assetID = strings.TrimSpace(assetID)
	if assetID == "" {
		return nil, errors.New("asset ID is required")
	}
	return c.getJSONObject(ctx, http.MethodGet, []string{"assets/" + url.PathEscape(assetID)}, nil)
}

// DiffAsset asks the gateway to compare local and remote asset references.
func (c *Client) DiffAsset(ctx context.Context, assetID string, localRef, remoteRef map[string]string) (json.RawMessage, error) {
	assetID = strings.TrimSpace(assetID)
	if assetID == "" {
		return nil, errors.New("asset ID is required")
	}
	body := map[string]any{
		"local_ref":  cloneStringMap(localRef),
		"remote_ref": cloneStringMap(remoteRef),
	}
	return c.getJSONObject(ctx, http.MethodPost, []string{"assets/" + url.PathEscape(assetID) + "/diff"}, body)
}

// PullAsset returns a streaming download for the requested asset reference.
func (c *Client) PullAsset(ctx context.Context, assetID, ref string) (io.ReadCloser, int64, error) {
	assetID = strings.TrimSpace(assetID)
	if assetID == "" {
		return nil, 0, errors.New("asset ID is required")
	}

	values := url.Values{}
	if ref = strings.TrimSpace(ref); ref != "" {
		values.Set("ref", ref)
	}
	path := "assets/" + url.PathEscape(assetID) + "/pull"
	if encoded := values.Encode(); encoded != "" {
		path += "?" + encoded
	}

	resp, err := c.doRequest(ctx, http.MethodGet, path, nil)
	if err != nil {
		return nil, 0, err
	}

	contentLength := resp.ContentLength
	if contentLength < 0 {
		contentLength = parseInt64(resp.Header.Get("X-Content-Length"))
	}

	checksum := normalizeChecksum(firstNonEmpty(
		resp.Header.Get("X-Checksum-SHA256"),
		resp.Header.Get("X-Content-SHA256"),
		trimETag(resp.Header.Get("ETag")),
	))

	return &pullStream{ReadCloser: resp.Body, checksum: checksum}, contentLength, nil
}

// ValidateAsset submits validation details for a local asset import.
func (c *Client) ValidateAsset(ctx context.Context, assetID string, validationData map[string]any) (json.RawMessage, error) {
	assetID = strings.TrimSpace(assetID)
	if assetID == "" {
		return nil, errors.New("asset ID is required")
	}
	return c.getJSONObject(ctx, http.MethodPost, []string{"assets/" + url.PathEscape(assetID) + "/validate"}, validationData)
}

// PromoteRequest requests promotion of an asset.
func (c *Client) PromoteRequest(ctx context.Context, assetID string, data map[string]any) error {
	assetID = strings.TrimSpace(assetID)
	if assetID == "" {
		return errors.New("asset ID is required")
	}
	return c.doJSON(ctx, http.MethodPost, "assets/"+url.PathEscape(assetID)+"/promote", data, nil)
}

// RegenerateRequest requests asset regeneration.
func (c *Client) RegenerateRequest(ctx context.Context, assetID string, data map[string]any) error {
	assetID = strings.TrimSpace(assetID)
	if assetID == "" {
		return errors.New("asset ID is required")
	}
	return c.doJSON(ctx, http.MethodPost, "assets/"+url.PathEscape(assetID)+"/regenerate", data, nil)
}

// UpdateLock sends the current local asset lock state to the gateway.
func (c *Client) UpdateLock(ctx context.Context, data map[string]any) error {
	return c.doJSON(ctx, http.MethodPost, "assets/lock", data, nil)
}

// ListTasks returns tasks visible to a workspace.
func (c *Client) ListTasks(ctx context.Context, workspaceID string) ([]json.RawMessage, error) {
	values := url.Values{}
	if workspaceID = strings.TrimSpace(workspaceID); workspaceID != "" {
		values.Set("workspace_id", workspaceID)
	}
	path := "tasks"
	if encoded := values.Encode(); encoded != "" {
		path += "?" + encoded
	}
	return c.getJSONArray(ctx, http.MethodGet, []string{path}, nil)
}

// GetTask returns a raw task document.
func (c *Client) GetTask(ctx context.Context, taskID string) (json.RawMessage, error) {
	taskID = strings.TrimSpace(taskID)
	if taskID == "" {
		return nil, errors.New("task ID is required")
	}
	return c.getJSONObject(ctx, http.MethodGet, []string{"tasks/" + url.PathEscape(taskID)}, nil)
}

// RequestPlan submits a planning request to the gateway.
func (c *Client) RequestPlan(ctx context.Context, data map[string]any) (json.RawMessage, error) {
	return c.getJSONObject(ctx, http.MethodPost, []string{"plans/request", "plans"}, data)
}

// AcceptPlan accepts a gateway-generated plan.
func (c *Client) AcceptPlan(ctx context.Context, planID string) error {
	planID = strings.TrimSpace(planID)
	if planID == "" {
		return errors.New("plan ID is required")
	}
	return c.doJSONPaths(ctx, http.MethodPost, []string{"plans/" + url.PathEscape(planID) + "/accept"}, nil, nil)
}

// SubmitContext uploads an editor context snapshot.
func (c *Client) SubmitContext(ctx context.Context, snapshot map[string]any) error {
	return c.doJSONPaths(ctx, http.MethodPost, []string{"context/snapshot", "context"}, snapshot, nil)
}

// SubmitLogs uploads a log bundle.
func (c *Client) SubmitLogs(ctx context.Context, bundle map[string]any) error {
	return c.doJSONPaths(ctx, http.MethodPost, []string{"logs/bundles", "logs"}, bundle, nil)
}

// SubmitTestRun uploads a test execution result.
func (c *Client) SubmitTestRun(ctx context.Context, data map[string]any) (json.RawMessage, error) {
	return c.getJSONObject(ctx, http.MethodPost, []string{"tests/runs", "tests/run"}, data)
}

// ConnectWebSocket connects to the gateway event stream and starts a reader loop.
func (c *Client) ConnectWebSocket(ctx context.Context) error {
	if ctx == nil {
		return errors.New("websocket context is nil")
	}

	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return errors.New("gateway client is closed")
	}
	if c.wsConnected {
		c.mu.Unlock()
		return errors.New("websocket already connected")
	}
	c.mu.Unlock()

	paths := []string{"ws", "events", "events/ws"}
	var dialErr error
	for _, candidate := range paths {
		conn, reader, err := c.connectWebSocketPath(ctx, candidate)
		if err == nil {
			c.mu.Lock()
			c.wsConn = conn
			c.wsReader = reader
			c.wsConnected = true
			c.mu.Unlock()

			c.readLoopWG.Add(1)
			go c.readEvents(ctx)
			c.logger.Info("gateway websocket connected", "path", candidate)
			return nil
		}
		var apiErr *APIError
		if errors.As(err, &apiErr) && (apiErr.StatusCode == http.StatusNotFound || apiErr.StatusCode == http.StatusMethodNotAllowed) {
			dialErr = err
			continue
		}
		dialErr = err
		break
	}
	if dialErr == nil {
		dialErr = errors.New("websocket endpoint not available")
	}
	return dialErr
}

// Events exposes the gateway event stream.
func (c *Client) Events() <-chan Event {
	return c.events
}

// Close closes the WebSocket stream and releases client resources.
func (c *Client) Close() error {
	var closeErr error
	c.closeOnce.Do(func() {
		c.mu.Lock()
		c.closed = true
		conn := c.wsConn
		c.wsConn = nil
		c.wsReader = nil
		c.wsConnected = false
		c.mu.Unlock()

		if conn != nil {
			closeErr = conn.Close()
		}
		c.readLoopWG.Wait()
		c.closeEvents()
		if transport, ok := c.httpClient.Transport.(*http.Transport); ok {
			transport.CloseIdleConnections()
		}
	})
	return closeErr
}

// doRequest sends a request to one API path under /api/editor/v1/.
func (c *Client) doRequest(ctx context.Context, method, path string, body any) (*http.Response, error) {
	return c.doRequestPaths(ctx, method, []string{path}, body)
}

// doJSON performs a JSON request and decodes the response into result.
func (c *Client) doJSON(ctx context.Context, method, path string, body, result any) error {
	return c.doJSONPaths(ctx, method, []string{path}, body, result)
}

func (c *Client) doRequestPaths(ctx context.Context, method string, paths []string, body any) (*http.Response, error) {
	if ctx == nil {
		return nil, errors.New("request context is nil")
	}
	if strings.TrimSpace(c.baseURL) == "" {
		return nil, errors.New("gateway base URL is required")
	}
	method = strings.ToUpper(strings.TrimSpace(method))
	if method == "" {
		return nil, errors.New("HTTP method is required")
	}

	payload, contentType, err := marshalRequestBody(body)
	if err != nil {
		return nil, err
	}

	var lastErr error
	for _, path := range paths {
		endpoint, err := c.buildAPIURL(path)
		if err != nil {
			return nil, err
		}

		var requestBody io.Reader
		if len(payload) > 0 {
			requestBody = bytes.NewReader(payload)
		}
		req, err := http.NewRequestWithContext(ctx, method, endpoint, requestBody)
		if err != nil {
			return nil, fmt.Errorf("create %s request for %q: %w", method, endpoint, err)
		}
		if len(payload) > 0 {
			req.Header.Set("Content-Type", contentType)
		}
		req.Header.Set("Accept", "application/json")
		req.Header.Set("User-Agent", defaultUserAgent)
		if c.token != "" {
			req.Header.Set("Authorization", "Bearer "+c.token)
		}

		resp, err := c.httpClient.Do(req)
		if err != nil {
			lastErr = fmt.Errorf("perform %s %q: %w", method, endpoint, err)
			break
		}
		if resp.StatusCode < http.StatusOK || resp.StatusCode >= http.StatusMultipleChoices {
			apiErr := readAPIError(resp)
			lastErr = apiErr
			if apiErr.StatusCode == http.StatusNotFound || apiErr.StatusCode == http.StatusMethodNotAllowed {
				continue
			}
			break
		}
		return resp, nil
	}

	if lastErr == nil {
		lastErr = errors.New("request failed")
	}
	return nil, lastErr
}

func (c *Client) doJSONPaths(ctx context.Context, method string, paths []string, body, result any) error {
	resp, err := c.doRequestPaths(ctx, method, paths, body)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if result == nil {
		_, _ = io.Copy(io.Discard, resp.Body)
		return nil
	}

	data, err := io.ReadAll(io.LimitReader(resp.Body, maxJSONResponseSize))
	if err != nil {
		return fmt.Errorf("read response body: %w", err)
	}
	trimmed := strings.TrimSpace(string(data))
	if trimmed == "" {
		return nil
	}

	if rawTarget, ok := result.(*json.RawMessage); ok {
		*rawTarget = append((*rawTarget)[:0], []byte(trimmed)...)
		return nil
	}

	if err := json.Unmarshal([]byte(trimmed), result); err != nil {
		return fmt.Errorf("decode JSON response: %w", err)
	}
	return nil
}

func (c *Client) getJSONArray(ctx context.Context, method string, paths []string, body any) ([]json.RawMessage, error) {
	resp, err := c.doRequestPaths(ctx, method, paths, body)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	data, err := io.ReadAll(io.LimitReader(resp.Body, maxJSONResponseSize))
	if err != nil {
		return nil, fmt.Errorf("read response body: %w", err)
	}
	return unwrapArrayDocument(data)
}

func (c *Client) getJSONObject(ctx context.Context, method string, paths []string, body any) (json.RawMessage, error) {
	resp, err := c.doRequestPaths(ctx, method, paths, body)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	data, err := io.ReadAll(io.LimitReader(resp.Body, maxJSONResponseSize))
	if err != nil {
		return nil, fmt.Errorf("read response body: %w", err)
	}
	return unwrapObjectDocument(data), nil
}

func (c *Client) buildAPIURL(path string) (string, error) {
	parsed, err := url.Parse(c.baseURL)
	if err != nil {
		return "", fmt.Errorf("parse gateway URL %q: %w", c.baseURL, err)
	}
	relative, err := url.Parse(strings.TrimSpace(path))
	if err != nil {
		return "", fmt.Errorf("parse API path %q: %w", path, err)
	}
	switch strings.ToLower(parsed.Scheme) {
	case "http", "https":
	case "ws":
		parsed.Scheme = "http"
	case "wss":
		parsed.Scheme = "https"
	default:
		return "", fmt.Errorf("unsupported gateway URL scheme %q", parsed.Scheme)
	}
	parsed.RawQuery = relative.RawQuery
	parsed.Fragment = ""
	parsed.Path = strings.TrimSuffix(strings.TrimRight(parsed.Path, "/"), apiPrefix)
	parsed.Path = joinURLPath(parsed.Path, apiPrefix, relative.Path)
	return parsed.String(), nil
}

func (c *Client) connectWebSocketPath(ctx context.Context, path string) (net.Conn, *bufio.Reader, error) {
	endpoint, err := c.buildWebSocketURL(path)
	if err != nil {
		return nil, nil, err
	}

	parsed, err := url.Parse(endpoint)
	if err != nil {
		return nil, nil, fmt.Errorf("parse websocket URL %q: %w", endpoint, err)
	}

	conn, err := dialWebSocket(ctx, parsed)
	if err != nil {
		return nil, nil, err
	}

	secKey, err := randomWebSocketKey()
	if err != nil {
		_ = conn.Close()
		return nil, nil, fmt.Errorf("generate websocket key: %w", err)
	}

	requestPath := parsed.EscapedPath()
	if requestPath == "" {
		requestPath = "/"
	}
	if parsed.RawQuery != "" {
		requestPath += "?" + parsed.RawQuery
	}

	var builder strings.Builder
	builder.WriteString("GET ")
	builder.WriteString(requestPath)
	builder.WriteString(" HTTP/1.1\r\n")
	builder.WriteString("Host: ")
	builder.WriteString(hostHeader(parsed))
	builder.WriteString("\r\n")
	builder.WriteString("Upgrade: websocket\r\n")
	builder.WriteString("Connection: Upgrade\r\n")
	builder.WriteString("Sec-WebSocket-Version: 13\r\n")
	builder.WriteString("Sec-WebSocket-Key: ")
	builder.WriteString(secKey)
	builder.WriteString("\r\n")
	builder.WriteString("User-Agent: ")
	builder.WriteString(defaultUserAgent)
	builder.WriteString("\r\n")
	if c.token != "" {
		builder.WriteString("Authorization: Bearer ")
		builder.WriteString(c.token)
		builder.WriteString("\r\n")
	}
	builder.WriteString("\r\n")

	if _, err := io.WriteString(conn, builder.String()); err != nil {
		_ = conn.Close()
		return nil, nil, fmt.Errorf("write websocket handshake: %w", err)
	}

	reader := bufio.NewReader(conn)
	resp, err := http.ReadResponse(reader, &http.Request{Method: http.MethodGet})
	if err != nil {
		_ = conn.Close()
		return nil, nil, fmt.Errorf("read websocket handshake response: %w", err)
	}

	if resp.StatusCode != http.StatusSwitchingProtocols {
		message := extractErrorMessage(io.LimitReader(resp.Body, 1<<20))
		_ = resp.Body.Close()
		_ = conn.Close()
		return nil, nil, &APIError{StatusCode: resp.StatusCode, Message: message}
	}
	if !strings.EqualFold(resp.Header.Get("Upgrade"), "websocket") {
		_ = resp.Body.Close()
		_ = conn.Close()
		return nil, nil, errors.New("websocket handshake missing Upgrade: websocket")
	}
	acceptExpected := websocketAcceptKey(secKey)
	if strings.TrimSpace(resp.Header.Get("Sec-WebSocket-Accept")) != acceptExpected {
		_ = resp.Body.Close()
		_ = conn.Close()
		return nil, nil, errors.New("websocket handshake returned invalid Sec-WebSocket-Accept")
	}

	return conn, reader, nil
}

func (c *Client) buildWebSocketURL(path string) (string, error) {
	parsed, err := url.Parse(c.baseURL)
	if err != nil {
		return "", fmt.Errorf("parse gateway URL %q: %w", c.baseURL, err)
	}
	relative, err := url.Parse(strings.TrimSpace(path))
	if err != nil {
		return "", fmt.Errorf("parse websocket path %q: %w", path, err)
	}
	switch strings.ToLower(parsed.Scheme) {
	case "http":
		parsed.Scheme = "ws"
	case "https":
		parsed.Scheme = "wss"
	case "ws", "wss":
	default:
		return "", fmt.Errorf("unsupported gateway URL scheme %q", parsed.Scheme)
	}
	parsed.RawQuery = relative.RawQuery
	parsed.Fragment = ""
	parsed.Path = strings.TrimSuffix(strings.TrimRight(parsed.Path, "/"), apiPrefix)
	parsed.Path = joinURLPath(parsed.Path, apiPrefix, relative.Path)
	return parsed.String(), nil
}

func (c *Client) readEvents(ctx context.Context) {
	defer c.readLoopWG.Done()
	defer func() {
		c.mu.Lock()
		c.wsConnected = false
		c.mu.Unlock()
		c.closeEvents()
	}()

	for {
		payload, opcode, err := c.readFrame()
		if err != nil {
			if !errors.Is(err, net.ErrClosed) && !errors.Is(err, io.EOF) {
				c.logger.Warn("gateway websocket read failed", "error", err)
			}
			return
		}

		switch opcode {
		case 0x1, 0x2:
			event := decodeEvent(payload)
			select {
			case c.events <- event:
			case <-ctx.Done():
				return
			}
		case 0x8:
			return
		case 0x9:
			if err := c.writeControlFrame(0xA, payload); err != nil {
				c.logger.Debug("failed to write websocket pong", "error", err)
				return
			}
		case 0xA:
			continue
		default:
			continue
		}
	}
}

func (c *Client) readFrame() ([]byte, byte, error) {
	c.mu.Lock()
	reader := c.wsReader
	c.mu.Unlock()
	if reader == nil {
		return nil, 0, net.ErrClosed
	}

	var message []byte
	var firstOpcode byte
	for {
		head1, err := reader.ReadByte()
		if err != nil {
			return nil, 0, err
		}
		head2, err := reader.ReadByte()
		if err != nil {
			return nil, 0, err
		}

		fin := head1&0x80 != 0
		opcode := head1 & 0x0F
		masked := head2&0x80 != 0
		payloadLen := int64(head2 & 0x7F)
		if payloadLen == 126 {
			var extended [2]byte
			if _, err := io.ReadFull(reader, extended[:]); err != nil {
				return nil, 0, err
			}
			payloadLen = int64(extended[0])<<8 | int64(extended[1])
		} else if payloadLen == 127 {
			var extended [8]byte
			if _, err := io.ReadFull(reader, extended[:]); err != nil {
				return nil, 0, err
			}
			payloadLen = 0
			for _, b := range extended {
				payloadLen = (payloadLen << 8) | int64(b)
			}
		}

		var maskKey [4]byte
		if masked {
			if _, err := io.ReadFull(reader, maskKey[:]); err != nil {
				return nil, 0, err
			}
		}

		payload := make([]byte, payloadLen)
		if _, err := io.ReadFull(reader, payload); err != nil {
			return nil, 0, err
		}
		if masked {
			for i := range payload {
				payload[i] ^= maskKey[i%4]
			}
		}

		if opcode == 0x0 {
			opcode = firstOpcode
		} else if firstOpcode == 0 {
			firstOpcode = opcode
		}

		message = append(message, payload...)
		if fin {
			return message, firstOpcode, nil
		}
	}
}

func (c *Client) writeControlFrame(opcode byte, payload []byte) error {
	c.mu.Lock()
	conn := c.wsConn
	c.mu.Unlock()
	if conn == nil {
		return net.ErrClosed
	}
	frame, err := buildClientFrame(opcode, payload)
	if err != nil {
		return err
	}
	_, err = conn.Write(frame)
	return err
}

func (c *Client) closeEvents() {
	c.eventsOnce.Do(func() {
		close(c.events)
	})
}

func marshalRequestBody(body any) ([]byte, string, error) {
	if body == nil {
		return nil, "", nil
	}
	switch value := body.(type) {
	case []byte:
		return append([]byte(nil), value...), "application/json", nil
	case json.RawMessage:
		return append([]byte(nil), value...), "application/json", nil
	case io.Reader:
		data, err := io.ReadAll(io.LimitReader(value, maxJSONResponseSize))
		if err != nil {
			return nil, "", fmt.Errorf("read request body: %w", err)
		}
		return data, "application/json", nil
	default:
		payload, err := json.Marshal(body)
		if err != nil {
			return nil, "", fmt.Errorf("marshal request body: %w", err)
		}
		return payload, "application/json", nil
	}
}

func readAPIError(resp *http.Response) *APIError {
	defer resp.Body.Close()
	return &APIError{
		StatusCode: resp.StatusCode,
		Message:    extractErrorMessage(io.LimitReader(resp.Body, 1<<20)),
	}
}

func extractErrorMessage(r io.Reader) string {
	data, err := io.ReadAll(r)
	if err != nil {
		return fmt.Sprintf("read error body: %v", err)
	}
	trimmed := strings.TrimSpace(string(data))
	if trimmed == "" {
		return ""
	}

	var envelope map[string]json.RawMessage
	if json.Unmarshal([]byte(trimmed), &envelope) == nil {
		for _, key := range []string{"message", "error", "detail"} {
			if raw, ok := envelope[key]; ok {
				var value string
				if json.Unmarshal(raw, &value) == nil && strings.TrimSpace(value) != "" {
					return strings.TrimSpace(value)
				}
			}
		}
	}
	return trimmed
}

func unwrapArrayDocument(data []byte) ([]json.RawMessage, error) {
	trimmed := strings.TrimSpace(string(data))
	if trimmed == "" {
		return []json.RawMessage{}, nil
	}

	var direct []json.RawMessage
	if err := json.Unmarshal([]byte(trimmed), &direct); err == nil {
		return direct, nil
	}

	var envelope map[string]json.RawMessage
	if err := json.Unmarshal([]byte(trimmed), &envelope); err != nil {
		return nil, fmt.Errorf("decode array response: %w", err)
	}
	for _, key := range []string{"assets", "tasks", "items", "results", "data"} {
		if raw, ok := envelope[key]; ok {
			if err := json.Unmarshal(raw, &direct); err == nil {
				return direct, nil
			}
		}
	}
	return nil, errors.New("response does not contain a JSON array")
}

func unwrapObjectDocument(data []byte) json.RawMessage {
	trimmed := strings.TrimSpace(string(data))
	if trimmed == "" {
		return json.RawMessage(`null`)
	}

	var envelope map[string]json.RawMessage
	if json.Unmarshal([]byte(trimmed), &envelope) != nil {
		return append(json.RawMessage(nil), []byte(trimmed)...)
	}
	for _, key := range []string{"asset", "task", "plan", "validation", "data", "result"} {
		if raw, ok := envelope[key]; ok && len(strings.TrimSpace(string(raw))) > 0 {
			return append(json.RawMessage(nil), raw...)
		}
	}
	return append(json.RawMessage(nil), []byte(trimmed)...)
}

func joinURLPath(parts ...string) string {
	segments := make([]string, 0, len(parts))
	for _, part := range parts {
		for _, segment := range strings.Split(part, "/") {
			segment = strings.TrimSpace(segment)
			if segment == "" {
				continue
			}
			segments = append(segments, segment)
		}
	}
	if len(segments) == 0 {
		return "/"
	}
	return "/" + strings.Join(segments, "/")
}

func cloneStringMap(values map[string]string) map[string]string {
	if len(values) == 0 {
		return map[string]string{}
	}
	cloned := make(map[string]string, len(values))
	for key, value := range values {
		cloned[key] = value
	}
	return cloned
}

func parseInt64(value string) int64 {
	parsed, err := strconv.ParseInt(strings.TrimSpace(value), 10, 64)
	if err != nil {
		return -1
	}
	return parsed
}

func trimETag(value string) string {
	value = strings.TrimSpace(value)
	value = strings.TrimPrefix(value, "W/")
	return strings.Trim(value, `"`)
}

func normalizeChecksum(value string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return ""
	}
	if strings.Contains(value, "=") && strings.HasPrefix(strings.ToLower(value), "sha-256=") {
		return ""
	}
	value = strings.TrimPrefix(strings.ToLower(value), "sha256:")
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

func dialWebSocket(ctx context.Context, endpoint *url.URL) (net.Conn, error) {
	hostPort := endpoint.Host
	if endpoint.Port() == "" {
		switch endpoint.Scheme {
		case "wss":
			hostPort = net.JoinHostPort(endpoint.Hostname(), "443")
		default:
			hostPort = net.JoinHostPort(endpoint.Hostname(), "80")
		}
	}

	dialer := &net.Dialer{Timeout: 10 * time.Second, KeepAlive: 30 * time.Second}
	switch endpoint.Scheme {
	case "ws":
		return dialer.DialContext(ctx, "tcp", hostPort)
	case "wss":
		return tls.DialWithDialer(dialer, "tcp", hostPort, &tls.Config{ServerName: endpoint.Hostname()})
	default:
		return nil, fmt.Errorf("unsupported websocket scheme %q", endpoint.Scheme)
	}
}

func randomWebSocketKey() (string, error) {
	buf := make([]byte, 16)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(buf), nil
}

func websocketAcceptKey(secKey string) string {
	hasher := sha1.New()
	_, _ = io.WriteString(hasher, secKey)
	_, _ = io.WriteString(hasher, wsGUID)
	return base64.StdEncoding.EncodeToString(hasher.Sum(nil))
}

func hostHeader(endpoint *url.URL) string {
	host := endpoint.Hostname()
	port := endpoint.Port()
	if port == "" {
		return endpoint.Host
	}
	if (endpoint.Scheme == "ws" && port == "80") || (endpoint.Scheme == "wss" && port == "443") {
		if strings.Contains(host, ":") {
			return "[" + host + "]"
		}
		return host
	}
	return net.JoinHostPort(host, port)
}

func buildClientFrame(opcode byte, payload []byte) ([]byte, error) {
	maskingKey := make([]byte, 4)
	if _, err := rand.Read(maskingKey); err != nil {
		return nil, fmt.Errorf("generate websocket mask: %w", err)
	}

	encoded := append([]byte(nil), payload...)
	for i := range encoded {
		encoded[i] ^= maskingKey[i%4]
	}

	frame := []byte{0x80 | opcode}
	length := len(encoded)
	switch {
	case length < 126:
		frame = append(frame, 0x80|byte(length))
	case length <= 0xFFFF:
		frame = append(frame, 0x80|126, byte(length>>8), byte(length))
	default:
		frame = append(frame, 0x80|127,
			byte(length>>56), byte(length>>48), byte(length>>40), byte(length>>32),
			byte(length>>24), byte(length>>16), byte(length>>8), byte(length),
		)
	}
	frame = append(frame, maskingKey...)
	frame = append(frame, encoded...)
	return frame, nil
}

func decodeEvent(payload []byte) Event {
	trimmed := strings.TrimSpace(string(payload))
	event := Event{
		Type:    "message",
		Payload: append(json.RawMessage(nil), []byte(trimmed)...),
	}
	if trimmed == "" {
		event.Payload = json.RawMessage(`null`)
		return event
	}

	var envelope map[string]json.RawMessage
	if json.Unmarshal([]byte(trimmed), &envelope) != nil {
		return event
	}
	if raw, ok := envelope["type"]; ok {
		var value string
		if json.Unmarshal(raw, &value) == nil && strings.TrimSpace(value) != "" {
			event.Type = strings.TrimSpace(value)
		}
	}
	if event.Type == "message" {
		for _, key := range []string{"event", "method"} {
			if raw, ok := envelope[key]; ok {
				var value string
				if json.Unmarshal(raw, &value) == nil && strings.TrimSpace(value) != "" {
					event.Type = strings.TrimSpace(value)
					break
				}
			}
		}
	}
	for _, key := range []string{"payload", "data", "params", "result"} {
		if raw, ok := envelope[key]; ok {
			event.Payload = append(event.Payload[:0], raw...)
			return event
		}
	}
	return event
}
