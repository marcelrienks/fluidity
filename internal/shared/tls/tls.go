package tls

import (
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"net"
	"os"

	"github.com/sirupsen/logrus"
)

// LoadClientTLSConfig loads client-side mTLS configuration
func LoadClientTLSConfig(certFile, keyFile, caFile string) (*tls.Config, error) {
	// Load client certificate
	cert, err := tls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		return nil, fmt.Errorf("failed to load client certificate: %w", err)
	}

	// Parse the certificate to log details
	if len(cert.Certificate) > 0 {
		x509Cert, err := x509.ParseCertificate(cert.Certificate[0])
		if err == nil {
			logrus.WithFields(logrus.Fields{
				"subject":    x509Cert.Subject.CommonName,
				"issuer":     x509Cert.Issuer.CommonName,
				"not_before": x509Cert.NotBefore,
				"not_after":  x509Cert.NotAfter,
			}).Info("Loaded client certificate")
		}
	}

	// Load CA certificate
	caCert, err := os.ReadFile(caFile)
	if err != nil {
		return nil, fmt.Errorf("failed to load CA certificate: %w", err)
	}

	caCertPool := x509.NewCertPool()
	if !caCertPool.AppendCertsFromPEM(caCert) {
		return nil, fmt.Errorf("failed to parse CA certificate")
	}

	config := &tls.Config{
		Certificates: []tls.Certificate{cert},
		RootCAs:      caCertPool,
		MinVersion:   tls.VersionTLS13, // Enforce TLS 1.3 (matches docs)
		ServerName:   "",               // Will be set dynamically
	}

	logrus.WithFields(logrus.Fields{
		"num_certificates": len(config.Certificates),
		"has_root_cas":     config.RootCAs != nil,
		"min_version":      "TLS 1.3",
	}).Info("Created client TLS config")

	return config, nil
}

// LoadServerTLSConfig loads server-side mTLS configuration
func LoadServerTLSConfig(certFile, keyFile, caFile string) (*tls.Config, error) {
	// Load server certificate
	cert, err := tls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		return nil, fmt.Errorf("failed to load server certificate: %w", err)
	}

	// Load CA certificate for client verification
	caCert, err := os.ReadFile(caFile)
	if err != nil {
		return nil, fmt.Errorf("failed to load CA certificate: %w", err)
	}

	caCertPool := x509.NewCertPool()
	if !caCertPool.AppendCertsFromPEM(caCert) {
		return nil, fmt.Errorf("failed to parse CA certificate")
	}

	config := &tls.Config{
		Certificates: []tls.Certificate{cert},
		ClientAuth:   tls.RequireAndVerifyClientCert,
		ClientCAs:    caCertPool,
		MinVersion:   tls.VersionTLS13, // Enforce TLS 1.3 (matches docs)
	}

	logrus.WithFields(logrus.Fields{
		"num_certificates": len(config.Certificates),
		"client_auth":      "RequireAndVerifyClientCert",
		"has_client_cas":   config.ClientCAs != nil,
		"min_version":      "TLS 1.3",
	}).Info("Created server TLS config")

	return config, nil
}

// LoadServerTLSConfigFromPEM loads server-side mTLS configuration from PEM bytes (e.g., from environment variables)
func LoadServerTLSConfigFromPEM(certPEM, keyPEM, caPEM []byte) (*tls.Config, error) {
	// Load server certificate from PEM bytes
	cert, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		return nil, fmt.Errorf("failed to load server certificate from PEM: %w", err)
	}

	// Create CA cert pool from PEM bytes
	caCertPool := x509.NewCertPool()
	if !caCertPool.AppendCertsFromPEM(caPEM) {
		return nil, fmt.Errorf("failed to parse CA certificate from PEM")
	}

	config := &tls.Config{
		Certificates: []tls.Certificate{cert},
		ClientAuth:   tls.RequireAndVerifyClientCert,
		ClientCAs:    caCertPool,
		MinVersion:   tls.VersionTLS13, // Enforce TLS 1.3 (matches docs)
	}

	logrus.WithFields(logrus.Fields{
		"num_certificates": len(config.Certificates),
		"client_auth":      "RequireAndVerifyClientCert",
		"has_client_cas":   config.ClientCAs != nil,
		"min_version":      "TLS 1.3",
		"source":           "PEM bytes (environment variables)",
	}).Info("Created server TLS config")

	return config, nil
}

// GetCertificateInfo extracts certificate information for logging
func GetCertificateInfo(cert *x509.Certificate) map[string]interface{} {
	return map[string]interface{}{
		"subject":    cert.Subject.CommonName,
		"issuer":     cert.Issuer.CommonName,
		"serial":     cert.SerialNumber.String(),
		"not_before": cert.NotBefore,
		"not_after":  cert.NotAfter,
	}
}

// ValidateServerCertificateARN validates that the server certificate CN matches expected ARN
// This is called by the agent to validate the server's identity
func ValidateServerCertificateARN(cert *x509.Certificate, expectedARN string) error {
	if cert == nil {
		return fmt.Errorf("certificate is nil")
	}

	cn := cert.Subject.CommonName
	
	// Check if CN matches the expected server ARN
	if cn != expectedARN {
		return fmt.Errorf("server certificate CN mismatch: expected '%s', got '%s'", expectedARN, cn)
	}

	logrus.WithFields(logrus.Fields{
		"expected_arn": expectedARN,
		"actual_cn":    cn,
	}).Debug("Server certificate ARN validation passed")

	return nil
}

