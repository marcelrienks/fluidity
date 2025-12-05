package config

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"

	"github.com/spf13/viper"
	"gopkg.in/yaml.v3"
)

// LoadConfig loads configuration with CLI override support
func LoadConfig[T any](configFile string, overrides map[string]interface{}) (*T, error) {
	// Initialize viper
	v := viper.New()

	// Set defaults first
	setDefaults(v)

	// Try to load config file if path is provided
	if configFile != "" {
		configData, err := os.ReadFile(configFile)
		if err != nil {
			return nil, fmt.Errorf("failed to read config file: %w", err)
		}
		v.SetConfigType("yaml")
		if err := v.ReadConfig(bytes.NewReader(configData)); err != nil {
			return nil, fmt.Errorf("failed to parse config file: %w", err)
		}
	} else {
		// No config file specified - check if one exists in installation directory
		exePath, err := os.Executable()
		if err == nil {
			exeDir := filepath.Dir(exePath)
			configPath := filepath.Join(exeDir, "agent.yaml")
			if _, err := os.Stat(configPath); err == nil {
				// Config file exists, try to read it
				configData, err := os.ReadFile(configPath)
				if err != nil {
					return nil, fmt.Errorf("failed to read config file: %w", err)
				}
				v.SetConfigType("yaml")
				if err := v.ReadConfig(bytes.NewReader(configData)); err != nil {
					return nil, fmt.Errorf("failed to parse config file: %w", err)
				}
			}
			// If config file doesn't exist, just use defaults
		}
		// If we can't determine exe path, just use defaults
	}

	// Apply CLI overrides
	for key, value := range overrides {
		if value != nil {
			v.Set(key, value)
		}
	}

	// Environment variable support
	v.AutomaticEnv()
	v.SetEnvPrefix("FLUIDITY")

	var config T
	if err := v.Unmarshal(&config); err != nil {
		return nil, fmt.Errorf("failed to unmarshal config: %w", err)
	}

	return &config, nil
}

// SaveConfig saves updated configuration
func SaveConfig(configFile string, config interface{}) error {
	// Create directory if it doesn't exist
	dir := filepath.Dir(configFile)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return fmt.Errorf("failed to create config directory: %w", err)
	}

	// Marshal the provided config directly as YAML
	data, err := yaml.Marshal(config)
	if err != nil {
		return fmt.Errorf("failed to marshal config: %w", err)
	}

	if err := os.WriteFile(configFile, data, 0644); err != nil {
		return fmt.Errorf("failed to write config file: %w", err)
	}
	return nil
}

// setDefaults sets default configuration values
func setDefaults(v *viper.Viper) {
	// Agent defaults
	v.SetDefault("agent.local_proxy_port", 8080)
	v.SetDefault("agent.server_port", 8443)
	v.SetDefault("agent.log_level", "info")
	v.SetDefault("agent.cert_file", "./certs/client.crt")
	v.SetDefault("agent.key_file", "./certs/client.key")
	v.SetDefault("agent.ca_cert_file", "./certs/ca.crt")

	// Server defaults
	v.SetDefault("server.listen_addr", "0.0.0.0")
	v.SetDefault("server.listen_port", 8443)
	v.SetDefault("server.log_level", "info")
	v.SetDefault("server.cert_file", "./certs/server.crt")
	v.SetDefault("server.key_file", "./certs/server.key")
	v.SetDefault("server.ca_cert_file", "./certs/ca.crt")
	v.SetDefault("server.max_connections", 100)
}
