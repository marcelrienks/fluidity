package query

import (
	"context"
	"encoding/json"
	"fmt"

	"fluidity/internal/shared/logger"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	"github.com/aws/aws-sdk-go-v2/service/ecs"
)

// QueryRequest represents the input to the Query Lambda
type QueryRequest struct {
	InstanceID string `json:"instance_id"`
}

// QueryResponse represents the output from the Query Lambda
type QueryResponse struct {
	Status   string `json:"status"` // "negative", "pending", "ready"
	PublicIP string `json:"public_ip,omitempty"`
	Message  string `json:"message"`
}

// FunctionURLResponse wraps the response for Lambda Function URL format
type FunctionURLResponse struct {
	StatusCode int               `json:"statusCode"`
	Headers    map[string]string `json:"headers"`
	Body       string            `json:"body"`
}

// ECSClient interface for testing
type ECSClient interface {
	DescribeServices(ctx context.Context, params *ecs.DescribeServicesInput, optFns ...func(*ecs.Options)) (*ecs.DescribeServicesOutput, error)
	ListTasks(ctx context.Context, params *ecs.ListTasksInput, optFns ...func(*ecs.Options)) (*ecs.ListTasksOutput, error)
	DescribeTasks(ctx context.Context, params *ecs.DescribeTasksInput, optFns ...func(*ecs.Options)) (*ecs.DescribeTasksOutput, error)
}

// EC2Client interface for testing
type EC2Client interface {
	DescribeNetworkInterfaces(ctx context.Context, params *ec2.DescribeNetworkInterfacesInput, optFns ...func(*ec2.Options)) (*ec2.DescribeNetworkInterfacesOutput, error)
}

// Handler processes query requests
type Handler struct {
	ecsClient   ECSClient
	ec2Client   EC2Client
	clusterName string
	serviceName string
	logger      *logger.Logger
}

// NewHandler creates a new query handler with AWS SDK clients
func NewHandler(ctx context.Context, clusterName, serviceName string) (*Handler, error) {
	log := logger.NewFromEnv()

	log.Info("Initializing Query Lambda handler", map[string]interface{}{
		"clusterName": clusterName,
		"serviceName": serviceName,
	})

	cfg, err := config.LoadDefaultConfig(ctx)
	if err != nil {
		log.Error("Failed to load AWS SDK config", err)
		return nil, fmt.Errorf("unable to load AWS SDK config: %w", err)
	}

	if clusterName == "" {
		log.Error("Missing required parameter: clusterName", nil)
		return nil, fmt.Errorf("clusterName is required")
	}

	if serviceName == "" {
		log.Error("Missing required parameter: serviceName", nil)
		return nil, fmt.Errorf("serviceName is required")
	}

	log.Info("Query Lambda handler initialized successfully")

	return &Handler{
		ecsClient:   ecs.NewFromConfig(cfg),
		ec2Client:   ec2.NewFromConfig(cfg),
		clusterName: clusterName,
		serviceName: serviceName,
		logger:      log,
	}, nil
}

// NewHandlerWithClient creates a new query handler with a provided ECS client (for testing)
func NewHandlerWithClient(ecsClient ECSClient, ec2Client EC2Client, clusterName, serviceName string) *Handler {
	return &Handler{
		ecsClient:   ecsClient,
		ec2Client:   ec2Client,
		clusterName: clusterName,
		serviceName: serviceName,
		logger:      logger.New("info"),
	}
}

