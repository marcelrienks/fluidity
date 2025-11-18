package server

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"sync"
	"time"

	"fluidity/internal/core/server/metrics"
	"fluidity/internal/shared/circuitbreaker"
	"fluidity/internal/shared/logging"
	"fluidity/internal/shared/protocol"
	"fluidity/internal/shared/retry"
	tlsutil "fluidity/internal/shared/tls"

	"github.com/gorilla/websocket"
)

// Server handles mTLS connections from agents
type Server struct {
	listener       net.Listener
	httpClient     *http.Client
	circuitBreaker *circuitbreaker.CircuitBreaker
	retryConfig    retry.Config
	metricsEmitter *metrics.Emitter
	logger         *logging.Logger
	ctx            context.Context
	cancel         context.CancelFunc
	wg             sync.WaitGroup
	maxConns       int
	activeConns    int32
	connMutex      sync.RWMutex
	tcpConns       map[string]net.Conn
	tcpMutex       sync.RWMutex
	wsConns        map[string]*websocket.Conn
	wsMutex        sync.RWMutex
	startTime      time.Time
}

// NewServer creates a new tunnel server
func NewServer(tlsConfig *tls.Config, addr string, maxConns int, logLevel string) (*Server, error) {
	listener, err := tls.Listen("tcp", addr, tlsConfig)
	if err != nil {
		return nil, fmt.Errorf("failed to create listener: %w", err)
	}

	// HTTP client for making requests to target websites
	httpClient := &http.Client{
		Timeout: 30 * time.Second,
		Transport: &http.Transport{
			MaxIdleConns:        100,
			MaxIdleConnsPerHost: 10,
			IdleConnTimeout:     90 * time.Second,
			TLSHandshakeTimeout: 10 * time.Second,
		},
	}

	ctx, cancel := context.WithCancel(context.Background())

	logger := logging.NewLogger("tunnel-server")
	logger.SetLevel(logLevel)

	// Initialize circuit breaker for external requests
	cbConfig := circuitbreaker.DefaultConfig()
	cb := circuitbreaker.New(cbConfig)

	// Initialize retry configuration
	retryConfig := retry.Config{
		MaxAttempts:  3,
		InitialDelay: 500 * time.Millisecond,
		MaxDelay:     5 * time.Second,
		Multiplier:   2.0,
	}

	// Initialize metrics emitter (optional - gracefully disabled if not configured)
	metricsConfig, err := metrics.LoadConfig()
	if err != nil {
		logger.Warn("Failed to load metrics configuration", "error", err.Error())
		metricsConfig = &metrics.Config{Enabled: false}
	}

	metricsEmitter, err := metrics.NewEmitter(metricsConfig, logger)
	if err != nil {
		logger.Warn("Failed to create metrics emitter", "error", err.Error())
	}

	return &Server{
		listener:       listener,
		httpClient:     httpClient,
		circuitBreaker: cb,
		retryConfig:    retryConfig,
		metricsEmitter: metricsEmitter,
		logger:         logger,
		ctx:            ctx,
		cancel:         cancel,
		maxConns:       maxConns,
		tcpConns:       make(map[string]net.Conn),
		wsConns:        make(map[string]*websocket.Conn),
		startTime:      time.Now(),
	}, nil
}

// Start begins accepting connections
func (s *Server) Start() error {
	s.logger.Info("Tunnel server starting", "addr", s.listener.Addr())

	// Start metrics emitter
	if s.metricsEmitter != nil {
		s.metricsEmitter.Start()
	}

	for {
		select {
		case <-s.ctx.Done():
			return nil
		default:
		}

		conn, err := s.listener.Accept()
		if err != nil {
			select {
			case <-s.ctx.Done():
				return nil
			default:
				s.logger.Error("Failed to accept connection", err)
				continue
			}
		}

		// Check connection limit
		s.connMutex.RLock()
		if int(s.activeConns) >= s.maxConns {
			s.connMutex.RUnlock()
			s.logger.Warn("Maximum connections reached, rejecting new connection")
			conn.Close()
			continue
		}
		s.connMutex.RUnlock()

		// Handle each connection in a goroutine
		s.wg.Add(1)
		go s.handleConnection(conn.(*tls.Conn))
	}
}

