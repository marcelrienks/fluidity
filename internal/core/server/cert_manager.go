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
	// New fields for lazy ARN-based certificate generation
	serverARN      string
	serverPublicIP string
	privateKey     *rsa.PrivateKey
	agentIPs       []string // List of agent IPs in current certificate
	useLazyGen     bool
}

// NewCertManager creates a new certificate manager for the server (legacy mode)
func NewCertManager(cacheDir string, caServiceURL string, log *logging.Logger) *CertManager {
	return &CertManager{
		cacheDir:      cacheDir,
		caServiceURL:  caServiceURL,
		caClient:      certs.NewCAServiceClient(caServiceURL, 10*time.Second, 3),
		log:           log,
		certCachePath: filepath.Join(cacheDir, "server.crt"),
		keyCachePath:  filepath.Join(cacheDir, "server.key"),
		useLazyGen:    false,
	}
}

// NewCertManagerWithLazyGen creates a new certificate manager with lazy generation
// serverARN and serverPublicIP are discovered at startup, but cert generation is deferred
func NewCertManagerWithLazyGen(cacheDir string, caServiceURL string, serverARN string, serverPublicIP string, log *logging.Logger) *CertManager {
	return &CertManager{
		cacheDir:       cacheDir,
		caServiceURL:   caServiceURL,
		caClient:       certs.NewCAServiceClient(caServiceURL, 10*time.Second, 3),
		log:            log,
		certCachePath:  filepath.Join(cacheDir, "server.crt"),
		keyCachePath:   filepath.Join(cacheDir, "server.key"),
		serverARN:      serverARN,
		serverPublicIP: serverPublicIP,
		useLazyGen:     true,
		agentIPs:       []string{},
	}
}

// InitializeKey generates and caches the RSA private key (called at startup for lazy gen)
func (cm *CertManager) InitializeKey() error {
	// Check if key already exists
	if _, err := os.Stat(cm.keyCachePath); err == nil {
		// Load existing key
		keyPEM, err := os.ReadFile(cm.keyCachePath)
		if err != nil {
			return fmt.Errorf("failed to read cached private key: %w", err)
		}
		
		privKey, err := certs.DecodePrivateKeyFromPEM(keyPEM)
		if err != nil {
			cm.log.Warn("Failed to decode cached private key, generating new one", "error", err.Error())
		} else {
			cm.privateKey = privKey
			cm.log.Info("Loaded existing private key from cache")
			return nil
		}
	}

	// Generate new private key
	privKey, err := certs.GeneratePrivateKey()
	if err != nil {
		return fmt.Errorf("failed to generate private key: %w", err)
	}

	cm.privateKey = privKey

	// Cache the private key
	keyPEM := certs.EncodePrivateKeyToPEM(privKey)
	if err := os.MkdirAll(cm.cacheDir, 0700); err != nil {
		return fmt.Errorf("failed to create cache directory: %w", err)
	}

	if err := os.WriteFile(cm.keyCachePath, keyPEM, 0600); err != nil {
		return fmt.Errorf("failed to write private key: %w", err)
	}

	cm.log.Info("Generated and cached new private key")
	return nil
}

// GetServerARN returns the stored server ARN
func (cm *CertManager) GetServerARN() string {
	return cm.serverARN
}