// ValidateServerCertificateIP validates that the target IP is in the server certificate SAN
// This is called by the agent to ensure the IP being connected to is authorized
func ValidateServerCertificateIP(cert *x509.Certificate, targetIP string) error {
	if cert == nil {
		return fmt.Errorf("certificate is nil")
	}

	// Parse target IP
	target := net.ParseIP(targetIP)
	if target == nil {
		return fmt.Errorf("invalid target IP: %s", targetIP)
	}

	// Check if target IP is in the certificate SAN
	for _, ip := range cert.IPAddresses {
		if ip.Equal(target) {
			logrus.WithFields(logrus.Fields{
				"target_ip": targetIP,
				"san_ips":   len(cert.IPAddresses),
			}).Debug("Server certificate IP validation passed")
			return nil
		}
	}

	// Log all IPs in SAN for debugging
	sanIPs := make([]string, len(cert.IPAddresses))
	for i, ip := range cert.IPAddresses {
		sanIPs[i] = ip.String()
	}

	return fmt.Errorf("target IP '%s' not found in server certificate SAN (available: %v)", targetIP, sanIPs)
}

// ValidateClientCertificateARN validates that the client certificate CN matches expected server ARN
// This is called by the server to validate the agent's certificate
func ValidateClientCertificateARN(cert *x509.Certificate, expectedServerARN string) error {
	if cert == nil {
		return fmt.Errorf("certificate is nil")
	}

	cn := cert.Subject.CommonName

	// Client certificate should have the server's ARN as CN
	if cn != expectedServerARN {
		return fmt.Errorf("client certificate CN mismatch: expected server ARN '%s', got '%s'", expectedServerARN, cn)
	}

	logrus.WithFields(logrus.Fields{
		"expected_server_arn": expectedServerARN,
		"actual_cn":           cn,
	}).Debug("Client certificate ARN validation passed")

	return nil
}

// ValidateClientCertificateIP validates that the source IP is in the client certificate SAN
// This is called by the server to ensure the connecting IP is authorized
func ValidateClientCertificateIP(cert *x509.Certificate, sourceIP string) error {
	if cert == nil {
		return fmt.Errorf("certificate is nil")
	}

	// Parse source IP
	source := net.ParseIP(sourceIP)
	if source == nil {
		return fmt.Errorf("invalid source IP: %s", sourceIP)
	}

	// Check if source IP is in the certificate SAN
	for _, ip := range cert.IPAddresses {
		if ip.Equal(source) {
			logrus.WithFields(logrus.Fields{
				"source_ip": sourceIP,
				"san_ips":   len(cert.IPAddresses),
			}).Debug("Client certificate IP validation passed")
			return nil
		}
	}

	// Log all IPs in SAN for debugging
	sanIPs := make([]string, len(cert.IPAddresses))
	for i, ip := range cert.IPAddresses {
		sanIPs[i] = ip.String()
	}

	return fmt.Errorf("source IP '%s' not found in client certificate SAN (available: %v)", sourceIP, sanIPs)
}

// CreateARNValidatingClientConfig creates a TLS config with ARN validation for the agent
func CreateARNValidatingClientConfig(certFile, keyFile, caFile, serverARN, targetIP string) (*tls.Config, error) {
	baseConfig, err := LoadClientTLSConfig(certFile, keyFile, caFile)
	if err != nil {
		return nil, err
	}

	// Add custom verification function
	baseConfig.VerifyPeerCertificate = func(rawCerts [][]byte, verifiedChains [][]*x509.Certificate) error {
		if len(verifiedChains) == 0 || len(verifiedChains[0]) == 0 {
			return fmt.Errorf("no verified certificate chains")
		}

		serverCert := verifiedChains[0][0]

		// Validate server ARN
		if err := ValidateServerCertificateARN(serverCert, serverARN); err != nil {
			return fmt.Errorf("server ARN validation failed: %w", err)
		}

		// Validate target IP in SAN
		if err := ValidateServerCertificateIP(serverCert, targetIP); err != nil {
			return fmt.Errorf("server IP validation failed: %w", err)
		}

		logrus.Info("Server certificate validation passed (ARN + IP)")
		return nil
	}

	logrus.WithFields(logrus.Fields{
		"server_arn": serverARN,
		"target_ip":  targetIP,
	}).Info("Created ARN-validating client TLS config")

	return baseConfig, nil
}

// CreateARNValidatingServerConfig creates a TLS config with ARN validation for the server
func CreateARNValidatingServerConfig(certFile, keyFile, caFile, serverARN string) (*tls.Config, error) {
	baseConfig, err := LoadServerTLSConfig(certFile, keyFile, caFile)
	if err != nil {
		return nil, err
	}

	// Add custom verification function
	baseConfig.VerifyPeerCertificate = func(rawCerts [][]byte, verifiedChains [][]*x509.Certificate) error {
		if len(verifiedChains) == 0 || len(verifiedChains[0]) == 0 {
			return fmt.Errorf("no verified certificate chains")
		}

		clientCert := verifiedChains[0][0]

		// Validate client certificate ARN (should be server's ARN)
		if err := ValidateClientCertificateARN(clientCert, serverARN); err != nil {
			return fmt.Errorf("client ARN validation failed: %w", err)
		}

		logrus.Info("Client certificate ARN validation passed")
		return nil
	}

	logrus.WithField("server_arn", serverARN).Info("Created ARN-validating server TLS config")

	return baseConfig, nil
}

// ValidateClientIPOnConnection validates the client IP during connection
// This should be called after TLS handshake with the actual source IP
func ValidateClientIPOnConnection(clientCert *x509.Certificate, sourceIP string) error {
	return ValidateClientCertificateIP(clientCert, sourceIP)
}
