package wake

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/aws/aws-sdk-go-v2/service/ecs"
	"github.com/aws/aws-sdk-go-v2/service/ecs/types"
)

// MockECSClient implements a mock ECS client for testing
type MockECSClient struct {
	DescribeServicesFunc func(ctx context.Context, params *ecs.DescribeServicesInput, optFns ...func(*ecs.Options)) (*ecs.DescribeServicesOutput, error)
	UpdateServiceFunc    func(ctx context.Context, params *ecs.UpdateServiceInput, optFns ...func(*ecs.Options)) (*ecs.UpdateServiceOutput, error)
}

func (m *MockECSClient) DescribeServices(ctx context.Context, params *ecs.DescribeServicesInput, optFns ...func(*ecs.Options)) (*ecs.DescribeServicesOutput, error) {
	return m.DescribeServicesFunc(ctx, params, optFns...)
}

func (m *MockECSClient) UpdateService(ctx context.Context, params *ecs.UpdateServiceInput, optFns ...func(*ecs.Options)) (*ecs.UpdateServiceOutput, error) {
	return m.UpdateServiceFunc(ctx, params, optFns...)
}

// TestWakeWhenServiceStopped verifies wake sets DesiredCount=1 when service is stopped
func TestWakeWhenServiceStopped(t *testing.T) {
	mockECS := &MockECSClient{
		DescribeServicesFunc: func(ctx context.Context, params *ecs.DescribeServicesInput, optFns ...func(*ecs.Options)) (*ecs.DescribeServicesOutput, error) {
			return &ecs.DescribeServicesOutput{
				Services: []types.Service{
					{
						ServiceName:  stringPtr("fluidity-server"),
						DesiredCount: int32(0),
						RunningCount: int32(0),
						PendingCount: int32(0),
					},
				},
			}, nil
		},
		UpdateServiceFunc: func(ctx context.Context, params *ecs.UpdateServiceInput, optFns ...func(*ecs.Options)) (*ecs.UpdateServiceOutput, error) {
			if *params.DesiredCount != 1 {
				t.Errorf("Expected DesiredCount=1, got %d", *params.DesiredCount)
			}
			return &ecs.UpdateServiceOutput{}, nil
		},
	}

	handler := NewHandlerWithClient(mockECS, "test-cluster", "fluidity-server")

	// Pass event as direct JSON (what Lambda Function URL would send)
	response, err := handler.HandleRequest(context.Background(), map[string]interface{}{})
	if err != nil {
		t.Fatalf("Expected no error, got %v", err)
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
	var wakeResp WakeResponse
	if err := json.Unmarshal([]byte(functionURLResp.Body), &wakeResp); err != nil {
		t.Fatalf("Failed to parse response body: %v", err)
	}

	if wakeResp.Status != "waking" {
		t.Errorf("Expected status 'waking', got '%s'", wakeResp.Status)
	}

	if wakeResp.DesiredCount != 1 {
		t.Errorf("Expected DesiredCount=1, got %d", wakeResp.DesiredCount)
	}

	if wakeResp.EstimatedStartTime == "" {
		t.Error("Expected EstimatedStartTime to be set")
	}
}

// TestWakeWhenServiceAlreadyRunning verifies scaling behavior when service is running
func TestWakeWhenServiceAlreadyRunning(t *testing.T) {
	mockECS := &MockECSClient{
		DescribeServicesFunc: func(ctx context.Context, params *ecs.DescribeServicesInput, optFns ...func(*ecs.Options)) (*ecs.DescribeServicesOutput, error) {
			return &ecs.DescribeServicesOutput{
				Services: []types.Service{
					{
						ServiceName:  stringPtr("fluidity-server"),
						DesiredCount: int32(1),
						RunningCount: int32(1),
						PendingCount: int32(0),
					},
				},
			}, nil
		},
		UpdateServiceFunc: func(ctx context.Context, params *ecs.UpdateServiceInput, optFns ...func(*ecs.Options)) (*ecs.UpdateServiceOutput, error) {
			if *params.DesiredCount != 2 {
				t.Errorf("Expected DesiredCount=2, got %d", *params.DesiredCount)
			}
			return &ecs.UpdateServiceOutput{}, nil
		},
	}

	handler := NewHandlerWithClient(mockECS, "test-cluster", "fluidity-server")

	response, err := handler.HandleRequest(context.Background(), map[string]interface{}{})
	if err != nil {
		t.Fatalf("Expected no error, got %v", err)
	}

	functionURLResp, ok := response.(FunctionURLResponse)
	if !ok {
		t.Fatalf("Expected FunctionURLResponse, got %T", response)
	}

	var wakeResp WakeResponse
	if err := json.Unmarshal([]byte(functionURLResp.Body), &wakeResp); err != nil {
		t.Fatalf("Failed to parse response body: %v", err)
	}

	if wakeResp.Status != "scaling" {
		t.Errorf("Expected status 'scaling', got '%s'", wakeResp.Status)
	}

	if wakeResp.DesiredCount != 2 {
		t.Errorf("Expected DesiredCount=2, got %d", wakeResp.DesiredCount)
	}
}

// TestWakeWhenServiceStarting verifies scaling behavior when service is pending
func TestWakeWhenServiceStarting(t *testing.T) {
	mockECS := &MockECSClient{
		DescribeServicesFunc: func(ctx context.Context, params *ecs.DescribeServicesInput, optFns ...func(*ecs.Options)) (*ecs.DescribeServicesOutput, error) {
			return &ecs.DescribeServicesOutput{
				Services: []types.Service{
					{
						ServiceName:  stringPtr("fluidity-server"),
						DesiredCount: int32(1),
						RunningCount: int32(0),
						PendingCount: int32(1),
					},
				},
			}, nil
		},
		UpdateServiceFunc: func(ctx context.Context, params *ecs.UpdateServiceInput, optFns ...func(*ecs.Options)) (*ecs.UpdateServiceOutput, error) {
			if *params.DesiredCount != 2 {
				t.Errorf("Expected DesiredCount=2, got %d", *params.DesiredCount)
			}
			return &ecs.UpdateServiceOutput{}, nil
		},
	}

	handler := NewHandlerWithClient(mockECS, "test-cluster", "fluidity-server")

	response, err := handler.HandleRequest(context.Background(), map[string]interface{}{})
	if err != nil {
		t.Fatalf("Expected no error, got %v", err)
	}

	functionURLResp, ok := response.(FunctionURLResponse)
	if !ok {
		t.Fatalf("Expected FunctionURLResponse, got %T", response)
	}

	var wakeResp WakeResponse
	if err := json.Unmarshal([]byte(functionURLResp.Body), &wakeResp); err != nil {
		t.Fatalf("Failed to parse response body: %v", err)
	}

	if wakeResp.Status != "starting" {
		t.Errorf("Expected status 'starting', got '%s'", wakeResp.Status)
	}

	if wakeResp.DesiredCount != 2 {
		t.Errorf("Expected DesiredCount=2, got %d", wakeResp.DesiredCount)
	}

	if wakeResp.PendingCount != 1 {
		t.Errorf("Expected PendingCount=1, got %d", wakeResp.PendingCount)
	}
}

// TestWakeServiceNotFound verifies error handling when service doesn't exist
func TestWakeServiceNotFound(t *testing.T) {
	mockECS := &MockECSClient{
		DescribeServicesFunc: func(ctx context.Context, params *ecs.DescribeServicesInput, optFns ...func(*ecs.Options)) (*ecs.DescribeServicesOutput, error) {
			return &ecs.DescribeServicesOutput{
				Services: []types.Service{}, // Empty list
			}, nil
		},
	}

	handler := NewHandlerWithClient(mockECS, "test-cluster", "non-existent-service")

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

// TestWakeWithRequestOverrides verifies cluster/service name can be overridden
func TestWakeWithRequestOverrides(t *testing.T) {
	mockECS := &MockECSClient{
		DescribeServicesFunc: func(ctx context.Context, params *ecs.DescribeServicesInput, optFns ...func(*ecs.Options)) (*ecs.DescribeServicesOutput, error) {
			if *params.Cluster != "override-cluster" {
				t.Errorf("Expected cluster 'override-cluster', got '%s'", *params.Cluster)
			}
			if params.Services[0] != "override-service" {
				t.Errorf("Expected service 'override-service', got '%s'", params.Services[0])
			}
			return &ecs.DescribeServicesOutput{
				Services: []types.Service{
					{
						ServiceName:  stringPtr("override-service"),
						DesiredCount: int32(0),
						RunningCount: int32(0),
						PendingCount: int32(0),
					},
				},
			}, nil
		},
		UpdateServiceFunc: func(ctx context.Context, params *ecs.UpdateServiceInput, optFns ...func(*ecs.Options)) (*ecs.UpdateServiceOutput, error) {
			return &ecs.UpdateServiceOutput{}, nil
		},
	}

	handler := NewHandlerWithClient(mockECS, "default-cluster", "default-service")

	// Pass request as JSON-encoded map (what Function URL would receive)
	requestJSON := map[string]interface{}{
		"cluster_name": "override-cluster",
		"service_name": "override-service",
	}

	_, err := handler.HandleRequest(context.Background(), requestJSON)
	if err != nil {
		t.Fatalf("Expected no error, got %v", err)
	}
}

// Helper function to create string pointers
func stringPtr(s string) *string {
	return &s
}
