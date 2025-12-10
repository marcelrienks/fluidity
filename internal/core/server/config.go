package server

import "fmt"

// Config holds server configuration
// NOTE: Only lazy dynamic certificate generation is supported.
// Static certs, secrets manager, and env var certs are not used.
type Config struct {
	ListenAddr   string `mapstructure:"listen_addr" yaml:"listen_addr"`
	ListenPort   int    `mapstructure:"listen_port" yaml:"listen_port"`
	LogLevel     string `mapstructure:"log_level" yaml:"log_level"`
	MaxConnections int    `mapstructure:"max_connections" yaml:"max_connections"`
	CAServiceURL   string `mapstructure:"ca_service_url" yaml:"ca_service_url"`
	CertCacheDir   string `mapstructure:"cert_cache_dir" yaml:"cert_cache_dir"`
	// CertManager for lazy certificate generation (not serialized)
	CertManager *CertManager `mapstructure:"-" yaml:"-"`
}

// GetListenAddress returns the full listen address
func (c *Config) GetListenAddress() string {
	return fmt.Sprintf("%s:%d", c.ListenAddr, c.ListenPort)
}
