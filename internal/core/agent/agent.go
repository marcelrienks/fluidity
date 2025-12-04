package agent

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"sync"
	"time"

	"fluidity/internal/shared/logging"
	"fluidity/internal/shared/protocol"
	"github.com/aws/aws-sdk-go-v2/aws"
	v4 "github.com/aws/aws-sdk-go-v2/aws/signer/v4"
	"github.com/aws/aws-sdk-go-v2/config"

	"github.com/sirupsen/logrus"
) // Client manages the tunnel connection to server
type Client struct {
	config      *tls.Config
	serverAddr  string
	conn        *tls.Conn
	mu          sync.RWMutex
	requests    map[string]chan *protocol.Response
	connectCh   map[string]chan *protocol.ConnectData
	connectAcks map[string]chan *protocol.ConnectAck
	wsCh        map[string]chan *protocol.WebSocketMessage
	wsAcks      map[string]chan *protocol.WebSocketAck
	logger      *logging.Logger
	ctx         context.Context
	cancel      context.CancelFunc
	connected   bool
	reconnectCh chan bool
	awsConfig   aws.Config
	signer      *v4.Signer
}

// NewClient creates a new tunnel client
func NewClient(tlsConfig *tls.Config, serverAddr string, logLevel string) *Client {
	return NewClientWithTestMode(tlsConfig, serverAddr, logLevel, false)
}

// NewClientWithTestMode creates a new tunnel client with test mode option
func NewClientWithTestMode(tlsConfig *tls.Config, serverAddr string, logLevel string, testMode bool) *Client {
	ctx, cancel := context.WithCancel(context.Background())

	logger := logging.NewLogger("tunnel-client")
	logger.SetLevel(logLevel)

	var awsCfg aws.Config
	var signer *v4.Signer

	if !testMode {
		// Load AWS configuration for IAM authentication
		var err error
		awsCfg, err = config.LoadDefaultConfig(ctx)
		if err != nil {
			logger.Error("Failed to load AWS config", err)
			// Continue without AWS config - tunnel will work without IAM auth
		}
		signer = v4.NewSigner()
	}

	return &Client{
		config:      tlsConfig,
		serverAddr:  serverAddr,
		requests:    make(map[string]chan *protocol.Response),
		connectCh:   make(map[string]chan *protocol.ConnectData),
		connectAcks: make(map[string]chan *protocol.ConnectAck),
		wsCh:        make(map[string]chan *protocol.WebSocketMessage),
		wsAcks:      make(map[string]chan *protocol.WebSocketAck),
		logger:      logger,
		ctx:         ctx,
		cancel:      cancel,
		reconnectCh: make(chan bool, 1),
		awsConfig:   awsCfg,
		signer:      signer,
	}
}

// UpdateServerAddress updates the server address for reconnection
func (c *Client) UpdateServerAddress(serverAddr string) {
	c.mu.Lock()
	defer c.mu.Unlock()

	// Close existing connection if connected
	if c.connected && c.conn != nil {
		c.logger.Info("Closing existing connection due to server address change", "old_addr", c.serverAddr, "new_addr", serverAddr)
		c.conn.Close()
		c.connected = false
	}

	c.serverAddr = serverAddr
	c.logger.Info("Server address updated", "new_addr", serverAddr)
}

// Connect establishes mTLS connection to server
func (c *Client) Connect() error {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.connected {
		return nil
	}

	c.logger.Info("Connecting to tunnel server", "addr", c.serverAddr)

	// Extract hostname for ServerName
	host := c.extractHost(c.serverAddr)

	// Create TLS config with client certificate
	tlsConfig := &tls.Config{
		Certificates:       c.config.Certificates,
		RootCAs:            c.config.RootCAs,
		MinVersion:         c.config.MinVersion,
		ServerName:         host, // CRITICAL: Set ServerName for proper mTLS handshake
		InsecureSkipVerify: true, // Skip hostname verification for dynamic Fargate IPs (temporary for testing)
	}

	c.logger.WithFields(logrus.Fields{
		"num_certificates":     len(tlsConfig.Certificates),
		"has_root_cas":         tlsConfig.RootCAs != nil,
		"server_name":          tlsConfig.ServerName,
		"insecure_skip_verify": tlsConfig.InsecureSkipVerify,
	}).Warn("TLS config for dial (hostname verification disabled - testing only)")

	conn, err := tls.Dial("tcp", c.serverAddr, tlsConfig)
	if err != nil {
		return fmt.Errorf("failed to connect to server: %w", err)
	}

	// Log the connection state
	state := conn.ConnectionState()
	c.logger.WithFields(logrus.Fields{
		"version":            state.Version,
		"cipher_suite":       state.CipherSuite,
		"peer_certificates":  len(state.PeerCertificates),
		"local_certificates": len(tlsConfig.Certificates),
	}).Info("TLS connection established")

	c.conn = conn
	c.connected = true
	c.logger.Info("Connected to tunnel server", "addr", c.serverAddr)

	// Start handling responses from server in background
	go c.handleResponses()

	// Perform IAM authentication after response handler is started
	if err := c.authenticateWithIAM(c.ctx); err != nil {
		c.logger.Error("IAM authentication failed", err)
		conn.Close()
		c.conn = nil
		c.connected = false
		return fmt.Errorf("IAM authentication failed: %w", err)
	}

	return nil
}

