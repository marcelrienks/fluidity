package lifecycle

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"fluidity/internal/core/agent"
	"fluidity/internal/shared/circuitbreaker"
	"fluidity/internal/shared/logging"
	"fluidity/internal/shared/retry"
	"github.com/aws/aws-sdk-go-v2/aws"
	v4 "github.com/aws/aws-sdk-go-v2/aws/signer/v4"
	awsconfig "github.com/aws/aws-sdk-go-v2/config"
)

// Client manages ECS service lifecycle through Lambda APIs
type Client struct {
	config         *Config
	httpClient     *http.Client
	circuitBreaker *circuitbreaker.CircuitBreaker
	logger         *logging.Logger
	awsConfig      aws.Config
	signer         *v4.Signer
}

// WakeRequest represents the request to Wake Lambda
type WakeRequest struct {
	ClusterName string `json:"clusterName,omitempty"`
	ServiceName string `json:"serviceName,omitempty"`
}

// WakeResponse represents the direct JSON response from Wake Lambda
type WakeResponse struct {
	Status             string `json:"status"`
	InstanceID         string `json:"instance_id,omitempty"`
	DesiredCount       int32  `json:"desiredCount"`
	RunningCount       int32  `json:"runningCount"`
	PendingCount       int32  `json:"pendingCount"`
	EstimatedStartTime string `json:"estimatedStartTime,omitempty"`
	Message            string `json:"message"`
}

// QueryRequest represents the request to Query Lambda
type QueryRequest struct {
	InstanceID string `json:"instance_id"`
}

// QueryResponse represents the direct JSON response from Query Lambda
type QueryResponse struct {
	Status   string `json:"status"` // "negative", "pending", "ready"
	PublicIP string `json:"public_ip,omitempty"`
	Message  string `json:"message"`
}

// KillRequest represents the request to Kill Lambda
type KillRequest struct {
	ClusterName string `json:"clusterName,omitempty"`
	ServiceName string `json:"serviceName,omitempty"`
}

// KillResponse represents the direct JSON response from Kill Lambda
type KillResponse struct {
	Status  string `json:"status"`
	Message string `json:"message"`
}

// NewClient creates a new lifecycle management client
func NewClient(config *Config, logger *logging.Logger) (*Client, error) {
	if config == nil {
		return nil, fmt.Errorf("config cannot be nil")
	}

	if logger == nil {
		logger = logging.NewLogger("lifecycle")
	}

	// Create HTTP client with timeout
	httpClient := &http.Client{
		Timeout: config.HTTPTimeout,
	}

	// Create circuit breaker for API calls
	cb := circuitbreaker.New(circuitbreaker.Config{
		MaxFailures:     3,
		ResetTimeout:    30 * time.Second,
		HalfOpenTimeout: 10 * time.Second,
		MaxHalfOpenReqs: 2,
	})

	// Load AWS configuration
	ctx := context.Background()
	awsCfg, err := awsconfig.LoadDefaultConfig(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to load AWS config: %w", err)
	}

	signer := v4.NewSigner()

	return &Client{
		config:         config,
		httpClient:     httpClient,
		circuitBreaker: cb,
		logger:         logger,
		awsConfig:      awsCfg,
		signer:         signer,
	}, nil
}

// Wake calls the Wake Lambda to start the ECS service
func (c *Client) Wake(ctx context.Context) (*WakeResponse, error) {
	if !c.config.Enabled {
		c.logger.Info("Lifecycle management disabled, skipping wake")
		return nil, nil
	}

	c.logger.Info("Waking ECS service",
		"endpoint", c.config.WakeEndpoint,
		"cluster", c.config.ClusterName,
		"service", c.config.ServiceName,
	)

	// Prepare request body
	reqBody := WakeRequest{
		ClusterName: c.config.ClusterName,
		ServiceName: c.config.ServiceName,
	}

	// Call Wake API with retry
	var response *WakeResponse
	retryConfig := retry.Config{
		MaxAttempts:  c.config.MaxRetries,
		InitialDelay: 500 * time.Millisecond,
		MaxDelay:     5 * time.Second,
		Multiplier:   2.0,
	}

	err := retry.Execute(ctx, retryConfig, retry.AlwaysRetry(), func() error {
		var err error
		response, err = c.callWakeAPI(ctx, reqBody)
		return err
	})

	if err != nil {
		c.logger.Error("Failed to wake ECS service", err)
		return nil, fmt.Errorf("wake failed: %w", err)
	}

	c.logger.Info("ECS service wake successful",
		"message", response.Message,
		"estimatedStartTime", response.EstimatedStartTime,
	)

	return response, nil
}

