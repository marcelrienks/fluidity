package query

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	ec2types "github.com/aws/aws-sdk-go-v2/service/ec2/types"
	"github.com/aws/aws-sdk-go-v2/service/ecs"
	ecstypes "github.com/aws/aws-sdk-go-v2/service/ecs/types"
)

// MockECSClient implements ECSClient for testing
type MockECSClient struct {
	DescribeServicesFunc func(ctx context.Context, params *ecs.DescribeServicesInput, optFns ...func(*ecs.Options)) (*ecs.DescribeServicesOutput, error)
	ListTasksFunc        func(ctx context.Context, params *ecs.ListTasksInput, optFns ...func(*ecs.Options)) (*ecs.ListTasksOutput, error)
	DescribeTasksFunc    func(ctx context.Context, params *ecs.DescribeTasksInput, optFns ...func(*ecs.Options)) (*ecs.DescribeTasksOutput, error)
}

func (m *MockECSClient) DescribeServices(ctx context.Context, params *ecs.DescribeServicesInput, optFns ...func(*ecs.Options)) (*ecs.DescribeServicesOutput, error) {
	if m.DescribeServicesFunc != nil {
		return m.DescribeServicesFunc(ctx, params, optFns...)
	}
	return &ecs.DescribeServicesOutput{}, nil
}

func (m *MockECSClient) ListTasks(ctx context.Context, params *ecs.ListTasksInput, optFns ...func(*ecs.Options)) (*ecs.ListTasksOutput, error) {
	if m.ListTasksFunc != nil {
		return m.ListTasksFunc(ctx, params, optFns...)
	}
	return &ecs.ListTasksOutput{}, nil
}

func (m *MockECSClient) DescribeTasks(ctx context.Context, params *ecs.DescribeTasksInput, optFns ...func(*ecs.Options)) (*ecs.DescribeTasksOutput, error) {
	if m.DescribeTasksFunc != nil {
		return m.DescribeTasksFunc(ctx, params, optFns...)
	}
	return &ecs.DescribeTasksOutput{}, nil
}

// MockEC2Client implements EC2Client for testing
type MockEC2Client struct {
	DescribeNetworkInterfacesFunc func(ctx context.Context, params *ec2.DescribeNetworkInterfacesInput, optFns ...func(*ec2.Options)) (*ec2.DescribeNetworkInterfacesOutput, error)
}

func (m *MockEC2Client) DescribeNetworkInterfaces(ctx context.Context, params *ec2.DescribeNetworkInterfacesInput, optFns ...func(*ec2.Options)) (*ec2.DescribeNetworkInterfacesOutput, error) {
	if m.DescribeNetworkInterfacesFunc != nil {
		return m.DescribeNetworkInterfacesFunc(ctx, params, optFns...)
	}
	return &ec2.DescribeNetworkInterfacesOutput{}, nil
}

func TestQueryHandler_ServiceNotFound(t *testing.T) {
	mockECS := &MockECSClient{
		DescribeServicesFunc: func(ctx context.Context, params *ecs.DescribeServicesInput, optFns ...func(*ecs.Options)) (*ecs.DescribeServicesOutput, error) {
			return &ecs.DescribeServicesOutput{
				Services: []ecstypes.Service{},
			}, nil
		},
	}

	handler := NewHandlerWithClient(mockECS, &MockEC2Client{}, "test-cluster", "test-service")

	request := QueryRequest{
		InstanceID: "test-instance-123",
	}

	response, err := handler.handleQueryRequest(context.Background(), request)
	if err != nil {
		t.Fatalf("Expected no error, got %v", err)
	}

	if response.Status != "negative" {
		t.Errorf("Expected status 'negative', got '%s'", response.Status)
	}

	if response.Message != "ECS service not found" {
		t.Errorf("Expected message 'ECS service not found', got '%s'", response.Message)
	}
}

func TestQueryHandler_ServiceStopped(t *testing.T) {
	mockECS := &MockECSClient{
		DescribeServicesFunc: func(ctx context.Context, params *ecs.DescribeServicesInput, optFns ...func(*ecs.Options)) (*ecs.DescribeServicesOutput, error) {
			return &ecs.DescribeServicesOutput{
				Services: []ecstypes.Service{
					{
						DesiredCount: 0,
						RunningCount: 0,
						PendingCount: 0,
					},
				},
			}, nil
		},
	}

	handler := NewHandlerWithClient(mockECS, &MockEC2Client{}, "test-cluster", "test-service")

	request := QueryRequest{
		InstanceID: "test-instance-123",
	}

	response, err := handler.handleQueryRequest(context.Background(), request)
	if err != nil {
		t.Fatalf("Expected no error, got %v", err)
	}

	if response.Status != "negative" {
		t.Errorf("Expected status 'negative', got '%s'", response.Status)
	}

	if response.Message != "Service is stopped (desiredCount=0)" {
		t.Errorf("Expected message 'Service is stopped (desiredCount=0)', got '%s'", response.Message)
	}
}