// Disconnect closes the connection to the server
func (c *Client) Disconnect() error {
	c.mu.Lock()
	defer c.mu.Unlock()

	if !c.connected {
		return nil
	}

	c.connected = false
	c.cancel()

	if c.conn != nil {
		c.conn.Close()
		c.conn = nil
	}

	c.logger.Info("Disconnected from tunnel server")
	return nil
}

// SendRequest sends request through tunnel and waits for response
func (c *Client) SendRequest(req *protocol.Request) (*protocol.Response, error) {
	c.mu.RLock()
	if !c.connected || c.conn == nil {
		c.mu.RUnlock()
		return nil, fmt.Errorf("not connected to server")
	}
	conn := c.conn
	c.mu.RUnlock()

	// Create response channel
	respChan := make(chan *protocol.Response, 1)
	c.mu.Lock()
	c.requests[req.ID] = respChan
	c.mu.Unlock()

	// Cleanup function
	cleanup := func() {
		c.mu.Lock()
		delete(c.requests, req.ID)
		c.mu.Unlock()
	}

	// Send request wrapped in Envelope
	encoder := json.NewEncoder(conn)
	env := protocol.Envelope{Type: "http_request", Payload: req}
	if err := encoder.Encode(env); err != nil {
		cleanup()
		c.logger.Error("Failed to send request", err, "id", req.ID)
		return nil, fmt.Errorf("failed to send request: %w", err)
	}

	c.logger.Debug("Sent request through tunnel", "id", req.ID, "url", req.URL)

	// Wait for response with timeout
	select {
	case resp, ok := <-respChan:
		if !ok {
			return nil, fmt.Errorf("response channel closed")
		}
		return resp, nil
	case <-time.After(30 * time.Second):
		cleanup()
		c.logger.Warn("Request timeout", "id", req.ID, "url", req.URL)
		return nil, fmt.Errorf("request timeout after 30 seconds")
	case <-c.ctx.Done():
		cleanup()
		return nil, fmt.Errorf("connection closed")
	}
}

