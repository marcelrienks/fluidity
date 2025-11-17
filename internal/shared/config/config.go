package config

import (
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

	// Set config file
	if configFile != "" {
		v.SetConfigFile(configFile)
	} else {
		// Look for config in installation directory (same location as binary)
		// This is the standard location set by the deployment script
		exePath, err := os.Executable()
		if err != nil {
			return nil, fmt.Errorf("failed to determine binary location: %w", err)
		}
		exeDir := filepath.Dir(exePath)
		configPath := filepath.Join(exeDir, "agent.yaml")
		v.SetConfigFile(configPath)
	}

	// Set defaults
	setDefaults(v)

	// Read config file (required - config must be in installation directory)
	if err := v.ReadInConfig(); err != nil {
		if _, ok := err.(viper.ConfigFileNotFoundError); !ok {
			return nil, fmt.Errorf("failed to read config file: %w", err)
		}
		return nil, fmt.Errorf("configuration file not found at expected location. The binary expects 'agent.yaml' in the same directory as the executable")
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