// HandleRequest processes the query request for Lambda Function URL
func (h *Handler) HandleRequest(ctx context.Context, event interface{}) (interface{}, error) {
	var request QueryRequest

	// Parse the event - could be direct JSON or wrapped in Function URL event
	switch e := event.(type) {
	case map[string]interface{}:
		// Try to unmarshal as request body first
		if body, ok := e["body"]; ok {
			// Lambda Function URL passes raw JSON body
			if bodyStr, ok := body.(string); ok {
				if err := json.Unmarshal([]byte(bodyStr), &request); err != nil {
					h.logger.Error("Failed to unmarshal body from event", err)
					return h.errorResponse(400, "Invalid JSON in request body"), nil
				}
			}
		} else {
			// Direct JSON invocation
			data, err := json.Marshal(e)
			if err != nil {
				h.logger.Error("Failed to marshal event", err)
				return h.errorResponse(400, "Invalid request format"), nil
			}
			if err := json.Unmarshal(data, &request); err != nil {
				h.logger.Error("Failed to unmarshal event", err)
				return h.errorResponse(400, "Invalid request format"), nil
			}
		}
	case string:
		// Raw JSON string
		if err := json.Unmarshal([]byte(e), &request); err != nil {
			h.logger.Error("Failed to unmarshal JSON string", err)
			return h.errorResponse(400, "Invalid JSON in request body"), nil
		}
	case []byte:
		// Raw bytes
		if err := json.Unmarshal(e, &request); err != nil {
			h.logger.Error("Failed to unmarshal bytes", err)
			return h.errorResponse(400, "Invalid JSON in request body"), nil
		}
	}

	response, err := h.handleQueryRequest(ctx, request)
	if err != nil {
		h.logger.Error("Query request failed", err)
		return h.errorResponse(500, err.Error()), nil
	}

	// Return Function URL response format
	return h.successResponse(response), nil
}

// handleQueryRequest contains the core query logic
func (h *Handler) handleQueryRequest(ctx context.Context, request QueryRequest) (*QueryResponse, error) {
	if request.InstanceID == "" {
		h.logger.Error("Missing required parameter: instance_id", nil)
		return nil, fmt.Errorf("instance_id is required")
	}

	h.logger.Info("Processing query request", map[string]interface{}{
		"instanceID": request.InstanceID,
	})

	// Step 1: Describe the current service state
	describeInput := &ecs.DescribeServicesInput{
		Cluster:  aws.String(h.clusterName),
		Services: []string{h.serviceName},
	}

	h.logger.Debug("Describing ECS service state")
	describeOutput, err := h.ecsClient.DescribeServices(ctx, describeInput)
	if err != nil {
		h.logger.Error("Failed to describe ECS service", err, map[string]interface{}{
			"clusterName": h.clusterName,
			"serviceName": h.serviceName,
		})
		return nil, fmt.Errorf("failed to describe ECS service: %w", err)
	}

	if len(describeOutput.Services) == 0 {
		h.logger.Error("ECS service not found", nil, map[string]interface{}{
			"clusterName": h.clusterName,
			"serviceName": h.serviceName,
		})
		return &QueryResponse{
			Status:  "negative",
			Message: "ECS service not found",
		}, nil
	}

	service := describeOutput.Services[0]
	desiredCount := service.DesiredCount
	runningCount := service.RunningCount
	pendingCount := service.PendingCount

	h.logger.Debug("Current service state", map[string]interface{}{
		"desiredCount": desiredCount,
		"runningCount": runningCount,
		"pendingCount": pendingCount,
	})

	// Step 2: Check if service is stopped (desiredCount=0)
	if desiredCount == 0 {
		h.logger.Info("Service is stopped", map[string]interface{}{
			"instanceID": request.InstanceID,
		})
		return &QueryResponse{
			Status:  "negative",
			Message: "Service is stopped (desiredCount=0)",
		}, nil
	}

	// Step 3: Check if service is starting (desiredCount > 0 but no running tasks)
	if runningCount == 0 && pendingCount > 0 {
		h.logger.Info("Service is starting", map[string]interface{}{
			"instanceID":   request.InstanceID,
			"pendingCount": pendingCount,
		})
		return &QueryResponse{
			Status:  "pending",
			Message: fmt.Sprintf("Service is starting (pendingCount=%d)", pendingCount),
		}, nil
	}

	// Step 4: Check if service is running but no tasks found
	if runningCount == 0 && pendingCount == 0 {
		h.logger.Info("Service has desiredCount > 0 but no running or pending tasks", map[string]interface{}{
			"instanceID":   request.InstanceID,
			"desiredCount": desiredCount,
		})
		return &QueryResponse{
			Status:  "negative",
			Message: "Service has desiredCount > 0 but no running or pending tasks",
		}, nil
	}

	// Step 5: Service is running, try to get the public IP
	publicIP, err := h.getServicePublicIP(ctx)
	if err != nil {
		h.logger.Warn("Failed to get public IP for running service", map[string]interface{}{
			"instanceID": request.InstanceID,
			"error":      err.Error(),
		})
		// If we can't get the IP but service is running, consider it pending
		return &QueryResponse{
			Status:  "pending",
			Message: "Service is running but IP not yet available",
		}, nil
	}

	h.logger.Info("Service is ready with public IP", map[string]interface{}{
		"instanceID": request.InstanceID,
		"publicIP":   publicIP,
	})

	return &QueryResponse{
		Status:   "ready",
		PublicIP: publicIP,
		Message:  "Service is running and ready",
	}, nil
}

