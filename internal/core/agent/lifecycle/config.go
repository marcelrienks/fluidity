package lifecycle

import (
	"context"
	"fmt"
	"os"
	"strconv"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
)

// Config holds lifecycle management configuration
type Config struct {
	// WakeEndpoint is the full URL to the Wake Lambda API endpoint
	WakeEndpoint string

	// KillEndpoint is the full URL to the Kill Lambda API endpoint
	KillEndpoint string

	// IAM configuration (replaces API key)
	IAMRoleARN string
	AWSRegion  string

	// ClusterName is the ECS cluster name
	ClusterName string

	// ServiceName is the ECS service name
	ServiceName string

	// ConnectionTimeout is the timeout for waiting for server connection after wake
	ConnectionTimeout time.Duration

	// ConnectionRetryInterval is the interval between connection retry attempts
	ConnectionRetryInterval time.Duration

	// HTTPTimeout is the timeout for HTTP API calls
	HTTPTimeout time.Duration

	// MaxRetries is the maximum number of retry attempts for API calls
	MaxRetries int

	// Enabled indicates if lifecycle management is enabled
	Enabled bool
}

// LoadConfig loads lifecycle configuration from environment variables
func LoadConfig() (*Config, error) {
	config := &Config{
		WakeEndpoint:            os.Getenv("WAKE_ENDPOINT"),
		KillEndpoint:            os.Getenv("KILL_ENDPOINT"),
		IAMRoleARN:              os.Getenv("IAM_ROLE_ARN"),
		AWSRegion:               getEnvOrDefault("AWS_REGION", ""),
		ClusterName:             getEnvOrDefault("ECS_CLUSTER_NAME", ""),
		ServiceName:             getEnvOrDefault("ECS_SERVICE_NAME", ""),
		ConnectionTimeout:       getEnvDuration("CONNECTION_TIMEOUT", 90*time.Second),
		ConnectionRetryInterval: getEnvDuration("CONNECTION_RETRY_INTERVAL", 5*time.Second),
		HTTPTimeout:             getEnvDuration("HTTP_TIMEOUT", 30*time.Second),
		MaxRetries:              getEnvInt("MAX_RETRIES", 3),
		Enabled:                 getEnvBool("LIFECYCLE_ENABLED", true),
	}

	// Lifecycle is disabled if endpoints are not configured
	if config.WakeEndpoint == "" || config.KillEndpoint == "" {
		config.Enabled = false
	}

	return config, nil
}

// Load loads AWS configuration for IAM authentication
func (c *Config) Load(ctx context.Context) (aws.Config, error) {
	cfg, err := config.LoadDefaultConfig(ctx,
		config.WithRegion(c.AWSRegion),
	)
	if err != nil {
		return aws.Config{}, fmt.Errorf("failed to load AWS config: %w", err)
	}
	return cfg, nil
}

// Validate checks if the configuration is valid
func (c *Config) Validate() error {
	if !c.Enabled {
		return nil
	}

	if c.WakeEndpoint == "" {
		return fmt.Errorf("WAKE_ENDPOINT is required when lifecycle is enabled")
	}

	if c.KillEndpoint == "" {
		return fmt.Errorf("KILL_ENDPOINT is required when lifecycle is enabled")
	}

	// IAM authentication doesn't require explicit validation here
	// AWS SDK will handle credential resolution

	return nil
}

// getEnvOrDefault returns environment variable value or default
func getEnvOrDefault(key, defaultValue string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return defaultValue
}

// getEnvDuration returns environment variable as duration or default
func getEnvDuration(key string, defaultValue time.Duration) time.Duration {
	if value := os.Getenv(key); value != "" {
		if duration, err := time.ParseDuration(value); err == nil {
			return duration
		}
	}
	return defaultValue
}

// getEnvInt returns environment variable as int or default
func getEnvInt(key string, defaultValue int) int {
	if value := os.Getenv(key); value != "" {
		if intValue, err := strconv.Atoi(value); err == nil {
			return intValue
		}
	}
	return defaultValue
}

// getEnvBool returns environment variable as bool or default
func getEnvBool(key string, defaultValue bool) bool {
	if value := os.Getenv(key); value != "" {
		if boolValue, err := strconv.ParseBool(value); err == nil {
			return boolValue
		}
	}
	return defaultValue
}
