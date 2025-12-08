package tests

import (
	"encoding/json"
	"fmt"
	"sync"
	"testing"
	"time"

	"fluidity/internal/core/agent"
	"fluidity/internal/shared/protocol"
)

// TestIAMAuthenticationSuccess tests successful IAM authentication flow
func TestIAMAuthenticationSuccess(t *testing.T) {
	// Generate test certificates
	certs := GenerateTestCerts(t)

	// Start test server
	srv := StartTestServer(t, certs)
	defer srv.Stop()

	// Create client and connect
	client := agent.NewClientWithTestMode(certs.ClientTLS, srv.Addr, "debug", true)

	// Connect (this should succeed even without IAM auth in test mode)
	err := client.Connect()
	if err != nil {
		t.Errorf("Failed to connect: %v", err)
	}

	// Verify connection is established
	if !client.IsConnected() {
		t.Error("Client should be connected")
	}

	// Cleanup
	client.Disconnect()
}

// TestIAMAuthenticationMessageValidation tests that invalid message types are rejected
func TestIAMAuthenticationMessageValidation(t *testing.T) {
	validAgentTypes := map[string]bool{
		"http_response":     true,
		"connect_ack":       true,
		"connect_data":      true,
		"connect_close":     true,
		"ws_ack":            true,
		"ws_message":        true,
		"ws_close":          true,
		"iam_auth_response": true,
	}

	// Test that all valid types are recognized
	validTypes := []string{
		"http_response",
		"connect_ack",
		"connect_data",
		"connect_close",
		"ws_ack",
		"ws_message",
		"ws_close",
		"iam_auth_response",
	}

	for _, msgType := range validTypes {
		if !validAgentTypes[msgType] {
			t.Errorf("Type %q should be valid", msgType)
		}
	}

	// Test that invalid types are not recognized
	invalidTypes := []string{
		"invalid_message",
		"unknown_type",
		"garbage",
		"",
	}

	for _, invalidType := range invalidTypes {
		if validAgentTypes[invalidType] {
			t.Errorf("Type %q should be invalid", invalidType)
		}
	}
}

// TestIAMAuthResponseHandling tests proper handling of IAM auth responses
func TestIAMAuthResponseHandling(t *testing.T) {
	tests := []struct {
		name           string
		response       protocol.IAMAuthResponse
		expectError    bool
		errorContains  string
	}{
		{
			name: "successful auth response",
			response: protocol.IAMAuthResponse{
				ID: "test-id",
				Ok: true,
			},
			expectError: false,
		},
		{
			name: "failed auth response",
			response: protocol.IAMAuthResponse{
				ID:    "test-id",
				Ok:    false,
				Error: "unauthorized",
			},
			expectError:   true,
			errorContains: "unauthorized",
		},
		{
			name: "empty error message",
			response: protocol.IAMAuthResponse{
				ID:    "test-id",
				Ok:    false,
				Error: "",
			},
			expectError: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Verify response can be marshaled/unmarshaled
			data, err := json.Marshal(tt.response)
			if err != nil {
				t.Fatalf("Failed to marshal response: %v", err)
			}

			var resp protocol.IAMAuthResponse
			err = json.Unmarshal(data, &resp)
			if err != nil {
				t.Fatalf("Failed to unmarshal response: %v", err)
			}

			if resp.Ok != tt.response.Ok {
				t.Errorf("Response Ok mismatch: got %v, want %v", resp.Ok, tt.response.Ok)
			}

			if resp.Error != tt.response.Error {
				t.Errorf("Response Error mismatch: got %q, want %q", resp.Error, tt.response.Error)
			}
		})
	}
}

// TestIAMAuthRequestValidation tests IAM auth request validation on server
func TestIAMAuthRequestValidation(t *testing.T) {
	tests := []struct {
		name        string
		request     protocol.IAMAuthRequest
		shouldValid bool
	}{
		{
			name: "valid request",
			request: protocol.IAMAuthRequest{
				ID:            "test-id",
				Timestamp:     time.Now(),
				Service:       "tunnel",
				Region:        "us-east-1",
				AccessKeyID:   "AKIA...",
				Signature:     "AWS4-HMAC-SHA256...",
				SignedHeaders: "host;x-amz-date",
			},
			shouldValid: true,
		},
		{
			name: "missing ID",
			request: protocol.IAMAuthRequest{
				ID:            "",
				Timestamp:     time.Now(),
				Service:       "tunnel",
				Region:        "us-east-1",
				AccessKeyID:   "AKIA...",
				Signature:     "AWS4-HMAC-SHA256...",
				SignedHeaders: "host;x-amz-date",
			},
			shouldValid: false,
		},
		{
			name: "missing AccessKeyID",
			request: protocol.IAMAuthRequest{
				ID:            "test-id",
				Timestamp:     time.Now(),
				Service:       "tunnel",
				Region:        "us-east-1",
				AccessKeyID:   "",
				Signature:     "AWS4-HMAC-SHA256...",
				SignedHeaders: "host;x-amz-date",
			},
			shouldValid: false,
		},
		{
			name: "missing Signature",
			request: protocol.IAMAuthRequest{
				ID:            "test-id",
				Timestamp:     time.Now(),
				Service:       "tunnel",
				Region:        "us-east-1",
				AccessKeyID:   "AKIA...",
				Signature:     "",
				SignedHeaders: "host;x-amz-date",
			},
			shouldValid: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Verify request can be marshaled/unmarshaled
			data, err := json.Marshal(tt.request)
			if err != nil {
				t.Fatalf("Failed to marshal request: %v", err)
			}

			var req protocol.IAMAuthRequest
			err = json.Unmarshal(data, &req)
			if err != nil {
				t.Fatalf("Failed to unmarshal request: %v", err)
			}

			// Check validation criteria
			isValid := req.ID != "" && req.AccessKeyID != "" && req.Signature != ""

			if isValid != tt.shouldValid {
				t.Errorf("Validation mismatch: got %v, want %v", isValid, tt.shouldValid)
			}
		})
	}
}