// Stop gracefully shuts down the server
func (s *Server) Stop() error {
	s.logger.Info("Stopping tunnel server")
	s.cancel()

	// Stop metrics emitter
	if s.metricsEmitter != nil {
		s.metricsEmitter.Stop()
	}

	if s.listener != nil {
		s.listener.Close()
	}

	// Wait for all connections to close
	done := make(chan struct{})
	go func() {
		s.wg.Wait()
		close(done)
	}()

	select {
	case <-done:
	case <-time.After(10 * time.Second):
		s.logger.Warn("Timeout waiting for connections to close")
	}

	return nil
}

// HealthStatus represents the health check response
type HealthStatus struct {
	Status             string  `json:"status"`
	ActiveConnections  int32   `json:"active_connections"`
	UptimeSeconds      int64   `json:"uptime_seconds"`
	MaxConnections     int     `json:"max_connections"`
	ConnectionsPercent float64 `json:"connections_percent"`
}

// GetHealth returns the health status of the server
func (s *Server) GetHealth() HealthStatus {
	s.connMutex.RLock()
	activeConns := s.activeConns
	s.connMutex.RUnlock()

	uptime := int64(time.Since(s.startTime).Seconds())
	connPercent := 0.0
	if s.maxConns > 0 {
		connPercent = (float64(activeConns) / float64(s.maxConns)) * 100
	}

	return HealthStatus{
		Status:             "healthy",
		ActiveConnections:  activeConns,
		UptimeSeconds:      uptime,
		MaxConnections:     s.maxConns,
		ConnectionsPercent: connPercent,
	}
}

// handleConnection processes requests from a single agent
func (s *Server) handleConnection(conn *tls.Conn) {
	defer func() {
		conn.Close()
		s.wg.Done()

		s.connMutex.Lock()
		s.activeConns--
		s.connMutex.Unlock()

		// Decrement metrics
		if s.metricsEmitter != nil {
			s.metricsEmitter.DecrementConnections()
		}
	}()

	s.connMutex.Lock()
	s.activeConns++
	s.connMutex.Unlock()

	// Increment metrics
	if s.metricsEmitter != nil {
		s.metricsEmitter.IncrementConnections()
	}

	// Complete the TLS handshake before inspecting connection state
	if err := conn.Handshake(); err != nil {
		s.logger.Error("TLS handshake failed", err)
		return
	}

	// Verify client certificate (after handshake)
	state := conn.ConnectionState()
	if len(state.PeerCertificates) == 0 {
		s.logger.Warn("Client connected without certificate")
		return
	}

	clientCert := state.PeerCertificates[0]
	clientInfo := tlsutil.GetCertificateInfo(clientCert)
	s.logger.Info("Client connected", "client", clientCert.Subject.CommonName, "cert_info", clientInfo)

	decoder := json.NewDecoder(conn)
	encoder := json.NewEncoder(conn)

	// Mutex to protect concurrent writes to encoder
	var encoderMutex sync.Mutex

	for {
		select {
		case <-s.ctx.Done():
			return
		default:
		}

		var env protocol.Envelope
		if err := decoder.Decode(&env); err != nil {
			if err != io.EOF {
				s.logger.Error("Failed to decode envelope", err)
			}
			break
		}

		switch env.Type {
		case "iam_auth_request":
			m, _ := env.Payload.(map[string]any)
			b, _ := json.Marshal(m)
			var authReq protocol.IAMAuthRequest
			if err := json.Unmarshal(b, &authReq); err != nil {
				s.logger.Error("Failed to parse iam_auth_request", err)
				continue
			}
			s.handleIAMAuth(&authReq, encoder, &encoderMutex)

		case "http_request":
			m, _ := env.Payload.(map[string]any)
			b, _ := json.Marshal(m)
			var req protocol.Request
			if err := json.Unmarshal(b, &req); err != nil {
				s.logger.Error("Failed to parse http_request", err)
				continue
			}
			// Process request in a goroutine to handle concurrent requests
			go s.processRequest(&req, encoder, &encoderMutex)

		case "connect_open":
			m, _ := env.Payload.(map[string]any)
			b, _ := json.Marshal(m)
			var open protocol.ConnectOpen
			if err := json.Unmarshal(b, &open); err != nil {
				s.logger.Error("Failed to parse connect_open", err)
				continue
			}
			go s.handleConnectOpen(&open, encoder, &encoderMutex)

		case "connect_data":
			m, _ := env.Payload.(map[string]any)
			b, _ := json.Marshal(m)
			var data protocol.ConnectData
			if err := json.Unmarshal(b, &data); err != nil {
				s.logger.Error("Failed to parse connect_data", err)
				continue
			}
			go s.handleConnectData(&data)

		case "connect_close":
			m, _ := env.Payload.(map[string]any)
			b, _ := json.Marshal(m)
			var cls protocol.ConnectClose
			if err := json.Unmarshal(b, &cls); err != nil {
				continue
			}
			go s.handleConnectClose(&cls)

		case "ws_open":
			m, _ := env.Payload.(map[string]any)
			b, _ := json.Marshal(m)
			var open protocol.WebSocketOpen
			if err := json.Unmarshal(b, &open); err != nil {
				s.logger.Error("Failed to parse ws_open", err)
				continue
			}
			go s.handleWebSocketOpen(&open, encoder, &encoderMutex)

		case "ws_message":
			m, _ := env.Payload.(map[string]any)
			b, _ := json.Marshal(m)
			var msg protocol.WebSocketMessage
			if err := json.Unmarshal(b, &msg); err != nil {
				s.logger.Error("Failed to parse ws_message", err)
				continue
			}
			go s.handleWebSocketMessage(&msg)

		case "ws_close":
			m, _ := env.Payload.(map[string]any)
			b, _ := json.Marshal(m)
			var cls protocol.WebSocketClose
			if err := json.Unmarshal(b, &cls); err != nil {
				continue
			}
			go s.handleWebSocketClose(&cls)

		default:
			// Ignore unknown message types
		}
	}

	s.logger.Info("Client disconnected", "client", clientCert.Subject.CommonName)
}

