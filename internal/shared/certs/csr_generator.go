package certs

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"fmt"
	"net"
	"regexp"
)

const (
	// RSA key size for certificate generation
	rsaKeySize = 2048
)

var (
	// arnRegex validates AWS ARN format
	arnRegex = regexp.MustCompile(`^arn:aws:[a-z0-9\-]+:[a-z0-9\-]*:[0-9]{12}:.+`)
	// ipv4Regex validates IPv4 address format
	ipv4Regex = regexp.MustCompile(`^(?:[0-9]{1,3}\.){3}[0-9]{1,3}$`)
)

// GeneratePrivateKey generates a new RSA private key
func GeneratePrivateKey() (*rsa.PrivateKey, error) {
	privKey, err := rsa.GenerateKey(rand.Reader, rsaKeySize)
	if err != nil {
		return nil, fmt.Errorf("failed to generate RSA key: %w", err)
	}
	return privKey, nil
}

// GenerateCSR generates a CSR with a simple CN and IP SAN (legacy function)
// Deprecated: Use GenerateCSRWithARNAndMultipleSANs for ARN-based certificates
func GenerateCSR(commonName string, ipAddress string, privKey *rsa.PrivateKey) ([]byte, error) {
	if ipAddress == "" {
		return nil, fmt.Errorf("IP address is required")
	}

	ip := net.ParseIP(ipAddress)
	if ip == nil {
		return nil, fmt.Errorf("invalid IP address: %s", ipAddress)
	}

	template := x509.CertificateRequest{
		Subject: pkix.Name{
			CommonName: commonName,
		},
		IPAddresses: []net.IP{ip},
	}

	csrBytes, err := x509.CreateCertificateRequest(rand.Reader, &template, privKey)
	if err != nil {
		return nil, fmt.Errorf("failed to create certificate request: %w", err)
	}

	return csrBytes, nil
}

// GenerateCSRWithARNAndMultipleSANs generates a CSR with an ARN as the CN and multiple IP addresses in the SAN
func GenerateCSRWithARNAndMultipleSANs(privKey *rsa.PrivateKey, serverARN string, ipAddresses []string) ([]byte, error) {
	// Validate ARN format
	if !arnRegex.MatchString(serverARN) {
		return nil, fmt.Errorf("invalid ARN format: %s (must match arn:aws:...)", serverARN)
	}

	// Validate and parse all IP addresses
	if len(ipAddresses) == 0 {
		return nil, fmt.Errorf("at least one IP address is required")
	}

	var ipList []net.IP
	for _, ipStr := range ipAddresses {
		// Validate IPv4 format
		if !ipv4Regex.MatchString(ipStr) {
			return nil, fmt.Errorf("invalid IPv4 address: %s", ipStr)
		}

		ip := net.ParseIP(ipStr)
		if ip == nil {
			return nil, fmt.Errorf("failed to parse IP address: %s", ipStr)
		}
		ipList = append(ipList, ip)
	}

	// Create CSR template with ARN as CN and IPs in SAN
	template := x509.CertificateRequest{
		Subject: pkix.Name{
			CommonName: serverARN,
		},
		IPAddresses: ipList,
	}

	csrBytes, err := x509.CreateCertificateRequest(rand.Reader, &template, privKey)
	if err != nil {
		return nil, fmt.Errorf("failed to create certificate request: %w", err)
	}

	return csrBytes, nil
}

// EncodeCSRToPEM encodes CSR bytes to PEM format
func EncodeCSRToPEM(csrBytes []byte) []byte {
	return pem.EncodeToMemory(&pem.Block{
		Type:  "CERTIFICATE REQUEST",
		Bytes: csrBytes,
	})
}

// EncodePrivateKeyToPEM encodes a private key to PEM format
func EncodePrivateKeyToPEM(privKey *rsa.PrivateKey) []byte {
	return pem.EncodeToMemory(&pem.Block{
		Type:  "RSA PRIVATE KEY",
		Bytes: x509.MarshalPKCS1PrivateKey(privKey),
	})
}

// DecodePrivateKeyFromPEM decodes a PEM-encoded private key
func DecodePrivateKeyFromPEM(pemData []byte) (*rsa.PrivateKey, error) {
	block, _ := pem.Decode(pemData)
	if block == nil {
		return nil, fmt.Errorf("failed to decode PEM block")
	}

	privKey, err := x509.ParsePKCS1PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("failed to parse private key: %w", err)
	}

	return privKey, nil
}

// AppendIPsToSAN is a helper to append new IPs to an existing IP list (deduplication)
func AppendIPsToSAN(existingIPs []string, newIPs ...string) []string {
	// Create a map for deduplication
	ipMap := make(map[string]bool)
	
	// Add existing IPs
	for _, ip := range existingIPs {
		ipMap[ip] = true
	}

	// Add new IPs
	for _, ip := range newIPs {
		ipMap[ip] = true
	}

	// Convert back to slice
	result := make([]string, 0, len(ipMap))
	for ip := range ipMap {
		result = append(result, ip)
	}

	return result
}

// ValidateARN validates that a string is a valid AWS ARN
func ValidateARN(arn string) error {
	if !arnRegex.MatchString(arn) {
		return fmt.Errorf("invalid ARN format: %s (must match arn:aws:...)", arn)
	}
	return nil
}

// ValidateIPv4 validates that a string is a valid IPv4 address
func ValidateIPv4(ip string) error {
	if !ipv4Regex.MatchString(ip) {
		return fmt.Errorf("invalid IPv4 address: %s", ip)
	}
	if net.ParseIP(ip) == nil {
		return fmt.Errorf("failed to parse IPv4 address: %s", ip)
	}
	return nil
}
