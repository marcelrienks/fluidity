package agent

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"time"

	"fluidity/internal/shared/logging"
	"fluidity/internal/shared/protocol"

	"github.com/gorilla/websocket"
)

// Server handles local HTTP proxy requests
type Server struct {
	port       int
	server     *http.Server
	tunnelConn *Client
	logger     *logging.Logger
	listener   net.Listener
	ctx        context.Context
	cancel     context.CancelFunc
	startTime  time.Time
}

// NewServer creates a new HTTP proxy server
func NewServer(port int, tunnelConn *Client, logLevel string) *Server {
	ctx, cancel := context.WithCancel(context.Background())

	logger := logging.NewLogger("proxy-server")
	logger.SetLevel(logLevel)

	proxy := &Server{
		port:       port,
		tunnelConn: tunnelConn,
		logger:     logger,
		ctx:        ctx,
		cancel:     cancel,
		startTime:  time.Now(),
	}

	proxy.server = &http.Server{
		Addr:         fmt.Sprintf(":%d", port),
		Handler:      proxy,
		ReadTimeout:  30 * time.Second,
		WriteTimeout: 30 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	return proxy
}

// Start begins serving HTTP proxy requests
func (p *Server) Start() error {

	listener, err := net.Listen("tcp", p.server.Addr)
	if err != nil {
		return fmt.Errorf("failed to start proxy server: %w", err)
	}

	go func() {
		if err := p.server.Serve(listener); err != nil && err != http.ErrServerClosed {
			p.logger.Error("Proxy server error", err)
		}
	}()

	p.logger.Info("HTTP proxy server started", "addr", p.server.Addr)
	return nil
}

// ServeHTTP implements http.Handler interface
func (p *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	p.handleRequest(w, r)
}

// Stop gracefully shuts down the proxy server
func (p *Server) Stop() error {
	p.logger.Info("Stopping HTTP proxy server")
	p.cancel()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	return p.server.Shutdown(ctx)
}

// HealthStatus represents the health check response
type ProxyHealthStatus struct {
	Status        string `json:"status"`
	Connected     bool   `json:"connected"`
	UptimeSeconds int64  `json:"uptime_seconds"`
	ProxyPort     int    `json:"proxy_port"`
	ServerAddr    string `json:"server_addr"`
}

// handleHealthCheck processes health check requests
func (p *Server) handleHealthCheck(w http.ResponseWriter, r *http.Request) {
	uptime := int64(time.Since(p.startTime).Seconds())

	health := ProxyHealthStatus{
		Status:        "healthy",
		Connected:     p.tunnelConn.IsConnected(),
		UptimeSeconds: uptime,
		ProxyPort:     p.port,
		ServerAddr:    p.tunnelConn.serverAddr,
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	if err := json.NewEncoder(w).Encode(health); err != nil {
		p.logger.Error("Failed to encode health check response", err)
	}
}

// handleRequest processes incoming HTTP requests
func (p *Server) handleRequest(w http.ResponseWriter, r *http.Request) {
	// Handle health check endpoint
	if r.URL.Path == "/health" && r.Method == "GET" {
		p.handleHealthCheck(w, r)
		return
	}

	// Log the request (domain only for privacy)
	p.logRequest(r)

	// Check if this is a WebSocket upgrade request
	if p.isWebSocketUpgrade(r) {
		p.handleWebSocket(w, r)
		return
	}

	// Handle CONNECT method for HTTPS tunneling
	if r.Method == "CONNECT" {
		p.handleConnect(w, r)
		return
	}

	// Handle regular HTTP requests
	p.handleHTTPRequest(w, r)
}

// handleHTTPRequest processes regular HTTP requests
func (p *Server) handleHTTPRequest(w http.ResponseWriter, r *http.Request) {
	// Generate request ID
	reqID := p.generateRequestID()

	// Check if tunnel is connected
	if !p.tunnelConn.IsConnected() {
		p.logger.Error("Failed to process HTTP request: tunnel not connected", nil, "id", reqID, "method", r.Method, "url", r.URL.String())
		http.Error(w, "Tunnel connection unavailable. Please ensure the tunnel server is running and try again.", http.StatusServiceUnavailable)
		return
	}

	p.logger.Debug("Processing HTTP request through tunnel", "id", reqID, "method", r.Method, "url", r.URL.String())

	// Ensure URL is absolute
	if !r.URL.IsAbs() {
		scheme := "http"
		if r.TLS != nil {
			scheme = "https"
		}
		r.URL.Scheme = scheme
		r.URL.Host = r.Host
	}

	// Read request body with size limit
	const maxBodySize = 10 * 1024 * 1024 // 10MB limit
	body, err := io.ReadAll(io.LimitReader(r.Body, maxBodySize))
	if err != nil {
		p.logger.Error("Failed to read request body", err, "id", reqID, "method", r.Method, "url", r.URL.String())
		http.Error(w, "Failed to read request body", http.StatusBadRequest)
		return
	}
	r.Body.Close()

	// Convert HTTP request to tunnel protocol
	tunnelReq := &protocol.Request{
		ID:      reqID,
		Method:  r.Method,
		URL:     r.URL.String(),
		Headers: convertHeaders(r.Header),
		Body:    body,
	}

	// Send through tunnel and get response
	resp, err := p.tunnelConn.SendRequest(tunnelReq)
	if err != nil {
		p.logger.Error("Failed to send request through tunnel", err, "id", reqID, "url", r.URL.String())

		// Provide more specific error message
		errorMsg := "Tunnel error: Unable to forward request"
		statusCode := http.StatusBadGateway

		if strings.Contains(err.Error(), "not connected") {
			errorMsg = "Tunnel connection lost. Attempting to reconnect..."
			statusCode = http.StatusServiceUnavailable
		} else if strings.Contains(err.Error(), "timeout") {
			errorMsg = "Request timeout: The server took too long to respond"
			statusCode = http.StatusGatewayTimeout
		}

		http.Error(w, errorMsg, statusCode)
		return
	}

	// Write response back to client
	p.writeResponse(w, resp)
}

// handleConnect handles HTTPS CONNECT requests for tunneling
func (p *Server) handleConnect(w http.ResponseWriter, r *http.Request) {
	// Establish a TCP tunnel via the server using our protocol
	reqID := p.generateRequestID()

	p.logger.Debug("CONNECT starting", "id", reqID, "host", r.Host)

	// Check if tunnel is connected
	if !p.tunnelConn.IsConnected() {
		p.logger.Error("Tunnel not connected for CONNECT", nil, "id", reqID, "host", r.Host)
		http.Error(w, "Tunnel connection unavailable", http.StatusServiceUnavailable)
		return
	}

	// Ask tunnel to open remote connection
	ack, err := p.tunnelConn.ConnectOpen(reqID, r.Host)
	if err != nil || !ack.Ok {
		if err == nil {
			err = fmt.Errorf(ack.Error)
		}
		p.logger.Error("CONNECT open failed", err, "host", r.Host, "id", reqID)

		// Provide more specific error message
		errorMsg := "Tunnel CONNECT failed"
		if strings.Contains(err.Error(), "timeout") {
			errorMsg = "Connection timeout"
		} else if strings.Contains(err.Error(), "refused") {
			errorMsg = "Connection refused by target"
		}

		http.Error(w, errorMsg, http.StatusBadGateway)
		return
	}

	p.logger.Debug("CONNECT opened successfully", "id", reqID)

	// Hijack client connection to get raw TCP
	hj, ok := w.(http.Hijacker)
	if !ok {
		p.logger.Error("Proxy does not support hijacking", nil, "id", reqID)
		http.Error(w, "Proxy does not support hijacking", http.StatusInternalServerError)
		return
	}
	clientConn, clientBuf, err := hj.Hijack()
	if err != nil {
		p.logger.Error("Hijack failed", err, "id", reqID)
		_ = p.tunnelConn.ConnectClose(reqID, "hijack failed")
		return
	}

	p.logger.Debug("CONNECT hijacked connection", "id", reqID)

	// Send 200 Connection established
	_, writeErr := clientBuf.WriteString("HTTP/1.1 200 Connection Established\r\n\r\n")
	if writeErr != nil {
		p.logger.Error("Failed to send 200 response", writeErr, "id", reqID)
		_ = p.tunnelConn.ConnectClose(reqID, "failed to send 200")
		clientConn.Close()
		return
	}

	if flushErr := clientBuf.Flush(); flushErr != nil {
		p.logger.Error("Failed to flush 200 response", flushErr, "id", reqID)
		_ = p.tunnelConn.ConnectClose(reqID, "failed to flush 200")
		clientConn.Close()
		return
	}

	p.logger.Debug("CONNECT sent 200 to client", "id", reqID)

	// Start pump: client->server
	go func() {
		defer func() {
			p.logger.Debug("CONNECT client->server pump exiting", "id", reqID)
			_ = p.tunnelConn.ConnectClose(reqID, "")
			clientConn.Close()
		}()
		p.logger.Debug("CONNECT client->server pump started", "id", reqID)
		buf := make([]byte, 32*1024)
		for {
			n, err := clientConn.Read(buf)
			if n > 0 {
				p.logger.Debug("CONNECT read from client", "id", reqID, "bytes", n)
				if sendErr := p.tunnelConn.ConnectSend(reqID, buf[:n]); sendErr != nil {
					p.logger.Error("CONNECT send error", sendErr, "id", reqID)
					return
				}
				p.logger.Debug("CONNECT sent to server", "id", reqID, "bytes", n)
			}
			if err != nil {
				if err != io.EOF {
					p.logger.Debug("CONNECT client read error", "id", reqID, "error", err)
				}
				return
			}
		}
	}()

	// Pump: server->client (main goroutine)
	p.logger.Debug("CONNECT server->client pump starting", "id", reqID)
	ch := p.tunnelConn.ConnectDataChannel(reqID)
	for msg := range ch {
		if msg.Chunk != nil && len(msg.Chunk) > 0 {
			p.logger.Debug("CONNECT received from server", "id", reqID, "bytes", len(msg.Chunk))
			if _, err := clientConn.Write(msg.Chunk); err != nil {
				p.logger.Error("CONNECT write to client failed", err, "id", reqID)
				return
			}
			p.logger.Debug("CONNECT wrote to client", "id", reqID, "bytes", len(msg.Chunk))
		}
	}
	p.logger.Debug("CONNECT server->client pump exiting", "id", reqID)
}

// writeResponse writes the tunnel response back to the HTTP client
func (p *Server) writeResponse(w http.ResponseWriter, resp *protocol.Response) {
	// Set headers
	for name, values := range resp.Headers {
		for _, value := range values {
			w.Header().Add(name, value)
		}
	}

	// Set status code
	w.WriteHeader(resp.StatusCode)

	// Write body
	if len(resp.Body) > 0 {
		w.Write(resp.Body)
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

// generateRequestID generates a unique request ID
func (p *Server) generateRequestID() string {
	bytes := make([]byte, 8)
	rand.Read(bytes)
	return fmt.Sprintf("%x", bytes)
}

// logRequest logs request information (domain only for privacy)
func (p *Server) logRequest(r *http.Request) {
	var domain string
	if r.URL != nil && r.URL.Host != "" {
		domain = r.URL.Host
	} else {
		domain = r.Host
	}

	// Remove port from domain for cleaner logging
	if host, _, err := net.SplitHostPort(domain); err == nil {
		domain = host
	}

	p.logger.Info("Proxying request", "method", r.Method, "domain", domain)
}

// isWebSocketUpgrade checks if the request is a WebSocket upgrade request
func (p *Server) isWebSocketUpgrade(r *http.Request) bool {
	return strings.ToLower(r.Header.Get("Upgrade")) == "websocket" &&
		strings.Contains(strings.ToLower(r.Header.Get("Connection")), "upgrade")
}

// handleWebSocket handles WebSocket upgrade requests and establishes a WebSocket tunnel
func (p *Server) handleWebSocket(w http.ResponseWriter, r *http.Request) {
	reqID := p.generateRequestID()

	p.logger.Info("WebSocket upgrade request", "id", reqID, "url", r.URL.String())

	// Ensure URL is absolute
	wsURL := r.URL.String()
	if !r.URL.IsAbs() {
		scheme := "ws"
		if r.TLS != nil {
			scheme = "wss"
		}
		wsURL = fmt.Sprintf("%s://%s%s", scheme, r.Host, r.URL.Path)
		if r.URL.RawQuery != "" {
			wsURL += "?" + r.URL.RawQuery
		}
	}

	// Request server to establish WebSocket connection
	wsOpen := &protocol.WebSocketOpen{
		ID:      reqID,
		URL:     wsURL,
		Headers: convertHeaders(r.Header),
	}

	ack, err := p.tunnelConn.WebSocketOpen(wsOpen)
	if err != nil || !ack.Ok {
		if err == nil {
			err = fmt.Errorf(ack.Error)
		}
		p.logger.Error("WebSocket open failed", err, "id", reqID)
		http.Error(w, "WebSocket tunnel error", http.StatusBadGateway)
		return
	}

	p.logger.Debug("WebSocket opened successfully on server", "id", reqID)

	// Upgrade client connection to WebSocket
	upgrader := websocket.Upgrader{
		CheckOrigin: func(r *http.Request) bool {
			return true // Accept all origins since we're a proxy
		},
	}

	clientWS, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		p.logger.Error("Failed to upgrade client connection", err, "id", reqID)
		_ = p.tunnelConn.WebSocketClose(reqID, websocket.CloseInternalServerErr, "upgrade failed")
		return
	}
	defer clientWS.Close()

	p.logger.Debug("Client WebSocket upgraded", "id", reqID)

	// Create channels for bidirectional communication
	clientToServer := make(chan *protocol.WebSocketMessage, 64)
	serverToClient := p.tunnelConn.WebSocketMessageChannel(reqID)
	done := make(chan struct{})

	// Goroutine: Read from client WebSocket and send to tunnel
	go func() {
		defer close(clientToServer)
		for {
			messageType, data, err := clientWS.ReadMessage()
			if err != nil {
				if websocket.IsUnexpectedCloseError(err, websocket.CloseGoingAway, websocket.CloseNormalClosure) {
					p.logger.Error("Client WebSocket read error", err, "id", reqID)
				}
				return
			}

			msg := &protocol.WebSocketMessage{
				ID:          reqID,
				MessageType: messageType,
				Data:        data,
			}

			select {
			case clientToServer <- msg:
			case <-done:
				return
			}
		}
	}()

	// Goroutine: Send client messages through tunnel
	go func() {
		for msg := range clientToServer {
			if err := p.tunnelConn.WebSocketSend(msg); err != nil {
				p.logger.Error("Failed to send WebSocket message through tunnel", err, "id", reqID)
				return
			}
		}
	}()

	// Main goroutine: Receive from tunnel and write to client WebSocket
	for {
		select {
		case msg, ok := <-serverToClient:
			if !ok {
				// Channel closed, connection terminated
				p.logger.Debug("Server WebSocket channel closed", "id", reqID)
				close(done)
				return
			}

			if err := clientWS.WriteMessage(msg.MessageType, msg.Data); err != nil {
				p.logger.Error("Failed to write to client WebSocket", err, "id", reqID)
				close(done)
				return
			}

		case <-p.ctx.Done():
			close(done)
			return
		}
	}
}