// handleResponses processes responses from the server
func (c *Client) handleResponses() {
	defer func() {
		c.mu.Lock()
		c.connected = false
		// Close all pending request channels
		for id, ch := range c.requests {
			close(ch)
			delete(c.requests, id)
		}
		c.mu.Unlock()

		// Signal reconnection needed
		select {
		case c.reconnectCh <- true:
		default:
		}
	}()

	decoder := json.NewDecoder(c.conn)

	for {
		select {
		case <-c.ctx.Done():
			return
		default:
		}

		var env protocol.Envelope
		if err := decoder.Decode(&env); err != nil {
			c.logger.Error("Failed to decode envelope", err)
			return
		}

		switch env.Type {
		case "http_response":
			// Parse payload as Response
			m, _ := env.Payload.(map[string]any)
			b, _ := json.Marshal(m)
			var resp protocol.Response
			if err := json.Unmarshal(b, &resp); err != nil {
				c.logger.Error("Failed to parse http_response", err)
				continue
			}
			c.logger.Debug("Received response from tunnel", "id", resp.ID, "status", resp.StatusCode)
			c.mu.RLock()
			respChan, exists := c.requests[resp.ID]
			c.mu.RUnlock()
			if exists {
				select {
				case respChan <- &resp:
				case <-time.After(1 * time.Second):
					c.logger.Warn("Response channel blocked", "id", resp.ID)
				}
				c.mu.Lock()
				delete(c.requests, resp.ID)
				c.mu.Unlock()
			} else {
				c.logger.Warn("Received response for unknown request", "id", resp.ID)
			}

		case "connect_ack":
			m, _ := env.Payload.(map[string]any)
			b, _ := json.Marshal(m)
			var ack protocol.ConnectAck
			if err := json.Unmarshal(b, &ack); err != nil {
				c.logger.Error("Failed to parse connect_ack", err)
				continue
			}
			c.mu.RLock()
			ackCh := c.connectAcks[ack.ID]
			c.mu.RUnlock()
			if ackCh != nil {
				select {
				case ackCh <- &ack:
				case <-time.After(1 * time.Second):
					c.logger.Warn("Connect ack channel blocked", "id", ack.ID)
				}
			}

		case "connect_data":
			m, _ := env.Payload.(map[string]any)
			b, _ := json.Marshal(m)
			var data protocol.ConnectData
			if err := json.Unmarshal(b, &data); err != nil {
				c.logger.Error("Failed to parse connect_data", err)
				continue
			}
			c.mu.RLock()
			ch := c.connectCh[data.ID]
			c.mu.RUnlock()
			if ch != nil {
				select {
				case ch <- &data:
				default:
					// Channel full, drop packet (backpressure)
				}
			}

		case "connect_close":
			m, _ := env.Payload.(map[string]any)
			b, _ := json.Marshal(m)
			var cls protocol.ConnectClose
			if err := json.Unmarshal(b, &cls); err != nil {
				continue
			}
			c.mu.Lock()
			if ch := c.connectCh[cls.ID]; ch != nil {
				close(ch)
				delete(c.connectCh, cls.ID)
			}
			c.mu.Unlock()

		case "ws_ack":
			m, _ := env.Payload.(map[string]any)
			b, _ := json.Marshal(m)
			var ack protocol.WebSocketAck
			if err := json.Unmarshal(b, &ack); err != nil {
				c.logger.Error("Failed to parse ws_ack", err)
				continue
			}
			c.mu.RLock()
			ackCh := c.wsAcks[ack.ID]
			c.mu.RUnlock()
			if ackCh != nil {
				select {
				case ackCh <- &ack:
				case <-time.After(1 * time.Second):
					c.logger.Warn("WebSocket ack channel blocked", "id", ack.ID)
				}
			}

		case "ws_message":
			m, _ := env.Payload.(map[string]any)
			b, _ := json.Marshal(m)
			var msg protocol.WebSocketMessage
			if err := json.Unmarshal(b, &msg); err != nil {
				c.logger.Error("Failed to parse ws_message", err)
				continue
			}
			c.mu.RLock()
			ch := c.wsCh[msg.ID]
			c.mu.RUnlock()
			if ch != nil {
				select {
				case ch <- &msg:
				default:
					// Channel full, drop message (backpressure)
					c.logger.Warn("WebSocket message channel full, dropping message", "id", msg.ID)
				}
			}

		case "ws_close":
			m, _ := env.Payload.(map[string]any)
			b, _ := json.Marshal(m)
			var cls protocol.WebSocketClose
			if err := json.Unmarshal(b, &cls); err != nil {
				continue
			}
			c.mu.Lock()
			if ch := c.wsCh[cls.ID]; ch != nil {
				close(ch)
				delete(c.wsCh, cls.ID)
			}
			c.mu.Unlock()

		case "iam_auth_response":
			// Handle IAM authentication response
			m, _ := env.Payload.(map[string]any)
			b, _ := json.Marshal(m)
			var resp protocol.IAMAuthResponse
			if err := json.Unmarshal(b, &resp); err != nil {
				c.logger.Error("Failed to parse iam_auth_response", err)
				continue
			}
			if resp.Ok {
				c.logger.Info("IAM authentication approved by server")
			} else {
				c.logger.Warn("IAM authentication denied by server", "error", resp.Error)
			}

		default:
			// Ignore unknown message types
		}
	}
}

// IsConnected returns the connection status
func (c *Client) IsConnected() bool {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.connected
}

// ReconnectChannel returns a channel that signals when reconnection is needed
func (c *Client) ReconnectChannel() <-chan bool {
	return c.reconnectCh
}

// extractHost extracts the host part from an address
func (c *Client) extractHost(addr string) string {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return addr
	}
	return host
}

