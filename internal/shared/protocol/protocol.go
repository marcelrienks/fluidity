package protocol

import (
	"crypto/rand"
	"encoding/hex"
	"time"
)

// Request represents an HTTP request through the tunnel
type Request struct {
	ID      string              `json:"id"`
	Method  string              `json:"method"`
	URL     string              `json:"url"`
	Headers map[string][]string `json:"headers"`
	Body    []byte              `json:"body,omitempty"`
}

// Response represents an HTTP response through the tunnel
type Response struct {
	ID         string              `json:"id"`
	StatusCode int                 `json:"status_code"`
	Headers    map[string][]string `json:"headers"`
	Body       []byte              `json:"body,omitempty"`
	Error      string              `json:"error,omitempty"`
}

// ConnectionInfo represents tunnel connection metadata
type ConnectionInfo struct {
	ClientID    string    `json:"client_id"`
	ConnectedAt time.Time `json:"connected_at"`
	LastSeen    time.Time `json:"last_seen"`
}

// HealthCheck represents a health check message
type HealthCheck struct {
	Type      string    `json:"type"` // "ping" or "pong"
	Timestamp time.Time `json:"timestamp"`
	Message   string    `json:"message,omitempty"`
}

// Envelope wraps different message kinds for the tunnel
// Types: "http_request", "http_response", "connect_open", "connect_ack", "connect_data", "connect_close",
// "ws_open", "ws_ack", "ws_message", "ws_close", "iam_auth_request", "iam_auth_response"
type Envelope struct {
	Type    string `json:"type"`
	Payload any    `json:"payload"`
}

// ConnectOpen requests the server to open a TCP connection to Address (host:port)
type ConnectOpen struct {
	ID      string `json:"id"`
	Address string `json:"address"`
}

// ConnectAck acknowledges a ConnectOpen
type ConnectAck struct {
	ID    string `json:"id"`
	Ok    bool   `json:"ok"`
	Error string `json:"error,omitempty"`
}

// ConnectData carries a chunk of bytes for a TCP tunnel
type ConnectData struct {
	ID    string `json:"id"`
	Chunk []byte `json:"chunk"`
}

// ConnectClose signals closing a TCP tunnel
type ConnectClose struct {
	ID    string `json:"id"`
	Error string `json:"error,omitempty"`
}

// WebSocketOpen requests the server to establish a WebSocket connection
type WebSocketOpen struct {
	ID      string              `json:"id"`
	URL     string              `json:"url"`
	Headers map[string][]string `json:"headers"`
}

// WebSocketAck acknowledges a WebSocketOpen
type WebSocketAck struct {
	ID    string `json:"id"`
	Ok    bool   `json:"ok"`
	Error string `json:"error,omitempty"`
}

// WebSocketMessage carries a WebSocket message frame
type WebSocketMessage struct {
	ID          string `json:"id"`
	MessageType int    `json:"message_type"` // 1=TextMessage, 2=BinaryMessage, 8=CloseMessage, 9=PingMessage, 10=PongMessage
	Data        []byte `json:"data"`
}

// WebSocketClose signals closing a WebSocket connection
type WebSocketClose struct {
	ID    string `json:"id"`
	Code  int    `json:"code,omitempty"`
	Error string `json:"error,omitempty"`
}

// IAMAuthRequest represents an IAM authentication request
type IAMAuthRequest struct {
	ID            string    `json:"id"`
	Timestamp     time.Time `json:"timestamp"`
	Service       string    `json:"service"` // "lambda" or "tunnel"
	Region        string    `json:"region"`
	AccessKeyID   string    `json:"access_key_id"`
	Signature     string    `json:"signature"`
	SignedHeaders string    `json:"signed_headers"`
}

// IAMAuthResponse represents an IAM authentication response
type IAMAuthResponse struct {
	ID           string `json:"id"`
	Ok           bool   `json:"ok"`
	Error        string `json:"error,omitempty"`
	SessionToken string `json:"session_token,omitempty"` // For temporary credentials
}

// GenerateID generates a unique ID for requests and connections
func GenerateID() string {
	b := make([]byte, 16)
	rand.Read(b)
	return hex.EncodeToString(b)
}