// processRequest handles a single HTTP request with circuit breaker and retry logic
func (s *Server) processRequest(req *protocol.Request, encoder *json.Encoder, mu *sync.Mutex) {
	s.logger.Debug("Processing request", "id", req.ID, "method", req.Method, "url", req.URL)

	// Update last activity timestamp
	if s.metricsEmitter != nil {
		s.metricsEmitter.UpdateLastActivity()
	}

	// Log the target endpoint (domain only)
	s.logRequest(req)

	// Execute request with circuit breaker and retry logic
	err := s.circuitBreaker.Execute(func() error {
		return s.executeRequestWithRetry(req, encoder, mu)
	})

	if err != nil {
		// Check if circuit is open
		if err == circuitbreaker.ErrCircuitOpen {
			s.logger.Warn("Circuit breaker is open, rejecting request", "id", req.ID)
			s.sendErrorResponse(req.ID, fmt.Errorf("service temporarily unavailable (circuit open)"), encoder, mu)
		}
		// Other errors already handled by executeRequestWithRetry
	}
}

// executeRequestWithRetry executes a single HTTP request with retry logic
func (s *Server) executeRequestWithRetry(req *protocol.Request, encoder *json.Encoder, mu *sync.Mutex) error {
	// Define shouldRetry function for network errors
	shouldRetry := func(err error) bool {
		// Retry on network errors or temporary failures
		if urlErr, ok := err.(*url.Error); ok {
			// Retry on timeout or temporary errors
			if urlErr.Timeout() || urlErr.Temporary() {
				return true
			}
		}
		// Don't retry on other errors
		return false
	}

	var httpResp *http.Response
	var body []byte

	// Execute with retry
	err := retry.Execute(s.ctx, s.retryConfig, shouldRetry, func() error {
		// Create HTTP request
		httpReq, err := http.NewRequestWithContext(s.ctx, req.Method, req.URL, bytes.NewReader(req.Body))
		if err != nil {
			return err
		}

		// Set headers
		for name, values := range req.Headers {
			for _, value := range values {
				httpReq.Header.Add(name, value)
			}
		}

		// Make request
		resp, err := s.httpClient.Do(httpReq)
		if err != nil {
			s.logger.Debug("Request failed, will retry if applicable", "id", req.ID, "error", err)
			return err
		}

		httpResp = resp
		return nil
	})

	if err != nil {
		s.sendErrorResponse(req.ID, err, encoder, mu)
		return err
	}

	defer httpResp.Body.Close()

	// Read response body
	body, err = io.ReadAll(httpResp.Body)
	if err != nil {
		s.sendErrorResponse(req.ID, err, encoder, mu)
		return err
	}

	// Send response back through tunnel wrapped in Envelope
	resp := &protocol.Response{
		ID:         req.ID,
		StatusCode: httpResp.StatusCode,
		Headers:    convertHeaders(httpResp.Header),
		Body:       body,
	}

	env := protocol.Envelope{Type: "http_response", Payload: resp}
	mu.Lock()
	encodeErr := encoder.Encode(env)
	mu.Unlock()
	if encodeErr != nil {
		s.logger.Error("Failed to send response", encodeErr, "id", req.ID)
		return encodeErr
	}

	s.logger.Debug("Response sent", "id", req.ID, "status", httpResp.StatusCode, "size", len(body))
	return nil
}

