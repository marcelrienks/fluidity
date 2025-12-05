package main

import (
	"context"
	"fmt"
	"os"

	"fluidity/internal/lambdas/query"

	"github.com/aws/aws-lambda-go/lambda"
)

func main() {
	// Get cluster and service names from environment variables
	clusterName := os.Getenv("ECS_CLUSTER_NAME")
	if clusterName == "" {
		fmt.Println("Error: ECS_CLUSTER_NAME environment variable is required")
		os.Exit(1)
	}

	serviceName := os.Getenv("ECS_SERVICE_NAME")
	if serviceName == "" {
		fmt.Println("Error: ECS_SERVICE_NAME environment variable is required")
		os.Exit(1)
	}

	// Initialize handler once at cold start
	handler, err := query.NewHandler(context.Background(), clusterName, serviceName)
	if err != nil {
		fmt.Printf("Failed to initialize handler: %v\n", err)
		os.Exit(1)
	}

	// Start Lambda runtime
	lambda.Start(handler.HandleRequest)
}