// EnsureCertificateForConnection ensures certificate is valid for the connecting agent IP
// This is called on each connection attempt and handles lazy generation
func (cm *CertManager) EnsureCertificateForConnection(ctx context.Context, agentIP string) (string, string, error) {
	if !cm.useLazyGen {
		// Legacy mode: use standard EnsureCertificate
		return cm.EnsureCertificate(ctx)
	}

	// Check if we need to regenerate the certificate
	needsRegeneration := false

	// Check if certificate exists
	if !cm.isCertificateValid() {
		cm.log.Info("No valid certificate found, generating new one", "agent_ip", agentIP)
		needsRegeneration = true
	} else {
		// Check if agent IP is already in the certificate
		if !cm.containsAgentIP(agentIP) {
			cm.log.Info("Agent IP not in certificate SAN, regenerating", "agent_ip", agentIP)
			needsRegeneration = true
		}
	}

	if needsRegeneration {
		// Add agent IP to the list
		cm.agentIPs = certs.AppendIPsToSAN(cm.agentIPs, agentIP)

		// Generate certificate with server IP and all agent IPs
		ipList := append([]string{cm.serverPublicIP}, cm.agentIPs...)

		cm.log.Info("Generating certificate with ARN and IPs", 
			"server_arn", cm.serverARN,
			"server_ip", cm.serverPublicIP,
			"agent_ips", cm.agentIPs,
			"total_ips", len(ipList))

		csrBytes, err := certs.GenerateCSRWithARNAndMultipleSANs(cm.privateKey, cm.serverARN, ipList)
		if err != nil {
			return "", "", fmt.Errorf("failed to generate CSR: %w", err)
		}

		csrPEM := certs.EncodeCSRToPEM(csrBytes)
		cm.log.Debug("Generated CSR", "size", len(csrPEM), "ip_count", len(ipList))

		// Request CA to sign the CSR
		cm.log.Info("Requesting CA to sign CSR", "ca_url", cm.caServiceURL)
		certPEM, err := cm.caClient.SignCSR(ctx, csrPEM)
		if err != nil {
			return "", "", fmt.Errorf("failed to sign CSR with CA: %w", err)
		}

		// Cache the certificate
		if err := os.MkdirAll(cm.cacheDir, 0700); err != nil {
			return "", "", fmt.Errorf("failed to create cache directory: %w", err)
		}

		if err := os.WriteFile(cm.certCachePath, certPEM, 0600); err != nil {
			return "", "", fmt.Errorf("failed to write certificate: %w", err)
		}

		cm.log.Info("Successfully generated and cached certificate", 
			"cert_path", cm.certCachePath, 
			"agent_count", len(cm.agentIPs))
	} else {
		cm.log.Debug("Using cached certificate", "agent_ip", agentIP)
	}

	return cm.certCachePath, cm.keyCachePath, nil
}

// containsAgentIP checks if the given agent IP is in the current certificate
func (cm *CertManager) containsAgentIP(agentIP string) bool {
	// Parse the current certificate
	certPEM, err := os.ReadFile(cm.certCachePath)
	if err != nil {
		return false
	}

	cert, err := certs.ParseCertificatePEM(certPEM)
	if err != nil {
		return false
	}

	// Check if agent IP is in the SAN list
	for _, ip := range cert.IPAddresses {
		if ip.String() == agentIP {
			return true
		}
	}

	return false
}

// EnsureCertificate ensures that the server has a valid certificate (legacy mode)
// It will generate and cache a certificate if one doesn't exist
func (cm *CertManager) EnsureCertificate(ctx context.Context) (string, string, error) {
	// Check if cached certificate exists and is valid
	if cm.isCertificateValid() {
		cm.log.Info("Using cached certificate", "cert_path", cm.certCachePath, "key_path", cm.keyCachePath)
		return cm.certCachePath, cm.keyCachePath, nil
	}

	cm.log.Info("Generating new certificate for server (legacy mode)")

	// Generate private key
	privKey, err := certs.GeneratePrivateKey()
	if err != nil {
		return "", "", fmt.Errorf("failed to generate private key: %w", err)
	}

	// Detect server IP for legacy mode
	serverIP, err := certs.DetectLocalIP()
	if err != nil {
		return "", "", fmt.Errorf("failed to detect server IP: %w", err)
	}
	cm.log.Info("Detected server IP", "ip", serverIP)

	// Generate CSR with legacy format
	csrBytes, err := certs.GenerateCSR("fluidity-server", serverIP, privKey)
	if err != nil {
		return "", "", fmt.Errorf("failed to generate CSR: %w", err)
	}

	csrPEM := certs.EncodeCSRToPEM(csrBytes)
	cm.log.Debug("Generated CSR", "size", len(csrPEM))

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