// sendErrorResponse sends an error response back to the client
func (s *Server) sendErrorResponse(reqID string, err error, encoder *json.Encoder, mu *sync.Mutex) {
	s.logger.Error("Request processing failed", err, "id", reqID)

	resp := &protocol.Response{
		ID:         reqID,
		StatusCode: 502,
		Headers:    map[string][]string{"Content-Type": {"text/plain"}},
		Body:       []byte(fmt.Sprintf("Tunnel error: %v", err)),
		Error:      err.Error(),
	}

	env := protocol.Envelope{Type: "http_response", Payload: resp}
	mu.Lock()
	encodeErr := encoder.Encode(env)
	mu.Unlock()
	if encodeErr != nil {
		s.logger.Error("Failed to send error response", encodeErr, "id", reqID)
	}
}

// convertHeaders converts http.Header to protocol headers format
func convertHeaders(headers http.Header) map[string][]string {
	result := make(map[string][]string)
	for name, values := range headers {
		result[name] = values
	}
	return result
}

// logRequest logs request information (domain only for privacy)
func (s *Server) logRequest(req *protocol.Request) {
	if parsedURL, err := parseURL(req.URL); err == nil {
		domain := parsedURL.Host

		// Remove port from domain for cleaner logging
		if host, _, err := net.SplitHostPort(domain); err == nil {
			domain = host
		}

		s.logger.Info("Forwarding request", "method", req.Method, "domain", domain, "id", req.ID)
	} else {
		s.logger.Warn("Invalid URL in request", "url", req.URL, "id", req.ID)
	}
}

// parseURL is a helper function to parse URLs safely
func parseURL(rawURL string) (*url.URL, error) {
	return url.Parse(rawURL)
}

// handleConnectOpen opens a TCP connection to the target address
func (s *Server) handleConnectOpen(open *protocol.ConnectOpen, encoder *json.Encoder, mu *sync.Mutex) {
	s.logger.Info("CONNECT open request", "id", open.ID, "address", open.Address)

	// Create context with timeout for dial
	dialCtx, dialCancel := context.WithTimeout(s.ctx, 10*time.Second)
	defer dialCancel()

	// Dial target with context
	var dialer net.Dialer
	targetConn, err := dialer.DialContext(dialCtx, "tcp", open.Address)
	if err != nil {
		s.logger.Error("CONNECT dial failed", err, "id", open.ID, "address", open.Address)
		// Send error via connect_close
		errMsg := err.Error()
		if dialCtx.Err() == context.DeadlineExceeded {
			errMsg = "connection timeout"
		}
		env := protocol.Envelope{Type: "connect_close", Payload: &protocol.ConnectClose{ID: open.ID, Error: errMsg}}
		mu.Lock()
		_ = encoder.Encode(env)
		mu.Unlock()
		return
	}

	s.logger.Debug("CONNECT dial successful", "id", open.ID, "address", open.Address)

	// Store connection
	s.tcpMutex.Lock()
	s.tcpConns[open.ID] = targetConn
	s.tcpMutex.Unlock()

	// Send ack
	env := protocol.Envelope{Type: "connect_ack", Payload: &protocol.ConnectAck{ID: open.ID, Ok: true}}
	mu.Lock()
	encErr := encoder.Encode(env)
	mu.Unlock()
	if encErr != nil {
		s.logger.Error("Failed to send connect_ack", encErr, "id", open.ID)
		return
	}
	s.logger.Debug("Sent connect_ack", "id", open.ID)

	// Start reader goroutine: read from target and send to agent
	go func() {
		defer func() {
			s.logger.Debug("CONNECT reader goroutine exiting", "id", open.ID)
			s.tcpMutex.Lock()
			delete(s.tcpConns, open.ID)
			s.tcpMutex.Unlock()
			targetConn.Close()
			// Send close
			closeEnv := protocol.Envelope{Type: "connect_close", Payload: &protocol.ConnectClose{ID: open.ID}}
			mu.Lock()
			_ = encoder.Encode(closeEnv)
			mu.Unlock()
		}()

		s.logger.Debug("CONNECT reader goroutine started", "id", open.ID)
		buf := make([]byte, 32*1024)

		// Set read deadline to detect stale connections
		targetConn.SetReadDeadline(time.Now().Add(5 * time.Minute))

		for {
			select {
			case <-s.ctx.Done():
				s.logger.Debug("CONNECT reader context cancelled", "id", open.ID)
				return
			default:
			}

			n, err := targetConn.Read(buf)
			if n > 0 {
				s.logger.Debug("CONNECT read data from target", "id", open.ID, "bytes", n)

				// Reset read deadline on successful read
				targetConn.SetReadDeadline(time.Now().Add(5 * time.Minute))

				dataEnv := protocol.Envelope{Type: "connect_data", Payload: &protocol.ConnectData{ID: open.ID, Chunk: buf[:n]}}
				mu.Lock()
				encErr := encoder.Encode(dataEnv)
				mu.Unlock()
				if encErr != nil {
					s.logger.Error("Failed to send connect_data", encErr, "id", open.ID)
					return
				}
				s.logger.Debug("CONNECT sent data to agent", "id", open.ID, "bytes", n)
			}
			if err != nil {
				if err != io.EOF {
					// Check if it's a timeout error
					if netErr, ok := err.(net.Error); ok && netErr.Timeout() {
						s.logger.Debug("CONNECT read timeout, connection idle", "id", open.ID)
					} else {
						s.logger.Debug("CONNECT read error from target", "id", open.ID, "error", err)
					}
				}
				return
			}
		}
	}()
}

