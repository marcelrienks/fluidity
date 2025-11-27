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

	// Parse event as JSON
	data, err := json.Marshal(event)
	if err != nil {
		h.logger.Error("Failed to marshal event", err)
		return map[string]string{"error": "Invalid request format"}, fmt.Errorf("invalid request: %w", err)
	}

	if err := json.Unmarshal(data, &request); err != nil {
		h.logger.Error("Failed to unmarshal event", err)
		return map[string]string{"error": "Invalid JSON in request body"}, fmt.Errorf("invalid json: %w", err)
	}

	response, err := h.handleWakeRequest(ctx, request)
	if err != nil {
		h.logger.Error("Wake request failed", err)
		return map[string]string{"error": err.Error()}, fmt.Errorf("wake failed: %w", err)
	}

	// Return direct JSON response
	return response, nil
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

		// Generate instance ID for this service instance
		instanceID := h.generateInstanceID(clusterName, serviceName)

		return &WakeResponse{
			Status:       status,
			InstanceID:   instanceID,
			DesiredCount: desiredCount,
			RunningCount: runningCount,
			PendingCount: pendingCount,
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

	// Generate instance ID for this service instance
	instanceID := h.generateInstanceID(clusterName, serviceName)

	// Estimate start time based on Fargate cold start (typically 60-90 seconds)
	estimatedStartTime := time.Now().Add(75 * time.Second).Format(time.RFC3339)

	h.logger.Info("Service wake initiated successfully", map[string]interface{}{
		"instanceID":         instanceID,
		"estimatedStartTime": estimatedStartTime,
	})

	return &WakeResponse{
		Status:             "waking",
		InstanceID:         instanceID,
		DesiredCount:       1,
		RunningCount:       0,
		PendingCount:       0,
		EstimatedStartTime: estimatedStartTime,
		Message:            "Service wake initiated. ECS task starting (estimated 60-90 seconds)",
	}, nil
}

// generateInstanceID creates a unique identifier for this service instance
func (h *Handler) generateInstanceID(clusterName, serviceName string) string {
	// Use timestamp + cluster + service to create a unique instance ID
	timestamp := time.Now().Unix()
	return fmt.Sprintf("%s-%s-%d", clusterName, serviceName, timestamp)
}