// ConnectOpen requests a TCP tunnel to host:port
func (c *Client) ConnectOpen(id, address string) (*protocol.ConnectAck, error) {
	c.mu.RLock()
	if !c.connected || c.conn == nil {
		c.mu.RUnlock()
		return nil, fmt.Errorf("not connected to server")
	}
	conn := c.conn
	c.mu.RUnlock()

	// Prepare channels for this connection
	ackCh := make(chan *protocol.ConnectAck, 1)
	c.mu.Lock()
	c.connectAcks[id] = ackCh
	if _, exists := c.connectCh[id]; !exists {
		c.connectCh[id] = make(chan *protocol.ConnectData, 64)
	}
	c.mu.Unlock()

	env := protocol.Envelope{Type: "connect_open", Payload: &protocol.ConnectOpen{ID: id, Address: address}}
	if err := json.NewEncoder(conn).Encode(env); err != nil {
		c.mu.Lock()
		delete(c.connectAcks, id)
		delete(c.connectCh, id)
		c.mu.Unlock()
		return nil, fmt.Errorf("failed to send connect_open: %w", err)
	}

	// Wait for real ack from server
	select {
	case ack := <-ackCh:
		c.mu.Lock()
		delete(c.connectAcks, id)
		c.mu.Unlock()
		return ack, nil
	case <-time.After(10 * time.Second):
		c.mu.Lock()
		delete(c.connectAcks, id)
		delete(c.connectCh, id)
		c.mu.Unlock()
		return nil, fmt.Errorf("timeout waiting for connect_ack")
	case <-c.ctx.Done():
		c.mu.Lock()
		delete(c.connectAcks, id)
		delete(c.connectCh, id)
		c.mu.Unlock()
		return nil, fmt.Errorf("connection closed")
	}
}

// ConnectSend sends a data chunk over the tunnel
func (c *Client) ConnectSend(id string, chunk []byte) error {
	c.mu.RLock()
	if !c.connected || c.conn == nil {
		c.mu.RUnlock()
		return fmt.Errorf("not connected to server")
	}
	conn := c.conn
	c.mu.RUnlock()
	env := protocol.Envelope{Type: "connect_data", Payload: &protocol.ConnectData{ID: id, Chunk: chunk}}
	return json.NewEncoder(conn).Encode(env)
}

// ConnectClose closes a tunnel stream
func (c *Client) ConnectClose(id, errMsg string) error {
	c.mu.RLock()
	if !c.connected || c.conn == nil {
		c.mu.RUnlock()
		return nil
	}
	conn := c.conn
	c.mu.RUnlock()
	env := protocol.Envelope{Type: "connect_close", Payload: &protocol.ConnectClose{ID: id, Error: errMsg}}
	return json.NewEncoder(conn).Encode(env)
}

// ConnectDataChannel returns the data channel for a given tunnel id
func (c *Client) ConnectDataChannel(id string) <-chan *protocol.ConnectData {
	c.mu.RLock()
	ch := c.connectCh[id]
	c.mu.RUnlock()
	return ch
}

// WebSocketOpen requests a WebSocket connection to be established
func (c *Client) WebSocketOpen(req *protocol.WebSocketOpen) (*protocol.WebSocketAck, error) {
	c.mu.RLock()
	if !c.connected || c.conn == nil {
		c.mu.RUnlock()
		return nil, fmt.Errorf("not connected to server")
	}
	conn := c.conn
	c.mu.RUnlock()

	// Prepare channels for this WebSocket
	ackCh := make(chan *protocol.WebSocketAck, 1)
	c.mu.Lock()
	c.wsAcks[req.ID] = ackCh
	if _, exists := c.wsCh[req.ID]; !exists {
		c.wsCh[req.ID] = make(chan *protocol.WebSocketMessage, 64)
	}
	c.mu.Unlock()

	env := protocol.Envelope{Type: "ws_open", Payload: req}
	if err := json.NewEncoder(conn).Encode(env); err != nil {
		c.mu.Lock()
		delete(c.wsAcks, req.ID)
		delete(c.wsCh, req.ID)
		c.mu.Unlock()
		return nil, fmt.Errorf("failed to send ws_open: %w", err)
	}

	// Wait for ack from server
	select {
	case ack := <-ackCh:
		c.mu.Lock()
		delete(c.wsAcks, req.ID)
		c.mu.Unlock()
		return ack, nil
	case <-time.After(10 * time.Second):
		c.mu.Lock()
		delete(c.wsAcks, req.ID)
		delete(c.wsCh, req.ID)
		c.mu.Unlock()
		return nil, fmt.Errorf("timeout waiting for ws_ack")
	case <-c.ctx.Done():
		c.mu.Lock()
		delete(c.wsAcks, req.ID)
		delete(c.wsCh, req.ID)
		c.mu.Unlock()
		return nil, fmt.Errorf("connection closed")
	}
}

