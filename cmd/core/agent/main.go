package main

import (
	"context"
	"crypto/tls"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/spf13/cobra"

	"fluidity/internal/core/agent"
	"fluidity/internal/core/agent/lifecycle"
	"fluidity/internal/shared/config"
	"fluidity/internal/shared/logging"
	"fluidity/internal/shared/secretsmanager"
	tlsutil "fluidity/internal/shared/tls"
)

var (
	configFile string
	serverPort int
	proxyPort  int
	logLevel   string
	certFile   string
	keyFile    string
	caCertFile string
)

// getConfigValue returns the first non-empty value
func getConfigValue(envValue, configValue string) string {
	if envValue != "" {
		return envValue
	}
	return configValue
}

func main() {
	// Note: GODEBUG must be set BEFORE the Go runtime initializes
	// Use run-agent-debug.cmd to launch with TLS debug logging enabled

	// Use the actual command name (handles symlinks correctly)
	commandName := filepath.Base(os.Args[0])

	rootCmd := &cobra.Command{
		Use:   commandName,
		Short: "Fluidity tunnel agent",
		Long:  "Fluidity tunnel agent - HTTP proxy that forwards traffic through secure tunnel",
		RunE:  runAgent,
	}

	rootCmd.Flags().StringVarP(&configFile, "config", "c", "", "Configuration file path")
	rootCmd.Flags().IntVar(&serverPort, "server-port", 0, "Tunnel server port")
	rootCmd.Flags().IntVar(&proxyPort, "proxy-port", 0, "Local proxy port")
	rootCmd.Flags().StringVar(&logLevel, "log-level", "", "Log level (debug, info, warn, error)")
	rootCmd.Flags().StringVar(&certFile, "cert", "", "Client certificate file")
	rootCmd.Flags().StringVar(&keyFile, "key", "", "Client private key file")
	rootCmd.Flags().StringVar(&caCertFile, "ca", "", "CA certificate file")

	if err := rootCmd.Execute(); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
}

