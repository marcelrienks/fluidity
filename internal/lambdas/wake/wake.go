package wake

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"fluidity/internal/shared/logger"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	"github.com/aws/aws-sdk-go-v2/service/ecs"
)

// WakeRequest represents the input to the Wake Lambda
type WakeRequest struct {
	ClusterName string `json:"cluster_name,omitempty"`
	ServiceName string `json:"service_name,omitempty"`
}

// WakeResponse represents the output from the Wake Lambda
type WakeResponse struct {
	Status             string `json:"status"`
	DesiredCount       int32  `json:"desiredCount"`
	RunningCount       int32  `json:"runningCount"`
	PendingCount       int32  `json:"pendingCount"`
	EstimatedStartTime string `json:"estimatedStartTime,omitempty"`
	PublicIP           string `json:"public_ip,omitempty"`
	Message            string `json:"message"`
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
	UpdateService(ctx context.Context, params *ecs.UpdateServiceInput, optFns ...func(*ecs.Options)) (*ecs.UpdateServiceOutput, error)
	ListTasks(ctx context.Context, params *ecs.ListTasksInput, optFns ...func(*ecs.Options)) (*ecs.ListTasksOutput, error)
	DescribeTasks(ctx context.Context, params *ecs.DescribeTasksInput, optFns ...func(*ecs.Options)) (*ecs.DescribeTasksOutput, error)
}

// EC2Client interface for testing
type EC2Client interface {
	DescribeNetworkInterfaces(ctx context.Context, params *ec2.DescribeNetworkInterfacesInput, optFns ...func(*ec2.Options)) (*ec2.DescribeNetworkInterfacesOutput, error)
}

// Handler processes wake requests
type Handler struct {
	ecsClient   ECSClient
	ec2Client   EC2Client
	clusterName string
	serviceName string
	logger      *logger.Logger
}

