package agent

import "fmt"

// Config holds agent configuration
type Config struct {
	ServerIP           string `mapstructure:"server_ip" yaml:"server_ip"`
	ServerPort         int    `mapstructure:"server_port" yaml:"server_port"`
	LocalProxyPort     int    `mapstructure:"local_proxy_port" yaml:"local_proxy_port"`
	CertFile           string `mapstructure:"cert_file" yaml:"cert_file"`
	KeyFile            string `mapstructure:"key_file" yaml:"key_file"`
	CACertFile         string `mapstructure:"ca_cert_file" yaml:"ca_cert_file"`
	LogLevel           string `mapstructure:"log_level" yaml:"log_level"`
	SecretsManagerName string `mapstructure:"secrets_manager_name" yaml:"secrets_manager_name"`
	UseSecretsManager  bool   `mapstructure:"use_secrets_manager" yaml:"use_secrets_manager"`
	WakeEndpoint       string `mapstructure:"wake_endpoint" yaml:"wake_endpoint"`
	QueryEndpoint      string `mapstructure:"query_endpoint" yaml:"query_endpoint"`
	KillEndpoint       string `mapstructure:"kill_endpoint" yaml:"kill_endpoint"`
	IAMRoleARN         string `mapstructure:"iam_role_arn" yaml:"iam_role_arn"`
	AWSRegion          string `mapstructure:"aws_region" yaml:"aws_region"`
}

// GetServerAddress returns the full server address
func (c *Config) GetServerAddress() string {
	return fmt.Sprintf("%s:%d", c.ServerIP, c.ServerPort)
}

// SetServerIP sets the server IP address
func (c *Config) SetServerIP(ip string) {
	c.ServerIP = ip
}
