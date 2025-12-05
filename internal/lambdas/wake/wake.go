package wake

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"fluidity/internal/shared/logger"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/ecs"
)

// WakeRequest represents the input to the Wake Lambda
type WakeRequest struct {
	ClusterName string `json:"cluster_name,omitempty"`
	ServiceName string `json:"service_name,omitempty"`
}

// WakeResponse represents the direct JSON response from Wake Lambda
type WakeResponse struct {
	Status             string `json:"status"`
	InstanceID         string `json:"instance_id"`
	DesiredCount       int32  `json:"desiredCount"`
	RunningCount       int32  `json:"runningCount"`
	PendingCount       int32  `json:"pendingCount"`
	EstimatedStartTime string `json:"estimatedStartTime,omitempty"`
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
}

// Handler processes wake requests
type Handler struct {
	ecsClient   ECSClient
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
		clusterName: clusterName,
		serviceName: serviceName,
		logger:      log,
	}, nil
}

// NewHandlerWithClient creates a new wake handler with a provided ECS client (for testing)
func NewHandlerWithClient(ecsClient ECSClient, clusterName, serviceName string) *Handler {
	return &Handler{
		ecsClient:   ecsClient,
		clusterName: clusterName,
		serviceName: serviceName,
		logger:      logger.New("info"),
	}
}

// HandleRequest processes the wake request
// Receives direct JSON from Lambda Function URL or direct invocation
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

	// Step 2: Always increment the desired count to allow multiple instances
	newDesiredCount := desiredCount + 1

	h.logger.Info("Incrementing service desired count", map[string]interface{}{
		"clusterName":    clusterName,
		"serviceName":    serviceName,
		"currentDesired": desiredCount,
		"newDesired":     newDesiredCount,
		"runningCount":   runningCount,
		"pendingCount":   pendingCount,
	})

	updateInput := &ecs.UpdateServiceInput{
		Cluster:      aws.String(clusterName),
		Service:      aws.String(serviceName),
		DesiredCount: aws.Int32(newDesiredCount),
	}

	_, err = h.ecsClient.UpdateService(ctx, updateInput)
	if err != nil {
		h.logger.Error("Failed to update ECS service", err, map[string]interface{}{
			"clusterName": clusterName,
			"serviceName": serviceName,
		})
		return nil, fmt.Errorf("failed to update ECS service: %w", err)
	}

	// Generate instance ID for this service instance
	instanceID := h.generateInstanceID(clusterName, serviceName)

	// Determine status based on current state
	status := "waking"
	message := fmt.Sprintf("Service desired count incremented to %d", newDesiredCount)
	estimatedStartTime := ""

	if runningCount > 0 {
		status = "scaling"
		message = fmt.Sprintf("Service scaling up (desiredCount=%d, runningCount=%d)", newDesiredCount, runningCount)
		h.logger.Info("Service is scaling up", map[string]interface{}{
			"desiredCount": newDesiredCount,
			"runningCount": runningCount,
		})
	} else if pendingCount > 0 {
		status = "starting"
		message = fmt.Sprintf("Service is starting additional instances (desiredCount=%d, pendingCount=%d)", newDesiredCount, pendingCount)
		h.logger.Info("Service is starting additional instances", map[string]interface{}{
			"desiredCount": newDesiredCount,
			"pendingCount": pendingCount,
		})
	} else {
		// Estimate start time based on Fargate cold start (typically 60-90 seconds)
		estimatedStartTime = time.Now().Add(75 * time.Second).Format(time.RFC3339)
		message = "Service wake initiated. ECS task starting (estimated 60-90 seconds)"
		h.logger.Info("Service wake initiated successfully", map[string]interface{}{
			"instanceID":         instanceID,
			"estimatedStartTime": estimatedStartTime,
		})
	}

	return &WakeResponse{
		Status:             status,
		InstanceID:         instanceID,
		DesiredCount:       newDesiredCount,
		RunningCount:       runningCount,
		PendingCount:       pendingCount,
		EstimatedStartTime: estimatedStartTime,
		Message:            message,
	}, nil
}

// generateInstanceID creates a unique identifier for this service instance
func (h *Handler) generateInstanceID(clusterName, serviceName string) string {
	// Use timestamp + cluster + service to create a unique instance ID
	timestamp := time.Now().Unix()
	return fmt.Sprintf("%s-%s-%d", clusterName, serviceName, timestamp)
}

// successResponse wraps the response in Function URL format
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

// errorResponse creates an error response in Function URL format
func (h *Handler) errorResponse(statusCode int, message string) FunctionURLResponse {
	errorResp := map[string]string{"error": message}
	body, _ := json.Marshal(errorResp)
	return FunctionURLResponse{
		StatusCode: statusCode,
		Headers: map[string]string{
			"Content-Type": "application/json",
		},
		Body: string(body),
	}
}