// callWakeAPI makes the HTTP request to Wake Lambda
func (c *Client) callWakeAPI(ctx context.Context, reqBody WakeRequest) (*WakeResponse, error) {
	response := &WakeResponse{}
	if err := c.callAPIWithSigV4(ctx, "POST", c.config.WakeEndpoint, reqBody, response); err != nil {
		return nil, err
	}
	return response, nil
}

// Kill calls the Kill Lambda to stop the ECS service
func (c *Client) Kill(ctx context.Context) error {
	if !c.config.Enabled {
		c.logger.Info("Lifecycle management disabled, skipping kill")
		return nil
	}

	c.logger.Info("Killing ECS service",
		"endpoint", c.config.KillEndpoint,
		"cluster", c.config.ClusterName,
		"service", c.config.ServiceName,
	)

	// Prepare request body
	reqBody := KillRequest{
		ClusterName: c.config.ClusterName,
		ServiceName: c.config.ServiceName,
	}

	// Call Kill API with retry
	var response *KillResponse
	retryConfig := retry.Config{
		MaxAttempts:  c.config.MaxRetries,
		InitialDelay: 500 * time.Millisecond,
		MaxDelay:     5 * time.Second,
		Multiplier:   2.0,
	}

	err := retry.Execute(ctx, retryConfig, retry.AlwaysRetry(), func() error {
		var err error
		response, err = c.callKillAPI(ctx, reqBody)
		return err
	})

	if err != nil {
		c.logger.Error("Failed to kill ECS service", err)
		return fmt.Errorf("kill failed: %w", err)
	}

	c.logger.Info("ECS service kill successful", "message", response.Message)

	return nil
}

// callKillAPI makes the HTTP request to Kill Lambda
func (c *Client) callKillAPI(ctx context.Context, reqBody KillRequest) (*KillResponse, error) {
	response := &KillResponse{}
	if err := c.callAPIWithSigV4(ctx, "POST", c.config.KillEndpoint, reqBody, response); err != nil {
		return nil, err
	}
	return response, nil
}

// callQueryAPI makes the HTTP request to Query Lambda
func (c *Client) callQueryAPI(ctx context.Context, instanceID string) (*QueryResponse, error) {
	reqBody := QueryRequest{InstanceID: instanceID}
	response := &QueryResponse{}
	if err := c.callAPIWithSigV4(ctx, "POST", c.config.QueryEndpoint, reqBody, response); err != nil {
		return nil, err
	}
	return response, nil
}

// callAPIWithSigV4 makes a SigV4 signed HTTP request to Lambda Function URL
// Returns direct JSON response (not wrapped)
func (c *Client) callAPIWithSigV4(ctx context.Context, method, url string, body interface{}, responseType interface{}) error {
	// Marshal request body
	bodyBytes, err := json.Marshal(body)
	if err != nil {
		return fmt.Errorf("failed to marshal request: %w", err)
	}

	// Execute with circuit breaker
	var response interface{}
	err = c.circuitBreaker.Execute(func() error {
		// Create HTTP request
		req, err := http.NewRequestWithContext(ctx, method, url, bytes.NewBuffer(bodyBytes))
		if err != nil {
			return fmt.Errorf("failed to create request: %w", err)
		}

		// Set headers
		req.Header.Set("Content-Type", "application/json")

		// Sign the request with SigV4
		bodyHash := sha256.Sum256(bodyBytes)
		bodyHashHex := hex.EncodeToString(bodyHash[:])

		// Retrieve credentials from provider
		creds, err := c.awsConfig.Credentials.Retrieve(ctx)
		if err != nil {
			return fmt.Errorf("failed to retrieve AWS credentials: %w", err)
		}

		err = c.signer.SignHTTP(ctx, creds, req, bodyHashHex, "lambda", c.awsConfig.Region, time.Now())
		if err != nil {
			return fmt.Errorf("failed to sign request: %w", err)
		}

		// Execute request
		resp, err := c.httpClient.Do(req)
		if err != nil {
			return fmt.Errorf("HTTP request failed: %w", err)
		}
		defer resp.Body.Close()

		// Read response body
		respBody, err := io.ReadAll(resp.Body)
		if err != nil {
			return fmt.Errorf("failed to read response: %w", err)
		}

		// Check status code
		if resp.StatusCode >= 400 {
			return fmt.Errorf("API returned error status %d: %s", resp.StatusCode, string(respBody))
		}

		// Try to parse as direct JSON response first (for SigV4 authenticated calls)
		var bodyData []byte

		// Check if response is direct JSON (SigV4) or Function URL format
		var testResp struct {
			StatusCode *int `json:"statusCode,omitempty"`
		}
		if err := json.Unmarshal(respBody, &testResp); err != nil || testResp.StatusCode == nil {
			// Direct JSON response (SigV4 auth)
			bodyData = respBody
		} else {
			// Function URL format response
			var functionURLResp struct {
				StatusCode int               `json:"statusCode"`
				Headers    map[string]string `json:"headers"`
				Body       string            `json:"body"`
			}

			if err := json.Unmarshal(respBody, &functionURLResp); err != nil {
				return fmt.Errorf("failed to parse Function URL response: %w", err)
			}

			// Extract the actual response from the body field
			bodyData = []byte(functionURLResp.Body)
		}

		// Parse response based on expected type
		// Check endpoint by comparing with configured endpoints
		if c.config.WakeEndpoint != "" && strings.HasPrefix(url, c.config.WakeEndpoint) {
			response = &WakeResponse{}
		} else if c.config.KillEndpoint != "" && strings.HasPrefix(url, c.config.KillEndpoint) {
			response = &KillResponse{}
		} else if c.config.QueryEndpoint != "" && strings.HasPrefix(url, c.config.QueryEndpoint) {
			response = &QueryResponse{}
		}

		if err := json.Unmarshal(bodyData, response); err != nil {
			return fmt.Errorf("failed to parse response body: %w", err)
		}

		return nil
	})

	if err != nil {
		return err
	}

	// Copy the response to the output parameter
	switch r := response.(type) {
	case *WakeResponse:
		*responseType.(*WakeResponse) = *r
	case *KillResponse:
		*responseType.(*KillResponse) = *r
	case *QueryResponse:
		*responseType.(*QueryResponse) = *r
	}

	return nil
}

