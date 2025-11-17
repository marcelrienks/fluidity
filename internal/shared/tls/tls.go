package tls

import (
	"crypto/tls"
	"crypto/x509"
	"fmt"
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