func runAgent(cmd *cobra.Command, args []string) error {
	// Create logger
	logger := logging.NewLogger("agent")

	// Build configuration overrides from CLI flags
	overrides := make(map[string]interface{})
	if serverPort != 0 {
		overrides["server_port"] = serverPort
	}
	if proxyPort != 0 {
		overrides["local_proxy_port"] = proxyPort
	}
	if logLevel != "" {
		overrides["log_level"] = logLevel
	}
	if certFile != "" {
		overrides["cert_file"] = certFile
	}
	if keyFile != "" {
		overrides["key_file"] = keyFile
	}
	if caCertFile != "" {
		overrides["ca_cert_file"] = caCertFile
	}

	// Load configuration from deployment location
	// The deployment script ensures agent.yaml is in the same directory as the binary
	cfg, err := config.LoadConfig[agent.Config](configFile, overrides)
	if err != nil {
		return fmt.Errorf("failed to load configuration: %w", err)
	}

	// Set log level
	logger.SetLevel(cfg.LogLevel)

	// Track if auto-discovery was performed (which already wakes the service)
	autoDiscovered := false
	var lifecycleClient *lifecycle.Client
	var lifecycleConfig *lifecycle.Config

	// Start server via lifecycle on every agent start
	{
		logger.Info("Starting server via lifecycle wake/query")

		// Load lifecycle configuration from agent config file
		lifecycleConfig = &lifecycle.Config{
			WakeEndpoint:            cfg.WakeEndpoint,
			QueryEndpoint:           cfg.QueryEndpoint,
			KillEndpoint:            cfg.KillEndpoint,
			IAMRoleARN:              cfg.IAMRoleARN,
			AWSRegion:               cfg.AWSRegion,
			ClusterName:             "", // Not used in current implementation
			ServiceName:             "", // Not used in current implementation
			ConnectionTimeout:       90 * time.Second,
			ConnectionRetryInterval: 5 * time.Second,
			HTTPTimeout:             30 * time.Second,
			MaxRetries:              3,
			Enabled:                 true,
		}

		// Lifecycle is disabled if endpoints are not configured
		if lifecycleConfig.WakeEndpoint == "" {
			return fmt.Errorf("lifecycle wake endpoint (WAKE_ENDPOINT) is required in configuration")
		}

		if err := lifecycleConfig.Validate(); err != nil {
			logger.Warn("Lifecycle configuration validation failed", "error", err.Error())
			return fmt.Errorf("lifecycle configuration invalid: fix WAKE/QUERY/KILL endpoints or credentials")
		}

		// Create lifecycle client
		lifecycleClient, err = lifecycle.NewClient(lifecycleConfig, logger)
		if err != nil {
			return fmt.Errorf("failed to create lifecycle client for IP discovery: %w", err)
		}

		// Call wake to get server IP
		wakeCtx, wakeCancel := context.WithTimeout(context.Background(), 180*time.Second)
		defer wakeCancel()

		if err := lifecycleClient.WakeAndGetIP(wakeCtx, cfg); err != nil {
			return fmt.Errorf("failed to auto-discover server IP: %w", err)
		}

		logger.Info("Started server via lifecycle", "server_ip", cfg.ServerIP)
		autoDiscovered = true
	}

	// Ensure lifecycle Kill is attempted on exit or error
	defer func() {
		if lifecycleClient != nil {
			logger.Info("Ensuring lifecycle Kill on exit")
			killCtx, killCancel := context.WithTimeout(context.Background(), 30*time.Second)
			if kerr := lifecycleClient.Kill(killCtx); kerr != nil {
				logger.Warn("Failed to kill ECS service", "error", kerr.Error())
			}
			killCancel()
		}
	}()

	logger.Info("Starting Fluidity tunnel agent",
		"server", cfg.GetServerAddress(),
		"proxy_port", cfg.LocalProxyPort,
		"log_level", cfg.LogLevel)

	// Load TLS configuration (with Secrets Manager support if enabled)
	var tlsConfig *tls.Config

	if cfg.UseSecretsManager && cfg.SecretsManagerName != "" {
		logger.Info("Using AWS Secrets Manager for TLS certificates",
			"secret_name", cfg.SecretsManagerName)
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		var tlsErr error
		tlsConfig, tlsErr = secretsmanager.LoadTLSConfigFromSecretsOrFallback(
			ctx,
			cfg.SecretsManagerName,
			cfg.CertFile,
			cfg.KeyFile,
			cfg.CACertFile,
			false, // isServer
			func() (*tls.Config, error) {
				return tlsutil.LoadClientTLSConfig(cfg.CertFile, cfg.KeyFile, cfg.CACertFile)
			},
		)
		if tlsErr != nil {
			return fmt.Errorf("failed to load TLS configuration: %w", tlsErr)
		}
	} else {
		logger.Info("Using local files for TLS certificates")
		var tlsErr error
		tlsConfig, tlsErr = tlsutil.LoadClientTLSConfig(cfg.CertFile, cfg.KeyFile, cfg.CACertFile)
		if tlsErr != nil {
			return fmt.Errorf("failed to load TLS configuration: %w", tlsErr)
		}
	}

	logger.Info("Loaded TLS configuration",
		"cert_file", cfg.CertFile,
		"key_file", cfg.KeyFile,
		"ca_file", cfg.CACertFile)

	// If auto-discovery didn't start service, call Wake before connecting
	if !autoDiscovered {
		logger.Info("Lifecycle management enabled, waking ECS service")
		wakeCtx, wakeCancel := context.WithTimeout(context.Background(), 30*time.Second)
		_, err := lifecycleClient.Wake(wakeCtx)
		if err != nil {
			// Log warning but continue - fallback to connecting without wake
			logger.Warn("Failed to wake ECS service, continuing anyway", "error", err.Error())
		}
		wakeCancel()
	}

	// Create tunnel client
	tunnelClient := agent.NewClient(tlsConfig, cfg.GetServerAddress(), cfg.LogLevel)

	// Create proxy server
	proxyServer := agent.NewServer(cfg.LocalProxyPort, tunnelClient, cfg.LogLevel)

	// Create context for graceful shutdown
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Set up signal handling
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	// Start proxy server
	if err := proxyServer.Start(); err != nil {
		return fmt.Errorf("failed to start proxy server: %w", err)
	}

	// Connection management goroutine
	go func() {
		// Wait for server connection after wake
		if lifecycleClient != nil {
			logger.Info("Waiting for server connection after wake")
			waitCtx, waitCancel := context.WithTimeout(ctx, lifecycleConfig.ConnectionTimeout)
			err := lifecycleClient.WaitForConnection(waitCtx, func() bool {
				return tunnelClient.IsConnected()
			})
			waitCancel()

			if err != nil {
				logger.Warn("Server connection wait timeout, will continue with normal connection retry", "error", err.Error())
			}
		}

		// Simple logic: if connection fails, immediately wake a new server for this agent
		// Each agent gets its own dedicated server instance

		for {
			select {
			case <-ctx.Done():
				return
			default:
			}

			// Connect to tunnel server
			if !tunnelClient.IsConnected() {
				logger.Info("Attempting to connect to tunnel server", "server_ip", cfg.ServerIP)
				if err := tunnelClient.Connect(); err != nil {
					// Do not attempt to start a new server here — the server was started at agent startup.
					logger.Error("Failed to connect to tunnel server, exiting", err)
					// cancel context and notify main loop to perform shutdown and lifecycle kill
					cancel()
					// notify main waiter
					sigChan <- syscall.SIGTERM
					return
				}
				// Successful connection
				logger.Info("Successfully connected to tunnel server", "server_ip", cfg.ServerIP)
			}

			// Wait for disconnection or shutdown
			select {
			case <-tunnelClient.ReconnectChannel():
				logger.Warn("Connection lost, will attempt to reconnect")
				time.Sleep(2 * time.Second)
			case <-ctx.Done():
				return
			}
		}
	}()

	// Wait for shutdown signal
	<-sigChan
	logger.Info("Shutdown signal received, stopping agent...")

	// Graceful shutdown
	cancel()

	// If lifecycle is enabled, call Kill API
	if lifecycleClient != nil && lifecycleConfig.Enabled {
		logger.Info("Calling Kill API for graceful ECS service shutdown")
		killCtx, killCancel := context.WithTimeout(context.Background(), 30*time.Second)
		if err := lifecycleClient.Kill(killCtx); err != nil {
			logger.Warn("Failed to kill ECS service", "error", err.Error())
		}
		killCancel()
	}

	// Stop proxy server
	if err := proxyServer.Stop(); err != nil {
		logger.Error("Error stopping proxy server", err)
	}

	// Disconnect tunnel client
	if err := tunnelClient.Disconnect(); err != nil {
		logger.Error("Error disconnecting tunnel client", err)
	}

	logger.Info("Agent stopped")
	return nil
}
