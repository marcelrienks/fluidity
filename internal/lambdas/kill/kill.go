package kill

import (
	"context"
	"encoding/json"
	"fmt"

	"fluidity/internal/shared/logger"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/ecs"
)

// KillRequest represents the input to the Kill Lambda
type KillRequest struct {
	ClusterName string `json:"cluster_name,omitempty"`
	ServiceName string `json:"service_name,omitempty"`
}

// KillResponse represents the output from the Kill Lambda
type KillResponse struct {
	Status       string `json:"status"`
	DesiredCount int32  `json:"desiredCount"`
	Message      string `json:"message"`
}

// FunctionURLResponse wraps the response for Lambda Function URL format
type FunctionURLResponse struct {
	StatusCode int               `json:"statusCode"`
	Headers    map[string]string `json:"headers"`
	Body       string            `json:"body"`
}

// ECSClient interface for testing
type ECSClient interface {
	UpdateService(ctx context.Context, params *ecs.UpdateServiceInput, optFns ...func(*ecs.Options)) (*ecs.UpdateServiceOutput, error)
}

// Handler processes kill requests
type Handler struct {
	ecsClient   ECSClient
	clusterName string
	serviceName string
	logger      *logger.Logger
}

// NewHandler creates a new kill handler with AWS SDK clients
func NewHandler(ctx context.Context, clusterName, serviceName string) (*Handler, error) {
	log := logger.NewFromEnv()

	log.Info("Initializing Kill Lambda handler", map[string]interface{}{
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

	log.Info("Kill Lambda handler initialized successfully")

	return &Handler{
		ecsClient:   ecs.NewFromConfig(cfg),
		clusterName: clusterName,
		serviceName: serviceName,
		logger:      log,
	}, nil
}

// NewHandlerWithClient creates a new kill handler with a provided ECS client (for testing)
func NewHandlerWithClient(ecsClient ECSClient, clusterName, serviceName string) *Handler {
	return &Handler{
		ecsClient:   ecsClient,
		clusterName: clusterName,
		serviceName: serviceName,
		logger:      logger.New("info"),
	}
}

// HandleRequest processes the kill request for Lambda Function URL
// Event can be either JSON body or API Gateway Proxy format
func (h *Handler) HandleRequest(ctx context.Context, event interface{}) (interface{}, error) {
	var request KillRequest

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

	response, err := h.handleKillRequest(ctx, request)
	if err != nil {
		h.logger.Error("Kill request failed", err)
		return h.errorResponse(500, err.Error()), nil
	}

	// Return Function URL response format
	return h.successResponse(response), nil
}

// handleKillRequest contains the core kill logic
func (h *Handler) handleKillRequest(ctx context.Context, request KillRequest) (*KillResponse, error) {
	// Allow request to override cluster/service names (for testing)
	clusterName := h.clusterName
	if request.ClusterName != "" {
		clusterName = request.ClusterName
	}

	serviceName := h.serviceName
	if request.ServiceName != "" {
		serviceName = request.ServiceName
	}

	h.logger.Info("Processing kill request", map[string]interface{}{
		"clusterName": clusterName,
		"serviceName": serviceName,
	})

	// Set desired count to 0 immediately (no checks, no validation)
	updateInput := &ecs.UpdateServiceInput{
		Cluster:      aws.String(clusterName),
		Service:      aws.String(serviceName),
		DesiredCount: aws.Int32(0),
	}

	h.logger.Info("Initiating immediate service shutdown", map[string]interface{}{
		"clusterName": clusterName,
		"serviceName": serviceName,
	})

	_, err := h.ecsClient.UpdateService(ctx, updateInput)
	if err != nil {
		h.logger.Error("Failed to update ECS service", err, map[string]interface{}{
			"clusterName": clusterName,
			"serviceName": serviceName,
		})
		return nil, fmt.Errorf("failed to update ECS service: %w", err)
	}

	h.logger.Info("Service shutdown initiated successfully", map[string]interface{}{
		"desiredCount": 0,
	})

	return &KillResponse{
		Status:       "killed",
		DesiredCount: 0,
		Message:      "Service shutdown initiated. ECS tasks will terminate immediately.",
	}, nil
}

// successResponse wraps the kill response in Function URL format
func (h *Handler) successResponse(data *KillResponse) FunctionURLResponse {
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
