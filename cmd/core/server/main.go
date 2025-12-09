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
	"fluidity/internal/shared/config"
	"fluidity/internal/shared/logging"
	"fluidity/internal/shared/secretsmanager"
	tlsutil "fluidity/internal/shared/tls"
)

var (
	configFile     string
	listenAddr     string
	listenPort     int
	maxConnections int
	logLevel       string
	certFile       string
	keyFile        string
	caCertFile     string
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
	rootCmd.Flags().StringVar(&certFile, "cert", "", "Server certificate file")
	rootCmd.Flags().StringVar(&keyFile, "key", "", "Server private key file")
	rootCmd.Flags().StringVar(&caCertFile, "ca", "", "CA certificate file")

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
	if certFile != "" {
		overrides["cert_file"] = certFile
	}
	if keyFile != "" {
		overrides["key_file"] = keyFile
	}
	if caCertFile != "" {
		overrides["ca_cert_file"] = caCertFile
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

	// Load TLS configuration (with dynamic certificate support)
	var tlsConfig *tls.Config
	var certFileUsed, keyFileUsed string

	// First, check if certificates are provided via environment variables (from ECS Secrets)
	certPEM := os.Getenv("CERT_PEM")
	keyPEM := os.Getenv("KEY_PEM")
	caPEM := os.Getenv("CA_PEM")

	if certPEM != "" && keyPEM != "" && caPEM != "" {
		logger.Info("Using TLS certificates from environment variables (ECS Secrets)")
		var tlsErr error
		tlsConfig, tlsErr = tlsutil.LoadServerTLSConfigFromPEM(
			[]byte(certPEM),
			[]byte(keyPEM),
			[]byte(caPEM),
		)
		if tlsErr != nil {
			return fmt.Errorf("failed to load TLS configuration from environment variables: %w", tlsErr)
		}
		certFileUsed = "environment variable (CERT_PEM)"
		keyFileUsed = "environment variable (KEY_PEM)"
	} else if cfg.UseDynamicCerts && cfg.CAServiceURL != "" {
		logger.Info("Using dynamic certificate generation",
			"ca_url", cfg.CAServiceURL,
			"cache_dir", cfg.CertCacheDir)

		certMgr := server.NewCertManager(cfg.CertCacheDir, cfg.CAServiceURL, logger)
		certCtx, certCancel := context.WithTimeout(context.Background(), 30*time.Second)
		var certErr error
		certFileUsed, keyFileUsed, certErr = certMgr.EnsureCertificate(certCtx)
		certCancel()
		if certErr != nil {
			return fmt.Errorf("failed to ensure certificate: %w", certErr)
		}

		var tlsErr error
		tlsConfig, tlsErr = certMgr.GetTLSConfig(cfg.CACertFile)
		if tlsErr != nil {
			return fmt.Errorf("failed to create TLS config from dynamic certificate: %w", tlsErr)
		}
	} else if cfg.UseSecretsManager && cfg.SecretsManagerName != "" {
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
			true, // isServer
			func() (*tls.Config, error) {
				return tlsutil.LoadServerTLSConfig(cfg.CertFile, cfg.KeyFile, cfg.CACertFile)
			},
		)
		if tlsErr != nil {
			return fmt.Errorf("failed to load TLS configuration: %w", tlsErr)
		}
		certFileUsed = cfg.CertFile
		keyFileUsed = cfg.KeyFile
	} else {
		logger.Info("Using local files for TLS certificates")
		var tlsErr error
		tlsConfig, tlsErr = tlsutil.LoadServerTLSConfig(cfg.CertFile, cfg.KeyFile, cfg.CACertFile)
		if tlsErr != nil {
			return fmt.Errorf("failed to load TLS configuration: %w", tlsErr)
		}
		certFileUsed = cfg.CertFile
		keyFileUsed = cfg.KeyFile
	}

	logger.Info("Loaded TLS configuration",
		"cert_file", certFileUsed,
		"key_file", keyFileUsed,
		"ca_file", cfg.CACertFile)

	// Create tunnel server
	tunnelServer, err := server.NewServer(tlsConfig, cfg.GetListenAddress(), cfg.MaxConnections, cfg.LogLevel)
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
