package lifecycle

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"fluidity/internal/shared/logging"
)

func TestLoadConfig(t *testing.T) {
	// Save original env vars
	originalVars := map[string]string{
		"WAKE_ENDPOINT":             "",
		"KILL_ENDPOINT":             "",
		"API_KEY":                   "",
		"ECS_CLUSTER_NAME":          "",
		"ECS_SERVICE_NAME":          "",
		"CONNECTION_TIMEOUT":        "",
		"CONNECTION_RETRY_INTERVAL": "",
		"HTTP_TIMEOUT":              "",
		"MAX_RETRIES":               "",
		"LIFECYCLE_ENABLED":         "",
	}

	// Clean up after test
	defer func() {
		for key, value := range originalVars {
			if value != "" {
				t.Setenv(key, value)
			}
		}
	}()

	tests := []struct {
		name        string
		envVars     map[string]string
		wantEnabled bool
		wantErr     bool
	}{
		{
			name: "disabled when endpoints not set",
			envVars: map[string]string{
				"WAKE_ENDPOINT": "",
				"KILL_ENDPOINT": "",
			},
			wantEnabled: false,
			wantErr:     false,
		},
		{
			name: "enabled when endpoints set",
			envVars: map[string]string{
				"WAKE_ENDPOINT":  "https://api.example.com/wake",
				"QUERY_ENDPOINT": "https://api.example.com/query",
				"KILL_ENDPOINT":  "https://api.example.com/kill",
				"API_KEY":        "test-key",
			},
			wantEnabled: true,
			wantErr:     false,
		},
		{
			name: "custom timeouts",
			envVars: map[string]string{
				"WAKE_ENDPOINT":             "https://api.example.com/wake",
				"QUERY_ENDPOINT":            "https://api.example.com/query",
				"KILL_ENDPOINT":             "https://api.example.com/kill",
				"CONNECTION_TIMEOUT":        "120s",
				"CONNECTION_RETRY_INTERVAL": "10s",
				"HTTP_TIMEOUT":              "60s",
			},
			wantEnabled: true,
			wantErr:     false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Set env vars
			for key, value := range tt.envVars {
				t.Setenv(key, value)
			}

			config, err := LoadConfig()
			if (err != nil) != tt.wantErr {
				t.Errorf("LoadConfig() error = %v, wantErr %v", err, tt.wantErr)
				return
			}

			if config.Enabled != tt.wantEnabled {
				t.Errorf("LoadConfig() Enabled = %v, want %v", config.Enabled, tt.wantEnabled)
			}
		})
	}
}

func TestConfigValidate(t *testing.T) {
	tests := []struct {
		name    string
		config  *Config
		wantErr bool
	}{
		{
			name: "valid config",
			config: &Config{
				WakeEndpoint:  "https://api.example.com/wake",
				QueryEndpoint: "https://api.example.com/query",
				KillEndpoint:  "https://api.example.com/kill",
				IAMRoleARN:    "arn:aws:iam::123456789012:role/fluidity-agent",
				AWSRegion:     "us-east-1",
				Enabled:       true,
			},
			wantErr: false,
		},
		{
			name: "disabled config is valid",
			config: &Config{
				Enabled: false,
			},
			wantErr: false,
		},
		{
			name: "missing wake endpoint",
			config: &Config{
				KillEndpoint: "https://api.example.com/kill",
				IAMRoleARN:   "arn:aws:iam::123456789012:role/fluidity-agent",
				AWSRegion:    "us-east-1",
				Enabled:      true,
			},
			wantErr: true,
		},
		{
			name: "missing kill endpoint",
			config: &Config{
				WakeEndpoint: "https://api.example.com/wake",
				IAMRoleARN:   "arn:aws:iam::123456789012:role/fluidity-agent",
				AWSRegion:    "us-east-1",
				Enabled:      true,
			},
			wantErr: true,
		},
		{
			name: "missing_endpoints",
			config: &Config{
				Enabled: true,
			},
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := tt.config.Validate()
			if (err != nil) != tt.wantErr {
				t.Errorf("Config.Validate() error = %v, wantErr %v", err, tt.wantErr)
			}
		})
	}
}