// WakeAndGetIP wakes the server and polls for its IP address until available
func (c *Client) WakeAndGetIP(ctx context.Context, agentConfig interface{}) error {
	if !c.config.Enabled {
		return fmt.Errorf("lifecycle management disabled")
	}

	// First, wake the server
	c.logger.Info("Waking ECS service")
	wakeResp, err := c.Wake(ctx)
	if err != nil {
		return fmt.Errorf("wake failed: %w", err)
	}

	// Wait a bit for the service to start
	time.Sleep(5 * time.Second)

	// Poll for the server IP
	maxAttempts := 10 // ~30 seconds with 3 second intervals
	pollInterval := 3 * time.Second
	for attempt := 1; attempt <= maxAttempts; attempt++ {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}

		c.logger.Info("Polling for server IP", "attempt", attempt, "max_attempts", maxAttempts)

		// Query for the server IP
		queryResp, err := c.callQueryAPI(ctx, wakeResp.InstanceID)
		if err != nil {
			c.logger.Warn("Query failed, will retry", "error", err.Error(), "attempt", attempt)
			time.Sleep(pollInterval)
			continue
		}

		if queryResp.PublicIP != "" {
			// Update the agent config with the discovered IP
			if cfg, ok := agentConfig.(*agent.Config); ok {
				cfg.ServerIP = queryResp.PublicIP
				c.logger.Info("Server IP discovered and config updated", "server_ip", queryResp.PublicIP)
			}
			return nil
		}

		c.logger.Info("Server not ready yet, waiting...", "attempt", attempt)
		time.Sleep(pollInterval)
	}

	return fmt.Errorf("timeout waiting for server IP after %d attempts", maxAttempts)
}

// WaitForConnection waits for the agent to establish server connection after wake
func (c *Client) WaitForConnection(ctx context.Context, checkFn func() bool) error {
	if !c.config.Enabled {
		return nil
	}

	c.logger.Info("Waiting for server connection",
		"timeout", c.config.ConnectionTimeout,
		"retryInterval", c.config.ConnectionRetryInterval,
	)

	// Create timeout context
	timeoutCtx, cancel := context.WithTimeout(ctx, c.config.ConnectionTimeout)
	defer cancel()

	ticker := time.NewTicker(c.config.ConnectionRetryInterval)
	defer ticker.Stop()

	for {
		select {
		case <-timeoutCtx.Done():
			return fmt.Errorf("connection timeout after %v", c.config.ConnectionTimeout)
		case <-ticker.C:
			if checkFn() {
				c.logger.Info("Server connection established")
				return nil
			}
			c.logger.Debug("Connection not ready, retrying...")
		}
	}
}
