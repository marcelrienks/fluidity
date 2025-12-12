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
)

var (
	configFile string
	serverPort int
	proxyPort  int
	logLevel   string
)

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

	if err := rootCmd.Execute(); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
}

func runAgent(cmd *cobra.Command, args []string) error {
	// Create logger
	logger := logging.NewLogger("agent")

	// If no config file specified, auto-discover it in the binary's directory
	if configFile == "" {
		exePath, err := os.Executable()
		if err == nil {
			exeDir := filepath.Dir(exePath)
			defaultConfig := filepath.Join(exeDir, "agent.yaml")
			if _, err := os.Stat(defaultConfig); err == nil {
				configFile = defaultConfig
				logger.Debug("Using default config file from binary directory", "path", configFile)
			}
		}
	}

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
			ClusterName:             "", // Not used in current implementation
			ServiceName:             "", // Not used in current implementation
			ConnectionTimeout:       30 * time.Second,
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

	// Use dynamic certificate generation (only supported mode)
	logger.Info("Using dynamic certificate generation",
		"ca_url", cfg.CAServiceURL,
		"cache_dir", cfg.CertCacheDir)

	var certMgr *agent.CertManager
	var tlsConfig *tls.Config
	var certFile, keyFile string

	// Use ARN-based certificate manager if ARN fields are available from Wake Lambda
	if cfg.ServerARN != "" && cfg.AgentPublicIP != "" {
		logger.Info("Using ARN-based certificate generation",
			"server_arn", cfg.ServerARN,
			"agent_public_ip", cfg.AgentPublicIP)
		certMgr = agent.NewCertManagerWithARN(cfg.CertCacheDir, cfg.CAServiceURL, cfg.ServerARN, cfg.AgentPublicIP, logger)
	} else {
		logger.Info("Using legacy certificate generation (ARN not available)")
		certMgr = agent.NewCertManager(cfg.CertCacheDir, cfg.CAServiceURL, logger)
	}

	certCtx, certCancel := context.WithTimeout(context.Background(), 30*time.Second)
	var certErr error
	certFile, keyFile, certErr = certMgr.EnsureCertificate(certCtx)
	certCancel()
	if certErr != nil {
		return fmt.Errorf("failed to ensure certificate: %w", certErr)
	}

	var tlsErr error
	tlsConfig, tlsErr = certMgr.GetTLSConfig(cfg.CACertFile)
	if tlsErr != nil {
		return fmt.Errorf("failed to create TLS config from dynamic certificate: %w", tlsErr)
	}

	logger.Info("Loaded TLS configuration",
		"cert_file", certFile,
		"key_file", keyFile,
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

	// Set server ARN for certificate validation if available
	if cfg.ServerARN != "" {
		tunnelClient.SetServerARN(cfg.ServerARN, cfg.ServerPublicIP)
		logger.Info("Configured ARN-based certificate validation",
			"server_arn", cfg.ServerARN,
			"server_public_ip", cfg.ServerPublicIP)
	}

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
		// Connect to tunnel server (single attempt, no retries)
		logger.Info("Connecting to tunnel server", "server_ip", cfg.ServerIP, "server_port", cfg.ServerPort, "server_address", cfg.GetServerAddress())
		logger.Debug("Connection configuration", "tls_min_version", "1.3", "tls_cert_file", certFile, "tls_key_file", keyFile, "tls_ca_file", cfg.CACertFile)
		if err := tunnelClient.Connect(); err != nil {
			logger.Error("Failed to establish tunnel connection to server, exiting", err, "server_ip", cfg.ServerIP, "server_port", cfg.ServerPort)
			cancel()
			sigChan <- syscall.SIGTERM
			return
		}

		logger.Info("Successfully connected to tunnel server", "server_ip", cfg.ServerIP)
		logger.Info("Agent ready for receiving proxy requests", "listen_addr", fmt.Sprintf("http://127.0.0.1:%d", cfg.LocalProxyPort))

		// Wait for disconnection or shutdown
		select {
		case <-tunnelClient.ReconnectChannel():
			logger.Error("Tunnel connection lost, exiting", fmt.Errorf("connection disconnected"))
			cancel()
			sigChan <- syscall.SIGTERM
		case <-ctx.Done():
			return
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