// WebSocketSend sends a WebSocket message through the tunnel
func (c *Client) WebSocketSend(msg *protocol.WebSocketMessage) error {
	c.mu.RLock()
	if !c.connected || c.conn == nil {
		c.mu.RUnlock()
		return fmt.Errorf("not connected to server")
	}
	conn := c.conn
	c.mu.RUnlock()
	env := protocol.Envelope{Type: "ws_message", Payload: msg}
	return json.NewEncoder(conn).Encode(env)
}

// WebSocketClose closes a WebSocket connection
func (c *Client) WebSocketClose(id string, code int, errMsg string) error {
	c.mu.RLock()
	if !c.connected || c.conn == nil {
		c.mu.RUnlock()
		return nil
	}
	conn := c.conn
	c.mu.RUnlock()
	env := protocol.Envelope{Type: "ws_close", Payload: &protocol.WebSocketClose{ID: id, Code: code, Error: errMsg}}
	return json.NewEncoder(conn).Encode(env)
}

// WebSocketMessageChannel returns the message channel for a given WebSocket id
func (c *Client) WebSocketMessageChannel(id string) <-chan *protocol.WebSocketMessage {
	c.mu.RLock()
	ch := c.wsCh[id]
	c.mu.RUnlock()
	return ch
}

// authenticateWithIAM performs IAM authentication over the established TLS tunnel
func (c *Client) authenticateWithIAM(ctx context.Context) error {
	// Skip IAM auth if AWS config not loaded (test mode)
	if c.awsConfig.Region == "" || c.signer == nil {
		c.logger.Info("AWS config not loaded, skipping IAM authentication")
		return nil
	}

	// Check if AWS credentials are available (skip IAM auth if not configured)
	creds, err := c.awsConfig.Credentials.Retrieve(ctx)
	if err != nil {
		c.logger.Info("AWS credentials not available, skipping IAM authentication", "error", err)
		return nil
	}
	if creds.AccessKeyID == "" {
		c.logger.Info("AWS credentials not configured, skipping IAM authentication")
		return nil
	}

	c.logger.Info("Performing IAM authentication")

	// Create IAM auth request
	authReq := protocol.IAMAuthRequest{
		ID:            protocol.GenerateID(),
		Timestamp:     time.Now(),
		Service:       "tunnel",
		Region:        c.awsConfig.Region,
		AccessKeyID:   "", // Will be filled from credentials
		Signature:     "",
		SignedHeaders: "",
	}

	// Create a dummy request for signing
	dummyReq, err := http.NewRequest("POST", fmt.Sprintf("https://fluidity-server.%s.amazonaws.com/auth", c.awsConfig.Region), nil)
	if err != nil {
		return fmt.Errorf("failed to create dummy request: %w", err)
	}

	// Retrieve credentials
	creds, err = c.awsConfig.Credentials.Retrieve(ctx)
	if err != nil {
		return fmt.Errorf("failed to retrieve AWS credentials: %w", err)
	}

	authReq.AccessKeyID = creds.AccessKeyID

	// Sign the request
	err = c.signer.SignHTTP(ctx, creds, dummyReq, "", "execute-api", c.awsConfig.Region, time.Now())
	if err != nil {
		return fmt.Errorf("failed to sign auth request: %w", err)
	}

	// Extract signature components
	authReq.Signature = dummyReq.Header.Get("Authorization")
	authReq.SignedHeaders = dummyReq.Header.Get("X-Amz-SignedHeaders")

	// Send auth request over tunnel
	envelope := protocol.Envelope{
		Type:    "iam_auth_request",
		Payload: authReq,
	}

	c.mu.RLock()
	if !c.connected || c.conn == nil {
		c.mu.RUnlock()
		return fmt.Errorf("not connected to server")
	}
	conn := c.conn
	c.mu.RUnlock()

	if err := json.NewEncoder(conn).Encode(envelope); err != nil {
		return fmt.Errorf("failed to send IAM auth request: %w", err)
	}

	// Wait for the IAM auth response (will be delivered through handleResponses)
	// For now, just give it a moment to process
	select {
	case <-time.After(5 * time.Second):
		c.logger.Info("IAM authentication request sent, continuing with tunnel operations")
		return nil
	case <-ctx.Done():
		return fmt.Errorf("IAM authentication cancelled")
	}
}