// handleConnectData writes data to the TCP connection
func (s *Server) handleConnectData(data *protocol.ConnectData) {
	s.tcpMutex.RLock()
	targetConn := s.tcpConns[data.ID]
	s.tcpMutex.RUnlock()

	if targetConn == nil {
		s.logger.Debug("CONNECT data received for unknown connection", "id", data.ID)
		return
	}

	s.logger.Debug("CONNECT writing data to target", "id", data.ID, "bytes", len(data.Chunk))
	if _, err := targetConn.Write(data.Chunk); err != nil {
		s.logger.Error("Failed to write to target conn", err, "id", data.ID)
		s.handleConnectClose(&protocol.ConnectClose{ID: data.ID})
	} else {
		s.logger.Debug("CONNECT wrote data to target", "id", data.ID, "bytes", len(data.Chunk))
	}
}

// handleConnectClose closes the TCP connection
func (s *Server) handleConnectClose(cls *protocol.ConnectClose) {
	s.tcpMutex.Lock()
	targetConn := s.tcpConns[cls.ID]
	delete(s.tcpConns, cls.ID)
	s.tcpMutex.Unlock()

	if targetConn != nil {
		targetConn.Close()
	}
}

// handleWebSocketOpen establishes a WebSocket connection to the target
func (s *Server) handleWebSocketOpen(open *protocol.WebSocketOpen, encoder *json.Encoder, mu *sync.Mutex) {
	s.logger.Info("WebSocket open request", "id", open.ID, "url", open.URL)

	// Create WebSocket dialer
	dialer := websocket.Dialer{
		HandshakeTimeout: 10 * time.Second,
		TLSClientConfig: &tls.Config{
			InsecureSkipVerify: false, // We should verify in production
		},
	}

	// Convert headers
	headers := http.Header{}
	for name, values := range open.Headers {
		for _, value := range values {
			headers.Add(name, value)
		}
	}

	// Dial the WebSocket
	wsConn, _, err := dialer.Dial(open.URL, headers)
	if err != nil {
		s.logger.Error("WebSocket dial failed", err, "id", open.ID, "url", open.URL)
		// Send error via ws_close
		env := protocol.Envelope{Type: "ws_close", Payload: &protocol.WebSocketClose{ID: open.ID, Code: websocket.CloseInternalServerErr, Error: err.Error()}}
		mu.Lock()
		_ = encoder.Encode(env)
		mu.Unlock()
		return
	}

	s.logger.Debug("WebSocket dial successful", "id", open.ID, "url", open.URL)

	// Store connection
	s.wsMutex.Lock()
	s.wsConns[open.ID] = wsConn
	s.wsMutex.Unlock()

	// Send ack
	env := protocol.Envelope{Type: "ws_ack", Payload: &protocol.WebSocketAck{ID: open.ID, Ok: true}}
	mu.Lock()
	encErr := encoder.Encode(env)
	mu.Unlock()
	if encErr != nil {
		s.logger.Error("Failed to send ws_ack", encErr, "id", open.ID)
		wsConn.Close()
		s.wsMutex.Lock()
		delete(s.wsConns, open.ID)
		s.wsMutex.Unlock()
		return
	}
	s.logger.Debug("Sent ws_ack", "id", open.ID)

	// Start reader goroutine: read from target WebSocket and send to agent
	go func() {
		defer func() {
			s.logger.Debug("WebSocket reader goroutine exiting", "id", open.ID)
			s.wsMutex.Lock()
			delete(s.wsConns, open.ID)
			s.wsMutex.Unlock()
			wsConn.Close()
			// Send close
			closeEnv := protocol.Envelope{Type: "ws_close", Payload: &protocol.WebSocketClose{ID: open.ID}}
			mu.Lock()
			_ = encoder.Encode(closeEnv)
			mu.Unlock()
		}()

		s.logger.Debug("WebSocket reader goroutine started", "id", open.ID)
		for {
			messageType, data, err := wsConn.ReadMessage()
			if err != nil {
				if websocket.IsUnexpectedCloseError(err, websocket.CloseGoingAway, websocket.CloseNormalClosure) {
					s.logger.Error("WebSocket read error", err, "id", open.ID)
				}
				return
			}

			s.logger.Debug("WebSocket read message from target", "id", open.ID, "type", messageType, "bytes", len(data))
			msgEnv := protocol.Envelope{Type: "ws_message", Payload: &protocol.WebSocketMessage{
				ID:          open.ID,
				MessageType: messageType,
				Data:        data,
			}}
			mu.Lock()
			encErr := encoder.Encode(msgEnv)
			mu.Unlock()
			if encErr != nil {
				s.logger.Error("Failed to send ws_message", encErr, "id", open.ID)
				return
			}
			s.logger.Debug("WebSocket sent message to agent", "id", open.ID, "type", messageType, "bytes", len(data))
		}
	}()
}

