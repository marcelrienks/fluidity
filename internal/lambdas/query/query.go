package query

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"fluidity/internal/shared/certs"
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

// QueryResponse represents the direct JSON response from Query Lambda
type QueryResponse struct {
	Status   string `json:"status"` // "negative", "pending", "ready"
	PublicIP string `json:"public_ip,omitempty"`
	Message  string `json:"message"`
	// New field for ARN-based certificate generation
	ServerARN string `json:"server_arn,omitempty"`
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

	if clusterName == "" {
		log.Error("Missing required parameter: clusterName", nil)
		return nil, fmt.Errorf("clusterName is required")
	}

	if serviceName == "" {
		log.Error("Missing required parameter: serviceName", nil)
		return nil, fmt.Errorf("serviceName is required")
	}

	cfg, err := config.LoadDefaultConfig(ctx)
	if err != nil {
		log.Error("Failed to load AWS SDK config", err)
		return nil, fmt.Errorf("unable to load AWS SDK config: %w", err)
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

// NewHandlerWithClient creates a new query handler with provided clients (for testing)
func NewHandlerWithClient(ecsClient ECSClient, ec2Client EC2Client, clusterName, serviceName string) *Handler {
	return &Handler{
		ecsClient:   ecsClient,
		ec2Client:   ec2Client,
		clusterName: clusterName,
		serviceName: serviceName,
		logger:      logger.New("info"),
	}
}

// HandleRequest processes the query request
// Receives direct JSON from Lambda Function URL or direct invocation
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
	h.logger.Info("Processing query request", map[string]interface{}{
		"instanceID": request.InstanceID,
	})

	if request.InstanceID == "" {
		return nil, fmt.Errorf("instance_id is required")
	}

	// Discover server ARN
	serverARN, err := certs.DiscoverServerARN()
	if err != nil {
		h.logger.Warn("Failed to discover server ARN, will continue without it", map[string]interface{}{
			"error": err.Error(),
		})
	} else {
		h.logger.Info("Discovered server ARN", map[string]interface{}{
			"serverARN": serverARN,
		})
	}

	// Parse instance ID to get cluster and service names
	// Format: {clusterName}-{serviceName}-{timestamp}
	parts := strings.Split(request.InstanceID, "-")
	if len(parts) < 3 {
		h.logger.Error("Invalid instance ID format", fmt.Errorf("invalid instance ID format"), map[string]interface{}{
			"instanceID": request.InstanceID,
		})
		return nil, fmt.Errorf("invalid instance ID format")
	}

	// Parse instance ID format: {cluster}-{service}-{timestamp}
	// For now, assume the format is {cluster}-{service}-{timestamp}
	timestamp := parts[len(parts)-1]
	clusterName := strings.Join(parts[:len(parts)-2], "-")
	serviceName := parts[len(parts)-2]

	h.logger.Debug("Parsed instance ID", map[string]interface{}{
		"instanceID":  request.InstanceID,
		"clusterName": clusterName,
		"serviceName": serviceName,
		"timestamp":   timestamp,
	})

	// Allow request to override cluster/service names (for testing)
	if h.clusterName != "" {
		clusterName = h.clusterName
	}
	if h.serviceName != "" {
		serviceName = h.serviceName
	}

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
		return &QueryResponse{
			Status:    "negative",
			Message:   "ECS service not found",
			ServerARN: serverARN,
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

	// Step 2: Check service status
	if desiredCount == 0 {
		return &QueryResponse{
			Status:    "negative",
			Message:   "Service is stopped (desiredCount=0)",
			ServerARN: serverARN,
		}, nil
	}

	if runningCount == 0 && pendingCount > 0 {
		return &QueryResponse{
			Status:    "pending",
			Message:   fmt.Sprintf("Service is starting (pendingCount=%d)", pendingCount),
			ServerARN: serverARN,
		}, nil
	}

	if runningCount == 0 {
		return &QueryResponse{
			Status:    "negative",
			Message:   "Service failed to start (runningCount=0)",
			ServerARN: serverARN,
		}, nil
	}

	// Step 3: Service is running, get the public IP
	h.logger.Info("Service is running, retrieving public IP", map[string]interface{}{
		"runningCount": runningCount,
	})

	publicIP, err := h.getPublicIPForService(ctx, clusterName, serviceName)
	if err != nil {
		h.logger.Error("Failed to get public IP", err, map[string]interface{}{
			"clusterName": clusterName,
			"serviceName": serviceName,
		})
		return nil, fmt.Errorf("failed to get public IP: %w", err)
	}

	if publicIP == "" {
		return &QueryResponse{
			Status:    "pending",
			Message:   "Service is running but public IP not yet available",
			ServerARN: serverARN,
		}, nil
	}

	h.logger.Info("Successfully retrieved public IP", map[string]interface{}{
		"publicIP": publicIP,
	})

	return &QueryResponse{
		Status:    "ready",
		PublicIP:  publicIP,
		Message:   "Service is running and ready",
		ServerARN: serverARN,
	}, nil
}

// getPublicIPForService retrieves the public IP address of the running ECS service
func (h *Handler) getPublicIPForService(ctx context.Context, clusterName, serviceName string) (string, error) {
	// List tasks for the service
	listTasksInput := &ecs.ListTasksInput{
		Cluster:     aws.String(clusterName),
		ServiceName: aws.String(serviceName),
	}

	h.logger.Debug("Listing tasks for service")
	listTasksOutput, err := h.ecsClient.ListTasks(ctx, listTasksInput)
	if err != nil {
		return "", fmt.Errorf("failed to list tasks: %w", err)
	}

	if len(listTasksOutput.TaskArns) == 0 {
		return "", fmt.Errorf("no tasks found for service")
	}

	// Describe the first task (assuming single task service)
	describeTasksInput := &ecs.DescribeTasksInput{
		Cluster: aws.String(clusterName),
		Tasks:   []string{listTasksOutput.TaskArns[0]},
	}

	h.logger.Debug("Describing task")
	describeTasksOutput, err := h.ecsClient.DescribeTasks(ctx, describeTasksInput)
	if err != nil {
		return "", fmt.Errorf("failed to describe tasks: %w", err)
	}

	if len(describeTasksOutput.Tasks) == 0 {
		return "", fmt.Errorf("no task details found")
	}

	task := describeTasksOutput.Tasks[0]

	// Find the Elastic Network Interface attachment
	var networkInterfaceID string
	for _, attachment := range task.Attachments {
		if attachment.Type != nil && *attachment.Type == "ElasticNetworkInterface" {
			for _, detail := range attachment.Details {
				if detail.Name != nil && *detail.Name == "networkInterfaceId" {
					networkInterfaceID = *detail.Value
					break
				}
			}
			if networkInterfaceID != "" {
				break
			}
		}
	}

	if networkInterfaceID == "" {
		return "", fmt.Errorf("no network interface found for task")
	}

	h.logger.Debug("Found network interface", map[string]interface{}{
		"networkInterfaceID": networkInterfaceID,
	})

	// Describe the network interface to get the public IP
	describeNIInput := &ec2.DescribeNetworkInterfacesInput{
		NetworkInterfaceIds: []string{networkInterfaceID},
	}

	h.logger.Debug("Describing network interface")
	describeNIOutput, err := h.ec2Client.DescribeNetworkInterfaces(ctx, describeNIInput)
	if err != nil {
		return "", fmt.Errorf("failed to describe network interface: %w", err)
	}

	if len(describeNIOutput.NetworkInterfaces) == 0 {
		return "", fmt.Errorf("network interface not found")
	}

	networkInterface := describeNIOutput.NetworkInterfaces[0]
	if networkInterface.Association == nil || networkInterface.Association.PublicIp == nil {
		return "", nil // No public IP assigned yet
	}

	return *networkInterface.Association.PublicIp, nil
}

// successResponse wraps the response in Function URL format
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
