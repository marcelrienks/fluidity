package kill

import (
	"context"
	"encoding/json"
	"fmt"
	"testing"

	"github.com/aws/aws-sdk-go-v2/service/ecs"
)

// Mock ECS client
type mockECSClient struct {
	updateServiceFunc func(ctx context.Context, params *ecs.UpdateServiceInput, optFns ...func(*ecs.Options)) (*ecs.UpdateServiceOutput, error)
}

func (m *mockECSClient) UpdateService(ctx context.Context, params *ecs.UpdateServiceInput, optFns ...func(*ecs.Options)) (*ecs.UpdateServiceOutput, error) {
	return m.updateServiceFunc(ctx, params, optFns...)
}

// TestKillSuccess tests successful service shutdown
func TestKillSuccess(t *testing.T) {
	updateCalled := false

	mockECS := &mockECSClient{
		updateServiceFunc: func(ctx context.Context, params *ecs.UpdateServiceInput, optFns ...func(*ecs.Options)) (*ecs.UpdateServiceOutput, error) {
			updateCalled = true

			// Verify parameters
			if *params.Cluster != "test-cluster" {
				t.Errorf("Expected cluster 'test-cluster', got: %s", *params.Cluster)
			}
			if *params.Service != "test-service" {
				t.Errorf("Expected service 'test-service', got: %s", *params.Service)
			}
			if *params.DesiredCount != 0 {
				t.Errorf("Expected DesiredCount 0, got: %d", *params.DesiredCount)
			}

			return &ecs.UpdateServiceOutput{}, nil
		},
	}

	handler := NewHandlerWithClient(mockECS, "test-cluster", "test-service")

	response, err := handler.HandleRequest(context.Background(), KillRequest{})
	if err != nil {
		t.Fatalf("Expected no error, got: %v", err)
	}

	if !updateCalled {
		t.Error("Expected UpdateService to be called")
	}

	// Response is wrapped in FunctionURLResponse
	functionURLResp, ok := response.(FunctionURLResponse)
	if !ok {
		t.Fatalf("Expected FunctionURLResponse, got %T", response)
	}

	if functionURLResp.StatusCode != 200 {
		t.Errorf("Expected StatusCode 200, got %d", functionURLResp.StatusCode)
	}

	// Parse the wrapped response
	var killResp KillResponse
	if err := json.Unmarshal([]byte(functionURLResp.Body), &killResp); err != nil {
		t.Fatalf("Failed to parse response body: %v", err)
	}

	if killResp.Status != "killed" {
		t.Errorf("Expected status 'killed', got '%s'", killResp.Status)
	}

	if killResp.DesiredCount != 0 {
		t.Errorf("Expected DesiredCount=0, got %d", killResp.DesiredCount)
	}
}

// TestKillWithOverrides tests that request parameters override handler defaults
func TestKillWithOverrides(t *testing.T) {
	mockECS := &mockECSClient{
		updateServiceFunc: func(ctx context.Context, params *ecs.UpdateServiceInput, optFns ...func(*ecs.Options)) (*ecs.UpdateServiceOutput, error) {
			// Verify overridden cluster/service names are used
			if *params.Cluster != "override-cluster" {
				t.Errorf("Expected cluster 'override-cluster', got: %s", *params.Cluster)
			}
			if *params.Service != "override-service" {
				t.Errorf("Expected service 'override-service', got: %s", *params.Service)
			}

			return &ecs.UpdateServiceOutput{}, nil
		},
	}

	handler := NewHandlerWithClient(mockECS, "default-cluster", "default-service")

	requestJSON := map[string]interface{}{
		"cluster_name": "override-cluster",
		"service_name": "override-service",
	}

	_, err := handler.HandleRequest(context.Background(), requestJSON)
	if err != nil {
		t.Fatalf("Expected no error, got: %v", err)
	}
}

