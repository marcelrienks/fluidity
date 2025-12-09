package server

import (
	"context"
	"crypto/rsa"
	"crypto/tls"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"fluidity/internal/shared/certs"
	"fluidity/internal/shared/logging"
	tlsutil "fluidity/internal/shared/tls"
)

// CertManager handles certificate generation and caching for the server
type CertManager struct {
	cacheDir       string
	caServiceURL   string
	caClient       *certs.CAServiceClient
	log            *logging.Logger
	certCachePath  string
	keyCachePath   string
}

// NewCertManager creates a new certificate manager for the server
func NewCertManager(cacheDir string, caServiceURL string, log *logging.Logger) *CertManager {
	return &CertManager{
		cacheDir:      cacheDir,
		caServiceURL:  caServiceURL,
		caClient:      certs.NewCAServiceClient(caServiceURL, 10*time.Second, 3),
		log:           log,
		certCachePath: filepath.Join(cacheDir, "server.crt"),
		keyCachePath:  filepath.Join(cacheDir, "server.key"),
	}
}

// EnsureCertificate ensures that the server has a valid certificate
// It will generate and cache a certificate if one doesn't exist
func (cm *CertManager) EnsureCertificate(ctx context.Context) (string, string, error) {
	// Check if cached certificate exists and is valid
	if cm.isCertificateValid() {
		cm.log.Info("Using cached certificate", "cert_path", cm.certCachePath, "key_path", cm.keyCachePath)
		return cm.certCachePath, cm.keyCachePath, nil
	}

	cm.log.Info("Generating new certificate for server")

	// Generate private key
	privKey, err := certs.GeneratePrivateKey()
	if err != nil {
		return "", "", fmt.Errorf("failed to generate private key: %w", err)
	}

	// Generate CSR without IP SAN (Option A design)
	// Server's public IP is discovered by agents via Query Lambda
	// Certificate uses CN-based validation instead of IP SAN
	csrBytes, err := certs.GenerateCSRWithoutSAN("fluidity-server", privKey)
	if err != nil {
		return "", "", fmt.Errorf("failed to generate CSR: %w", err)
	}

	csrPEM := certs.EncodeCSRToPEM(csrBytes)
	cm.log.Debug("Generated CSR (no IP SAN)", "size", len(csrPEM))

	// Request CA to sign the CSR
	cm.log.Info("Requesting CA to sign CSR", "ca_url", cm.caServiceURL)
	certPEM, err := cm.caClient.SignCSR(ctx, csrPEM)
	if err != nil {
		return "", "", fmt.Errorf("failed to sign CSR with CA: %w", err)
	}

	// Cache the certificate and key
	if err := cm.cacheFiles(certPEM, privKey); err != nil {
		return "", "", fmt.Errorf("failed to cache certificate: %w", err)
	}

	cm.log.Info("Successfully generated and cached certificate", "cert_path", cm.certCachePath, "key_path", cm.keyCachePath)
	return cm.certCachePath, cm.keyCachePath, nil
}

// isCertificateValid checks if the cached certificate exists and is valid
func (cm *CertManager) isCertificateValid() bool {
	// Check if both files exist
	certInfo, err := os.Stat(cm.certCachePath)
	if err != nil {
		return false
	}
	keyInfo, err := os.Stat(cm.keyCachePath)
	if err != nil {
		return false
	}

	// Both files exist, check certificate validity
	certPEM, err := os.ReadFile(cm.certCachePath)
	if err != nil {
		cm.log.Warn("Failed to read cached certificate", "error", err.Error())
		return false
	}

	cert, err := certs.ParseCertificatePEM(certPEM)
	if err != nil {
		cm.log.Warn("Failed to parse cached certificate", "error", err.Error())
		return false
	}

	// Check if certificate is still valid (not expired)
	if time.Now().After(cert.NotAfter) {
		cm.log.Warn("Cached certificate has expired", "not_after", cert.NotAfter.String())
		return false
	}

	// Certificate should be renewed if it expires within 30 days
	if time.Until(cert.NotAfter) < 30*24*time.Hour {
		cm.log.Warn("Cached certificate expires soon", "not_after", cert.NotAfter.String())
		return false
	}

	cm.log.Debug("Cached certificate is valid",
		"cert_modified", certInfo.ModTime().String(),
		"key_modified", keyInfo.ModTime().String(),
		"cert_expires", cert.NotAfter.String())

	return true
}

// cacheFiles writes the certificate and key to the cache directory
func (cm *CertManager) cacheFiles(certPEM []byte, privKey *rsa.PrivateKey) error {
	// Create cache directory if it doesn't exist
	if err := os.MkdirAll(cm.cacheDir, 0700); err != nil {
		return fmt.Errorf("failed to create cache directory: %w", err)
	}

	// Write certificate
	if err := os.WriteFile(cm.certCachePath, certPEM, 0600); err != nil {
		return fmt.Errorf("failed to write certificate cache: %w", err)
	}

	// Write private key
	keyPEM := certs.EncodePrivateKeyToPEM(privKey)
	if err := os.WriteFile(cm.keyCachePath, keyPEM, 0600); err != nil {
		return fmt.Errorf("failed to write key cache: %w", err)
	}

	return nil
}

// GetTLSConfig returns a TLS configuration using the managed certificate
func (cm *CertManager) GetTLSConfig(caCertFile string) (*tls.Config, error) {
	return tlsutil.LoadServerTLSConfig(cm.certCachePath, cm.keyCachePath, caCertFile)
}