// getServicePublicIP retrieves the public IP address of the running ECS service
func (h *Handler) getServicePublicIP(ctx context.Context) (string, error) {
	// List tasks for the service
	listTasksInput := &ecs.ListTasksInput{
		Cluster:     aws.String(h.clusterName),
		ServiceName: aws.String(h.serviceName),
	}

	h.logger.Debug("Listing tasks for service", map[string]interface{}{
		"clusterName": h.clusterName,
		"serviceName": h.serviceName,
	})

	listTasksOutput, err := h.ecsClient.ListTasks(ctx, listTasksInput)
	if err != nil {
		return "", fmt.Errorf("failed to list tasks: %w", err)
	}

	if len(listTasksOutput.TaskArns) == 0 {
		return "", fmt.Errorf("no tasks found for service")
	}

	// Describe the first task (should be the only one for our service)
	describeTasksInput := &ecs.DescribeTasksInput{
		Cluster: aws.String(h.clusterName),
		Tasks:   []string{listTasksOutput.TaskArns[0]},
	}

	h.logger.Debug("Describing task", map[string]interface{}{
		"taskArn": listTasksOutput.TaskArns[0],
	})

	describeTasksOutput, err := h.ecsClient.DescribeTasks(ctx, describeTasksInput)
	if err != nil {
		return "", fmt.Errorf("failed to describe task: %w", err)
	}

	if len(describeTasksOutput.Tasks) == 0 {
		return "", fmt.Errorf("task not found")
	}

	task := describeTasksOutput.Tasks[0]

	// Extract network interface ID from task attachments
	var eniID string
	for _, attachment := range task.Attachments {
		if attachment.Type != nil && *attachment.Type == "ElasticNetworkInterface" {
			for _, detail := range attachment.Details {
				if detail.Name != nil && *detail.Name == "networkInterfaceId" && detail.Value != nil {
					eniID = *detail.Value
					break
				}
			}
		}
		if eniID != "" {
			break
		}
	}

	if eniID == "" {
		return "", fmt.Errorf("no network interface found for task")
	}

	h.logger.Debug("Found network interface", map[string]interface{}{
		"eniId": eniID,
	})

	// Describe the network interface to get the public IP
	describeENIInput := &ec2.DescribeNetworkInterfacesInput{
		NetworkInterfaceIds: []string{eniID},
	}

	describeENIOutput, err := h.ec2Client.DescribeNetworkInterfaces(ctx, describeENIInput)
	if err != nil {
		return "", fmt.Errorf("failed to describe network interface: %w", err)
	}

	if len(describeENIOutput.NetworkInterfaces) == 0 {
		return "", fmt.Errorf("network interface not found")
	}

	eni := describeENIOutput.NetworkInterfaces[0]
	if eni.Association == nil || eni.Association.PublicIp == nil {
		return "", fmt.Errorf("no public IP associated with network interface")
	}

	publicIP := *eni.Association.PublicIp
	h.logger.Info("Retrieved public IP for service", map[string]interface{}{
		"clusterName": h.clusterName,
		"serviceName": h.serviceName,
		"publicIP":    publicIP,
	})

	return publicIP, nil
}

// successResponse wraps the query response in Function URL format
func (h *Handler) successResponse(data *QueryResponse) FunctionURLResponse {
	body, _ := json.Marshal(data)
	return FunctionURLResponse{
		StatusCode: 200,
		Headers: map[string]string{
			"Content-Type": "application/json",
		},
		Body: string(body),
	}
}

// errorResponse returns an error response in Function URL format
func (h *Handler) errorResponse(statusCode int, message string) FunctionURLResponse {
	body := map[string]string{"error": message}
	bodyBytes, _ := json.Marshal(body)
	return FunctionURLResponse{
		StatusCode: statusCode,
		Headers: map[string]string{
			"Content-Type": "application/json",
		},
		Body: string(bodyBytes),
	}
}