// TestKillECSError tests handling of ECS API errors
func TestKillECSError(t *testing.T) {
	mockECS := &mockECSClient{
		updateServiceFunc: func(ctx context.Context, params *ecs.UpdateServiceInput, optFns ...func(*ecs.Options)) (*ecs.UpdateServiceOutput, error) {
			return nil, fmt.Errorf("ECS service not found")
		},
	}

	handler := NewHandlerWithClient(mockECS, "test-cluster", "test-service")

	response, err := handler.HandleRequest(context.Background(), map[string]interface{}{})
	if err != nil {
		// Errors are returned wrapped in FunctionURLResponse with statusCode 500
		t.Fatalf("Expected error wrapped in response, got error: %v", err)
	}

	// Check if response is error response
	functionURLResp, ok := response.(FunctionURLResponse)
	if !ok {
		t.Fatalf("Expected FunctionURLResponse, got %T", response)
	}

	if functionURLResp.StatusCode != 500 {
		t.Errorf("Expected error status 500, got %d", functionURLResp.StatusCode)
	}
}

// TestKillIdempotency tests that kill can be called multiple times safely
func TestKillIdempotency(t *testing.T) {
	callCount := 0

	mockECS := &mockECSClient{
		updateServiceFunc: func(ctx context.Context, params *ecs.UpdateServiceInput, optFns ...func(*ecs.Options)) (*ecs.UpdateServiceOutput, error) {
			callCount++
			// ECS UpdateService is idempotent - setting desiredCount=0 multiple times is safe
			return &ecs.UpdateServiceOutput{}, nil
		},
	}

	handler := NewHandlerWithClient(mockECS, "test-cluster", "test-service")

	// Call kill three times
	for i := 0; i < 3; i++ {
		response, err := handler.HandleRequest(context.Background(), KillRequest{})
		if err != nil {
			t.Fatalf("Call %d: Expected no error, got: %v", i+1, err)
		}

		functionURLResp, ok := response.(FunctionURLResponse)
		if !ok {
			t.Fatalf("Call %d: Expected FunctionURLResponse, got %T", i+1, response)
		}

		var killResp KillResponse
		if err := json.Unmarshal([]byte(functionURLResp.Body), &killResp); err != nil {
			t.Fatalf("Call %d: Failed to parse response body: %v", i+1, err)
		}

		if killResp.Status != "killed" {
			t.Errorf("Call %d: Expected status 'killed', got: %s", i+1, killResp.Status)
		}
	}

	if callCount != 3 {
		t.Errorf("Expected 3 UpdateService calls, got: %d", callCount)
	}
}

// TestKillEmptyRequest tests that empty request uses handler defaults
func TestKillEmptyRequest(t *testing.T) {
	mockECS := &mockECSClient{
		updateServiceFunc: func(ctx context.Context, params *ecs.UpdateServiceInput, optFns ...func(*ecs.Options)) (*ecs.UpdateServiceOutput, error) {
			// Should use handler defaults
			if *params.Cluster != "default-cluster" {
				t.Errorf("Expected cluster 'default-cluster', got: %s", *params.Cluster)
			}
			if *params.Service != "default-service" {
				t.Errorf("Expected service 'default-service', got: %s", *params.Service)
			}

			return &ecs.UpdateServiceOutput{}, nil
		},
	}

	handler := NewHandlerWithClient(mockECS, "default-cluster", "default-service")

	// Empty request - should use handler defaults
	_, err := handler.HandleRequest(context.Background(), KillRequest{})
	if err != nil {
		t.Fatalf("Expected no error, got: %v", err)
	}
}

// TestNewHandlerValidation tests that NewHandler validates required parameters
func TestNewHandlerValidation(t *testing.T) {
	tests := []struct {
		name        string
		clusterName string
		serviceName string
		wantErr     string
	}{
		{
			name:        "missing cluster name",
			clusterName: "",
			serviceName: "test-service",
			wantErr:     "clusterName is required",
		},
		{
			name:        "missing service name",
			clusterName: "test-cluster",
			serviceName: "",
			wantErr:     "serviceName is required",
		},
		{
			name:        "both missing",
			clusterName: "",
			serviceName: "",
			wantErr:     "clusterName is required",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := NewHandler(context.Background(), tt.clusterName, tt.serviceName)
			if err == nil {
				t.Fatal("Expected validation error, got nil")
			}
			if err.Error() != tt.wantErr {
				t.Errorf("Expected error '%s', got: %v", tt.wantErr, err)
			}
		})
	}
}
