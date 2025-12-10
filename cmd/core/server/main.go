package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/spf13/cobra"

	"fluidity/internal/core/server"
	"fluidity/internal/shared/certs"
	"fluidity/internal/shared/config"
	"fluidity/internal/shared/logging"
)

var (
	configFile string
	listenAddr string
	listenPort int
	maxConnections int
	logLevel   string
)

func main() {
	// Note: GODEBUG must be set BEFORE the Go runtime initializes
	// Use run-server-debug.cmd to launch with TLS debug logging enabled

	rootCmd := &cobra.Command{
		Use:   "fluidity-server",
		Short: "Fluidity tunnel server",
		Long:  "Fluidity tunnel server - Accepts secure connections from agents and forwards HTTP requests",
		RunE:  runServer,
	}

	rootCmd.Flags().StringVarP(&configFile, "config", "c", "", "Configuration file path")
	rootCmd.Flags().StringVar(&listenAddr, "listen-addr", "", "Address to listen on")
	rootCmd.Flags().IntVar(&listenPort, "listen-port", 0, "Port to listen on")
	rootCmd.Flags().IntVar(&maxConnections, "max-connections", 0, "Maximum number of concurrent connections")
	rootCmd.Flags().StringVar(&logLevel, "log-level", "", "Log level (debug, info, warn, error)")

	if err := rootCmd.Execute(); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
}

func runServer(cmd *cobra.Command, args []string) error {
	// Create logger
	logger := logging.NewLogger("server")

	// Build configuration overrides from CLI flags
	overrides := make(map[string]interface{})
	if listenAddr != "" {
		overrides["listen_addr"] = listenAddr
	}
	if listenPort != 0 {
		overrides["listen_port"] = listenPort
	}
	if maxConnections != 0 {
		overrides["max_connections"] = maxConnections
	}
	if logLevel != "" {
		overrides["log_level"] = logLevel
	}

	// Load configuration
	cfg, err := config.LoadConfig[server.Config](configFile, overrides)
	if err != nil {
		return fmt.Errorf("failed to load configuration: %w", err)
	}

	// Set log level
	logger.SetLevel(cfg.LogLevel)

	logger.Info("Starting Fluidity tunnel server",
		"listen_addr", cfg.GetListenAddress(),
		"max_connections", cfg.MaxConnections,
		"log_level", cfg.LogLevel)

	// Dynamic lazy certificate generation is the ONLY supported mode
	if cfg.CAServiceURL == "" {
		return fmt.Errorf("ca_service_url is required - dynamic lazy certificate generation is mandatory")
	}
	if cfg.CertCacheDir == "" {
		return fmt.Errorf("cert_cache_dir is required - dynamic lazy certificate generation is mandatory")
	}

	logger.Info("Using mandatory dynamic lazy certificate generation",
		"ca_url", cfg.CAServiceURL,
		"cache_dir", cfg.CertCacheDir)

	// Discover server ARN (required for ARN-based certificates)
	serverARN, arnErr := certs.DiscoverServerARN()
	if arnErr != nil {
		return fmt.Errorf("failed to discover server ARN (required for dynamic cert generation): %w", arnErr)
	}
	logger.Info("Server ARN discovered", "arn", serverARN)

	// Discover or use explicit SERVER_PUBLIC_IP (required for certificate validation)
	serverPublicIP := os.Getenv("SERVER_PUBLIC_IP")
	if serverPublicIP == "" {
		var ipErr error
		serverPublicIP, ipErr = certs.DiscoverPublicIP()
		if ipErr != nil {
			return fmt.Errorf("failed to discover server public IP and SERVER_PUBLIC_IP env var not set: %w", ipErr)
		}
		logger.Info("Server public IP discovered from metadata", "ip", serverPublicIP)
	} else {
		logger.Info("Using explicit SERVER_PUBLIC_IP from environment", "server_public_ip", serverPublicIP)
	}

	// Initialize certificate manager for lazy generation
	certMgr := server.NewCertManagerWithLazyGen(cfg.CertCacheDir, cfg.CAServiceURL, serverARN, serverPublicIP, logger)
	
	// Initialize the private key at startup
	if keyErr := certMgr.InitializeKey(); keyErr != nil {
		return fmt.Errorf("failed to initialize private key: %w", keyErr)
	}
	logger.Info("Server private key initialized")

	// Store cert manager in config for use during connections
	cfg.CertManager = certMgr

	logger.Info("Server ready for lazy certificate generation on first agent connection",
		"server_arn", serverARN,
		"server_public_ip", serverPublicIP)

	// Create minimal TLS config for wrapping TCP connections
	// Actual certificates will be generated per-connection during TLS handshake
	tlsConfig := &tls.Config{
		ClientAuth: tls.RequireAndVerifyClientCert,
		MinVersion: tls.VersionTLS13,
	}

	// Create tunnel server with cert manager
	logger.Info("Creating server with lazy certificate generation")
	tunnelServer, err := server.NewServerWithCertManager(
		tlsConfig,
		cfg.GetListenAddress(),
		cfg.MaxConnections,
		cfg.LogLevel,
		cfg.CertManager,
		"", // caCertFile not needed since we generate on-the-fly
	)
	
	if err != nil {
		return fmt.Errorf("failed to create tunnel server: %w", err)
	}

	// Create context for graceful shutdown
	_, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Set up signal handling
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	// Start health check HTTP server (port 8080)
	healthMux := http.NewServeMux()
	healthMux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		if err := json.NewEncoder(w).Encode(tunnelServer.GetHealth()); err != nil {
			logger.Error("Failed to encode health response", err)
		}
	})

	healthServer := &http.Server{
		Addr:         ":8080",
		Handler:      healthMux,
		ReadTimeout:  5 * time.Second,
		WriteTimeout: 5 * time.Second,
		IdleTimeout:  10 * time.Second,
	}

	healthErrChan := make(chan error, 1)
	go func() {
		if err := healthServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			healthErrChan <- err
		}
	}()

	logger.Info("Health check server started on", "addr", "localhost:8080")

	// Start server in a goroutine
	serverErrChan := make(chan error, 1)
	go func() {
		if err := tunnelServer.Start(); err != nil {
			serverErrChan <- err
		}
	}()

	logger.Info("Tunnel server started successfully")

	// Wait for shutdown signal or server error
	select {
	case <-sigChan:
		logger.Info("Shutdown signal received, stopping server...")
	case err := <-serverErrChan:
		logger.Error("Server error", err)
		healthServer.Shutdown(context.Background())
		return err
	case err := <-healthErrChan:
		logger.Error("Health server error", err)
		tunnelServer.Stop()
		return err
	}

	// Graceful shutdown
	cancel()

	// Stop health server
	healthShutdownCtx, healthShutdownCancel := context.WithTimeout(context.Background(), 5*time.Second)
	if err := healthServer.Shutdown(healthShutdownCtx); err != nil {
		logger.Warn("Error shutting down health server", err)
	}
	healthShutdownCancel()

	// Stop server
	if err := tunnelServer.Stop(); err != nil {
		logger.Error("Error stopping tunnel server", err)
		return err
	}

	logger.Info("Server stopped")
	return nil
}