// NewHandler creates a new wake handler with AWS SDK clients
func NewHandler(ctx context.Context, clusterName, serviceName string) (*Handler, error) {
	log := logger.NewFromEnv()

	log.Info("Initializing Wake Lambda handler", map[string]interface{}{
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

	log.Info("Wake Lambda handler initialized successfully")

	return &Handler{
		ecsClient:   ecs.NewFromConfig(cfg),
		ec2Client:   ec2.NewFromConfig(cfg),
		clusterName: clusterName,
		serviceName: serviceName,
		logger:      log,
	}, nil
}

// NewHandlerWithClient creates a new wake handler with a provided ECS client (for testing)
func NewHandlerWithClient(ecsClient ECSClient, ec2Client EC2Client, clusterName, serviceName string) *Handler {
	return &Handler{
		ecsClient:   ecsClient,
		ec2Client:   ec2Client,
		clusterName: clusterName,
		serviceName: serviceName,
		logger:      logger.New("info"),
	}
}

// HandleRequest processes the wake request for Lambda Function URL
// Event can be either JSON body or API Gateway Proxy format
func (h *Handler) HandleRequest(ctx context.Context, event interface{}) (interface{}, error) {
	var request WakeRequest

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

	response, err := h.handleWakeRequest(ctx, request)
	if err != nil {
		h.logger.Error("Wake request failed", err)
		return h.errorResponse(500, err.Error()), nil
	}

	// Return Function URL response format
	return h.successResponse(response), nil
}

// handleWakeRequest contains the core wake logic
func (h *Handler) handleWakeRequest(ctx context.Context, request WakeRequest) (*WakeResponse, error) {
	// Allow request to override cluster/service names (for testing)
	clusterName := h.clusterName
	if request.ClusterName != "" {
		clusterName = request.ClusterName
	}

	serviceName := h.serviceName
	if request.ServiceName != "" {
		serviceName = request.ServiceName
	}

	h.logger.Info("Processing wake request", map[string]interface{}{
		"clusterName": clusterName,
		"serviceName": serviceName,
	})

	// Step 1: Describe the current service state
	describeInput := &ecs.DescribeServicesInput{
		Cluster:  aws.String(clusterName),
		Services: []string{serviceName},
	}

	h.logger.Debug("Describing ECS service state")
	describeOutput, err := h.ecsClient.DescribeServices(ctx, describeInput)
	if err != nil {
		h.logger.Error("Failed to describe ECS service", err, map[string]interface{}{
			"clusterName": clusterName,
			"serviceName": serviceName,
		})
		return nil, fmt.Errorf("failed to describe ECS service: %w", err)
	}

	if len(describeOutput.Services) == 0 {
		h.logger.Error("ECS service not found", nil, map[string]interface{}{
			"clusterName": clusterName,
			"serviceName": serviceName,
		})
		return nil, fmt.Errorf("service %s not found in cluster %s", serviceName, clusterName)
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

	// Step 2: Check if service is already running or starting
	if desiredCount > 0 {
		status := "already_running"
		message := fmt.Sprintf("Service already has desiredCount=%d", desiredCount)

		if runningCount == 0 && pendingCount > 0 {
			status = "starting"
			message = fmt.Sprintf("Service is starting (desiredCount=%d, pendingCount=%d)", desiredCount, pendingCount)
			h.logger.Info("Service is already starting", map[string]interface{}{
				"desiredCount": desiredCount,
				"pendingCount": pendingCount,
			})
		} else if runningCount > 0 {
			message = fmt.Sprintf("Service is running (desiredCount=%d, runningCount=%d)", desiredCount, runningCount)
			h.logger.Info("Service is already running", map[string]interface{}{
				"desiredCount": desiredCount,
				"runningCount": runningCount,
			})
		}

		// Try to get the public IP if service is running
		publicIP, err := h.getServicePublicIP(ctx, clusterName, serviceName)
		if err != nil {
			h.logger.Warn("Failed to get public IP for running service", map[string]interface{}{
				"clusterName": clusterName,
				"serviceName": serviceName,
				"error":       err.Error(),
			})
		}

		return &WakeResponse{
			Status:       status,
			DesiredCount: desiredCount,
			RunningCount: runningCount,
			PendingCount: pendingCount,
			PublicIP:     publicIP,
			Message:      message,
		}, nil
	}

	// Step 3: Service is stopped (desiredCount=0), start it
	h.logger.Info("Service is stopped, initiating wake", map[string]interface{}{
		"clusterName": clusterName,
		"serviceName": serviceName,
	})

	updateInput := &ecs.UpdateServiceInput{
		Cluster:      aws.String(clusterName),
		Service:      aws.String(serviceName),
		DesiredCount: aws.Int32(1),
	}

	_, err = h.ecsClient.UpdateService(ctx, updateInput)
	if err != nil {
		h.logger.Error("Failed to update ECS service", err, map[string]interface{}{
			"clusterName": clusterName,
			"serviceName": serviceName,
		})
		return nil, fmt.Errorf("failed to update ECS service: %w", err)
	}

	// Estimate start time based on Fargate cold start (typically 60-90 seconds)
	estimatedStartTime := time.Now().Add(75 * time.Second).Format(time.RFC3339)

	h.logger.Info("Service wake initiated successfully", map[string]interface{}{
		"estimatedStartTime": estimatedStartTime,
	})

	return &WakeResponse{
		Status:             "waking",
		DesiredCount:       1,
		RunningCount:       0,
		PendingCount:       0,
		EstimatedStartTime: estimatedStartTime,
		Message:            "Service wake initiated. ECS task starting (estimated 60-90 seconds)",
	}, nil
}

// getServicePublicIP retrieves the public IP address of the running ECS service
func (h *Handler) getServicePublicIP(ctx context.Context, clusterName, serviceName string) (string, error) {
	// List tasks for the service
	listTasksInput := &ecs.ListTasksInput{
		Cluster:     aws.String(clusterName),
		ServiceName: aws.String(serviceName),
	}

	h.logger.Debug("Listing tasks for service", map[string]interface{}{
		"clusterName": clusterName,
		"serviceName": serviceName,
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
		Cluster: aws.String(clusterName),
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
		"clusterName": clusterName,
		"serviceName": serviceName,
		"publicIP":    publicIP,
	})

	return publicIP, nil
}

// successResponse wraps the wake response in Function URL format
func (h *Handler) successResponse(data *WakeResponse) FunctionURLResponse {
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