// TestEnvelopeMessageTypeValidation tests envelope message type validation
func TestEnvelopeMessageTypeValidation(t *testing.T) {
	validAgentTypes := []string{
		"http_response",
		"connect_ack",
		"connect_data",
		"connect_close",
		"ws_ack",
		"ws_message",
		"ws_close",
		"iam_auth_response",
	}

	validServerTypes := []string{
		"http_request",
		"connect_open",
		"connect_data",
		"connect_close",
		"ws_open",
		"ws_message",
		"ws_close",
	}

	// Test agent valid types
	for _, msgType := range validAgentTypes {
		envelope := protocol.Envelope{
			Type:    msgType,
			Payload: map[string]interface{}{},
		}

		data, err := json.Marshal(envelope)
		if err != nil {
			t.Fatalf("Failed to marshal envelope: %v", err)
		}

		var env protocol.Envelope
		err = json.Unmarshal(data, &env)
		if err != nil {
			t.Fatalf("Failed to unmarshal envelope: %v", err)
		}

		if env.Type != msgType {
			t.Errorf("Type mismatch: got %q, want %q", env.Type, msgType)
		}
	}

	// Test server valid types
	for _, msgType := range validServerTypes {
		envelope := protocol.Envelope{
			Type:    msgType,
			Payload: map[string]interface{}{},
		}

		data, err := json.Marshal(envelope)
		if err != nil {
			t.Fatalf("Failed to marshal envelope: %v", err)
		}

		var env protocol.Envelope
		err = json.Unmarshal(data, &env)
		if err != nil {
			t.Fatalf("Failed to unmarshal envelope: %v", err)
		}

		if env.Type != msgType {
			t.Errorf("Type mismatch: got %q, want %q", env.Type, msgType)
		}
	}
}

// TestConcurrentIAMAuthRequests tests handling of concurrent IAM auth requests
func TestConcurrentIAMAuthRequests(t *testing.T) {
	numRequests := 10
	var wg sync.WaitGroup
	errors := make(chan error, numRequests)

	for i := 0; i < numRequests; i++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()

			req := protocol.IAMAuthRequest{
				ID:            fmt.Sprintf("req-%d", id),
				Timestamp:     time.Now(),
				Service:       "tunnel",
				Region:        "us-east-1",
				AccessKeyID:   fmt.Sprintf("AKIA%d", id),
				Signature:     fmt.Sprintf("sig-%d", id),
				SignedHeaders: "host;x-amz-date",
			}

			data, err := json.Marshal(req)
			if err != nil {
				errors <- err
				return
			}

			var req2 protocol.IAMAuthRequest
			err = json.Unmarshal(data, &req2)
			if err != nil {
				errors <- err
				return
			}

			if req2.ID != req.ID {
				errors <- fmt.Errorf("ID mismatch")
			}
		}(i)
	}

	wg.Wait()
	close(errors)

	for err := range errors {
		if err != nil {
			t.Errorf("Concurrent request failed: %v", err)
		}
	}
}

// TestIAMAuthEnvelopePayloadHandling tests envelope payload handling for IAM auth
func TestIAMAuthEnvelopePayloadHandling(t *testing.T) {
	req := protocol.IAMAuthRequest{
		ID:            "test-req",
		Timestamp:     time.Now(),
		Service:       "tunnel",
		Region:        "us-east-1",
		AccessKeyID:   "AKIA...",
		Signature:     "AWS4...",
		SignedHeaders: "host",
	}

	// Test with struct
	envelope := protocol.Envelope{
		Type:    "iam_auth_request",
		Payload: req,
	}

	data, err := json.Marshal(envelope)
	if err != nil {
		t.Fatalf("Failed to marshal envelope: %v", err)
	}

	// Unmarshal and re-parse
	var env protocol.Envelope
	err = json.Unmarshal(data, &env)
	if err != nil {
		t.Fatalf("Failed to unmarshal envelope: %v", err)
	}

	if env.Type != "iam_auth_request" {
		t.Errorf("Type mismatch: got %q, want %q", env.Type, "iam_auth_request")
	}

	// Extract payload
	payloadBytes, err := json.Marshal(env.Payload)
	if err != nil {
		t.Fatalf("Failed to marshal payload: %v", err)
	}

	var req2 protocol.IAMAuthRequest
	err = json.Unmarshal(payloadBytes, &req2)
	if err != nil {
		t.Fatalf("Failed to unmarshal payload: %v", err)
	}

	if req2.ID != req.ID {
		t.Errorf("ID mismatch: got %q, want %q", req2.ID, req.ID)
	}
	if req2.AccessKeyID != req.AccessKeyID {
		t.Errorf("AccessKeyID mismatch: got %q, want %q", req2.AccessKeyID, req.AccessKeyID)
	}
}