// handleWebSocketMessage writes a message to the target WebSocket
func (s *Server) handleWebSocketMessage(msg *protocol.WebSocketMessage) {
	s.wsMutex.RLock()
	wsConn := s.wsConns[msg.ID]
	s.wsMutex.RUnlock()

	if wsConn == nil {
		s.logger.Debug("WebSocket message received for unknown connection", "id", msg.ID)
		return
	}

	s.logger.Debug("WebSocket writing message to target", "id", msg.ID, "type", msg.MessageType, "bytes", len(msg.Data))
	if err := wsConn.WriteMessage(msg.MessageType, msg.Data); err != nil {
		s.logger.Error("Failed to write to target WebSocket", err, "id", msg.ID)
		s.handleWebSocketClose(&protocol.WebSocketClose{ID: msg.ID})
	} else {
		s.logger.Debug("WebSocket wrote message to target", "id", msg.ID, "type", msg.MessageType, "bytes", len(msg.Data))
	}
}

// handleWebSocketClose closes the WebSocket connection
func (s *Server) handleWebSocketClose(cls *protocol.WebSocketClose) {
	s.wsMutex.Lock()
	wsConn := s.wsConns[cls.ID]
	delete(s.wsConns, cls.ID)
	s.wsMutex.Unlock()

	if wsConn != nil {
		// Send close message to target if code is specified
		if cls.Code != 0 {
			closeMsg := websocket.FormatCloseMessage(cls.Code, cls.Error)
			wsConn.WriteMessage(websocket.CloseMessage, closeMsg)
		}
		wsConn.Close()
		s.logger.Debug("WebSocket connection closed", "id", cls.ID)
	}
}

// handleIAMAuth processes IAM authentication requests from agents
func (s *Server) handleIAMAuth(authReq *protocol.IAMAuthRequest, encoder *json.Encoder, mu *sync.Mutex) {
	s.logger.Info("Processing IAM authentication request", "client", authReq.AccessKeyID)

	// For now, accept all IAM authentication requests
	// In production, you would validate the SigV4 signature here
	// This requires implementing SigV4 verification logic

	authResp := protocol.IAMAuthResponse{
		ID: authReq.ID,
		Ok: true,
	}

	// Send response
	mu.Lock()
	err := encoder.Encode(protocol.Envelope{
		Type:    "iam_auth_response",
		Payload: authResp,
	})
	mu.Unlock()

	if err != nil {
		s.logger.Error("Failed to send IAM auth response", err)
		return
	}

	s.logger.Info("IAM authentication successful", "client", authReq.AccessKeyID)
}