func TestWakeSuccess(t *testing.T) {
	t.Skip("Skipping SigV4 test - requires AWS credentials in test environment")

	// Create mock server
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Verify request
		if r.Method != "POST" {
			t.Errorf("Expected POST request, got %s", r.Method)
		}

		// IAM authentication uses SigV4 signing instead of API keys

		// Send response
		response := WakeResponse{
			StatusCode:         200,
			Message:            "Service wake initiated",
			EstimatedStartTime: "2025-10-29T17:00:00Z",
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(response)
	}))
	defer server.Close()

	// Create client
	config := &Config{
		WakeEndpoint: server.URL,
		KillEndpoint: server.URL,
		IAMRoleARN:   "arn:aws:iam::123456789012:role/fluidity-agent",
		AWSRegion:    "us-east-1",
		HTTPTimeout:  10 * time.Second,
		MaxRetries:   3,
		Enabled:      true,
		ClusterName:  "test-cluster",
		ServiceName:  "test-service",
	}

	logger := logging.NewLogger("test")
	client, err := NewClient(config, logger)
	if err != nil {
		t.Fatalf("NewClient() error = %v", err)
	}

	// Call Wake
	ctx := context.Background()
	err = client.Wake(ctx)
	if err != nil {
		t.Errorf("Wake() error = %v", err)
	}
}

func TestWakeDisabled(t *testing.T) {
	config := &Config{
		Enabled: false,
	}

	logger := logging.NewLogger("test")
	client, err := NewClient(config, logger)
	if err != nil {
		t.Fatalf("NewClient() error = %v", err)
	}

	// Call Wake - should not error when disabled
	ctx := context.Background()
	err = client.Wake(ctx)
	if err != nil {
		t.Errorf("Wake() error = %v, expected nil when disabled", err)
	}
}

func TestWakeAPIError(t *testing.T) {
	// Create mock server that returns error
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		w.Write([]byte("Internal server error"))
	}))
	defer server.Close()

	config := &Config{
		WakeEndpoint: server.URL,
		KillEndpoint: server.URL,
		IAMRoleARN:   "arn:aws:iam::123456789012:role/fluidity-agent",
		AWSRegion:    "us-east-1",
		HTTPTimeout:  10 * time.Second,
		MaxRetries:   3,
		Enabled:      true,
		ClusterName:  "test-cluster",
		ServiceName:  "test-service",
	}

	logger := logging.NewLogger("test")
	client, err := NewClient(config, logger)
	if err != nil {
		t.Fatalf("NewClient() error = %v", err)
	}

	ctx := context.Background()
	err = client.Wake(ctx)
	if err == nil {
		t.Error("Wake() expected error, got nil")
	}
}

func TestKillSuccess(t *testing.T) {
	t.Skip("Skipping SigV4 test - requires AWS credentials in test environment")

	// Create mock server
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Verify request
		if r.Method != "POST" {
			t.Errorf("Expected POST request, got %s", r.Method)
		}

		// IAM authentication uses SigV4 signing instead of API keys

		// Send response
		response := KillResponse{
			StatusCode: 200,
			Message:    "Service shutdown initiated",
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(response)
	}))
	defer server.Close()

	config := &Config{
		WakeEndpoint: server.URL,
		KillEndpoint: server.URL,
		IAMRoleARN:   "arn:aws:iam::123456789012:role/fluidity-agent",
		AWSRegion:    "us-east-1",
		HTTPTimeout:  10 * time.Second,
		MaxRetries:   3,
		Enabled:      true,
		ClusterName:  "test-cluster",
		ServiceName:  "test-service",
	}

	logger := logging.NewLogger("test")
	client, err := NewClient(config, logger)
	if err != nil {
		t.Fatalf("NewClient() error = %v", err)
	}

	ctx := context.Background()
	err = client.Kill(ctx)
	if err != nil {
		t.Errorf("Kill() error = %v", err)
	}
}

func TestWaitForConnection(t *testing.T) {
	config := &Config{
		ConnectionTimeout:       2 * time.Second,
		ConnectionRetryInterval: 200 * time.Millisecond,
		Enabled:                 true,
	}

	logger := logging.NewLogger("test")
	client, err := NewClient(config, logger)
	if err != nil {
		t.Fatalf("NewClient() error = %v", err)
	}

	t.Run("connection established", func(t *testing.T) {
		connected := false
		go func() {
			time.Sleep(500 * time.Millisecond)
			connected = true
		}()

		ctx := context.Background()
		err := client.WaitForConnection(ctx, func() bool {
			return connected
		})

		if err != nil {
			t.Errorf("WaitForConnection() error = %v", err)
		}
	})

	t.Run("connection timeout", func(t *testing.T) {
		ctx := context.Background()
		err := client.WaitForConnection(ctx, func() bool {
			return false // Never connected
		})

		if err == nil {
			t.Error("WaitForConnection() expected timeout error, got nil")
		}
	})

	t.Run("disabled skips wait", func(t *testing.T) {
		disabledConfig := &Config{
			Enabled: false,
		}
		disabledClient, _ := NewClient(disabledConfig, logger)

		ctx := context.Background()
		err := disabledClient.WaitForConnection(ctx, func() bool {
			return false
		})

		if err != nil {
			t.Errorf("WaitForConnection() error = %v, expected nil when disabled", err)
		}
	})
}
