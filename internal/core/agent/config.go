package agent

import "fmt"

// Config holds agent configuration
// Dynamic certificate generation is the only supported mode
type Config struct {
	// Server discovery endpoints (required)
	WakeEndpoint  string `mapstructure:"wake_endpoint" yaml:"wake_endpoint"`
	QueryEndpoint string `mapstructure:"query_endpoint" yaml:"query_endpoint"`
	KillEndpoint  string `mapstructure:"kill_endpoint" yaml:"kill_endpoint"`

	// Dynamic certificate generation (required)
	CAServiceURL string `mapstructure:"ca_service_url" yaml:"ca_service_url"`
	CertCacheDir string `mapstructure:"cert_cache_dir" yaml:"cert_cache_dir"`
	CACertFile   string `mapstructure:"ca_cert_file" yaml:"ca_cert_file"`

	// Tunnel settings
	ServerIP       string `mapstructure:"server_ip" yaml:"server_ip"`
	ServerPort     int    `mapstructure:"server_port" yaml:"server_port"`
	LocalProxyPort int    `mapstructure:"local_proxy_port" yaml:"local_proxy_port"`

	// Logging
	LogLevel string `mapstructure:"log_level" yaml:"log_level"`

	// ARN-based certificate fields (populated by Wake/Query Lambdas)
	ServerARN      string `mapstructure:"server_arn" yaml:"server_arn"`
	ServerPublicIP string `mapstructure:"server_public_ip" yaml:"server_public_ip"`
	AgentPublicIP  string `mapstructure:"agent_public_ip" yaml:"agent_public_ip"`
}

// GetServerAddress returns the full server address
func (c *Config) GetServerAddress() string {
	return fmt.Sprintf("%s:%d", c.ServerIP, c.ServerPort)
}

// SetServerIP sets the server IP address
func (c *Config) SetServerIP(ip string) {
	c.ServerIP = ip
}