func TestQueryHandler_ServiceStarting(t *testing.T) {
	mockECS := &MockECSClient{
		DescribeServicesFunc: func(ctx context.Context, params *ecs.DescribeServicesInput, optFns ...func(*ecs.Options)) (*ecs.DescribeServicesOutput, error) {
			return &ecs.DescribeServicesOutput{
				Services: []ecstypes.Service{
					{
						DesiredCount: 1,
						RunningCount: 0,
						PendingCount: 1,
					},
				},
			}, nil
		},
	}

	handler := NewHandlerWithClient(mockECS, &MockEC2Client{}, "test-cluster", "test-service")

	request := QueryRequest{
		InstanceID: "test-instance-123",
	}

	response, err := handler.handleQueryRequest(context.Background(), request)
	if err != nil {
		t.Fatalf("Expected no error, got %v", err)
	}

	if response.Status != "pending" {
		t.Errorf("Expected status 'pending', got '%s'", response.Status)
	}

	if response.Message != "Service is starting (pendingCount=1)" {
		t.Errorf("Expected message 'Service is starting (pendingCount=1)', got '%s'", response.Message)
	}
}

func TestQueryHandler_ServiceRunningWithIP(t *testing.T) {
	mockECS := &MockECSClient{
		DescribeServicesFunc: func(ctx context.Context, params *ecs.DescribeServicesInput, optFns ...func(*ecs.Options)) (*ecs.DescribeServicesOutput, error) {
			return &ecs.DescribeServicesOutput{
				Services: []ecstypes.Service{
					{
						DesiredCount: 1,
						RunningCount: 1,
						PendingCount: 0,
					},
				},
			}, nil
		},
		ListTasksFunc: func(ctx context.Context, params *ecs.ListTasksInput, optFns ...func(*ecs.Options)) (*ecs.ListTasksOutput, error) {
			return &ecs.ListTasksOutput{
				TaskArns: []string{"arn:aws:ecs:us-east-1:123456789012:task/test-task"},
			}, nil
		},
		DescribeTasksFunc: func(ctx context.Context, params *ecs.DescribeTasksInput, optFns ...func(*ecs.Options)) (*ecs.DescribeTasksOutput, error) {
			return &ecs.DescribeTasksOutput{
				Tasks: []ecstypes.Task{
					{
						Attachments: []ecstypes.Attachment{
							{
								Type: aws.String("ElasticNetworkInterface"),
								Details: []ecstypes.KeyValuePair{
									{
										Name:  aws.String("networkInterfaceId"),
										Value: aws.String("eni-12345"),
									},
								},
							},
						},
					},
				},
			}, nil
		},
	}

	mockEC2 := &MockEC2Client{
		DescribeNetworkInterfacesFunc: func(ctx context.Context, params *ec2.DescribeNetworkInterfacesInput, optFns ...func(*ec2.Options)) (*ec2.DescribeNetworkInterfacesOutput, error) {
			return &ec2.DescribeNetworkInterfacesOutput{
				NetworkInterfaces: []ec2types.NetworkInterface{
					{
						Association: &ec2types.NetworkInterfaceAssociation{
							PublicIp: aws.String("203.0.113.42"),
						},
					},
				},
			}, nil
		},
	}

	handler := NewHandlerWithClient(mockECS, mockEC2, "test-cluster", "test-service")

	request := QueryRequest{
		InstanceID: "test-instance-123",
	}

	response, err := handler.handleQueryRequest(context.Background(), request)
	if err != nil {
		t.Fatalf("Expected no error, got %v", err)
	}

	if response.Status != "ready" {
		t.Errorf("Expected status 'ready', got '%s'", response.Status)
	}

	if response.PublicIP != "203.0.113.42" {
		t.Errorf("Expected public IP '203.0.113.42', got '%s'", response.PublicIP)
	}

	if response.Message != "Service is running and ready" {
		t.Errorf("Expected message 'Service is running and ready', got '%s'", response.Message)
	}
}

func TestQueryHandler_MissingInstanceID(t *testing.T) {
	handler := NewHandlerWithClient(&MockECSClient{}, &MockEC2Client{}, "test-cluster", "test-service")

	request := QueryRequest{
		InstanceID: "", // Missing instance ID
	}

	_, err := handler.handleQueryRequest(context.Background(), request)
	if err == nil {
		t.Fatal("Expected error for missing instance_id, got nil")
	}

	expectedError := "instance_id is required"
	if err.Error() != expectedError {
		t.Errorf("Expected error '%s', got '%s'", expectedError, err.Error())
	}
}

func TestQueryHandler_FunctionURL(t *testing.T) {
	mockECS := &MockECSClient{
		DescribeServicesFunc: func(ctx context.Context, params *ecs.DescribeServicesInput, optFns ...func(*ecs.Options)) (*ecs.DescribeServicesOutput, error) {
			return &ecs.DescribeServicesOutput{
				Services: []ecstypes.Service{
					{
						DesiredCount: 0,
						RunningCount: 0,
						PendingCount: 0,
					},
				},
			}, nil
		},
	}

	handler := NewHandlerWithClient(mockECS, &MockEC2Client{}, "test-cluster", "test-service")

	// Test Function URL format
	event := map[string]interface{}{
		"body": `{"instance_id":"test-instance-123"}`,
	}

	result, err := handler.HandleRequest(context.Background(), event)
	if err != nil {
		t.Fatalf("Expected no error, got %v", err)
	}

	// Parse the result
	var response FunctionURLResponse
	resultBytes, _ := json.Marshal(result)
	json.Unmarshal(resultBytes, &response)

	if response.StatusCode != 200 {
		t.Errorf("Expected status code 200, got %d", response.StatusCode)
	}

	var queryResponse QueryResponse
	json.Unmarshal([]byte(response.Body), &queryResponse)

	if queryResponse.Status != "negative" {
		t.Errorf("Expected status 'negative', got '%s'", queryResponse.Status)
	}
}
