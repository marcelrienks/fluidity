package server

import "fmt"

// Config holds server configuration
// NOTE: Only lazy dynamic certificate generation is supported.
// Server certificate is generated dynamically with agent IPs.
// CA certificate file is required for client certificate verification.
type Config struct {
	ListenAddr     string `mapstructure:"listen_addr" yaml:"listen_addr"`
	ListenPort     int    `mapstructure:"listen_port" yaml:"listen_port"`
	LogLevel       string `mapstructure:"log_level" yaml:"log_level"`
	MaxConnections int    `mapstructure:"max_connections" yaml:"max_connections"`
	CAServiceURL   string `mapstructure:"ca_service_url" yaml:"ca_service_url"`
	CertCacheDir   string `mapstructure:"cert_cache_dir" yaml:"cert_cache_dir"`
	CACertFile     string `mapstructure:"ca_cert_file" yaml:"ca_cert_file"` // Required for client cert verification
	// CertManager for lazy certificate generation (not serialized)
	CertManager *CertManager `mapstructure:"-" yaml:"-"`
}

// GetListenAddress returns the full listen address
func (c *Config) GetListenAddress() string {
	return fmt.Sprintf("%s:%d", c.ListenAddr, c.ListenPort)
}
