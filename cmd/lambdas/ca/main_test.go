package main

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"net"
	"testing"
	"time"
)

// Helper function to create a test CA certificate and key
func createTestCA(t *testing.T) (*x509.Certificate, *rsa.PrivateKey) {
	caKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("Failed to generate CA key: %v", err)
	}

	caTemplate := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject: pkix.Name{
			CommonName: "Fluidity Test CA",
		},
		NotBefore:             time.Now(),
		NotAfter:              time.Now().AddDate(10, 0, 0),
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
		BasicConstraintsValid: true,
		IsCA:                  true,
	}

	caCertBytes, err := x509.CreateCertificate(rand.Reader, caTemplate, caTemplate, &caKey.PublicKey, caKey)
	if err != nil {
		t.Fatalf("Failed to create CA certificate: %v", err)
	}

	caCert, err := x509.ParseCertificate(caCertBytes)
	if err != nil {
		t.Fatalf("Failed to parse CA certificate: %v", err)
	}

	return caCert, caKey
}

// Helper function to create a CSR
func createTestCSR(t *testing.T, cn string, ipAddresses []string) string {
	privKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("Failed to generate private key: %v", err)
	}

	var ips []net.IP
	for _, ipStr := range ipAddresses {
		ip := net.ParseIP(ipStr)
		if ip == nil {
			t.Fatalf("Invalid IP address: %s", ipStr)
		}
		ips = append(ips, ip)
	}

	template := x509.CertificateRequest{
		Subject: pkix.Name{
			CommonName: cn,
		},
		IPAddresses: ips,
	}

	csrBytes, err := x509.CreateCertificateRequest(rand.Reader, &template, privKey)
	if err != nil {
		t.Fatalf("Failed to create CSR: %v", err)
	}

	csrPEM := pem.EncodeToMemory(&pem.Block{
		Type:  "CERTIFICATE REQUEST",
		Bytes: csrBytes,
	})

	return string(csrPEM)
}

func TestParseAndValidateCSR_LegacyClient(t *testing.T) {
	csrPEM := createTestCSR(t, "fluidity-client", []string{"192.168.1.1"})

	csr, err := parseAndValidateCSR(csrPEM)
	if err != nil {
		t.Fatalf("Expected no error, got: %v", err)
	}

	if csr.Subject.CommonName != "fluidity-client" {
		t.Errorf("Expected CN 'fluidity-client', got '%s'", csr.Subject.CommonName)
	}

	if len(csr.IPAddresses) != 1 {
		t.Errorf("Expected 1 IP address, got %d", len(csr.IPAddresses))
	}
}

func TestParseAndValidateCSR_LegacyServer(t *testing.T) {
	csrPEM := createTestCSR(t, "fluidity-server", []string{"10.0.0.1"})

	csr, err := parseAndValidateCSR(csrPEM)
	if err != nil {
		t.Fatalf("Expected no error, got: %v", err)
	}

	if csr.Subject.CommonName != "fluidity-server" {
		t.Errorf("Expected CN 'fluidity-server', got '%s'", csr.Subject.CommonName)
	}
}

func TestParseAndValidateCSR_ARNFormat(t *testing.T) {
	arn := "arn:aws:ecs:us-east-1:123456789012:task/my-cluster/abc123"
	csrPEM := createTestCSR(t, arn, []string{"54.123.45.67"})

	csr, err := parseAndValidateCSR(csrPEM)
	if err != nil {
		t.Fatalf("Expected no error, got: %v", err)
	}

	if csr.Subject.CommonName != arn {
		t.Errorf("Expected CN '%s', got '%s'", arn, csr.Subject.CommonName)
	}
}

func TestParseAndValidateCSR_MultipleIPs(t *testing.T) {
	arn := "arn:aws:ec2:eu-west-1:987654321098:instance/i-1234567890abcdef0"
	ips := []string{"54.123.45.67", "203.45.67.89", "10.0.1.5"}
	csrPEM := createTestCSR(t, arn, ips)

	csr, err := parseAndValidateCSR(csrPEM)
	if err != nil {
		t.Fatalf("Expected no error, got: %v", err)
	}

	if len(csr.IPAddresses) != 3 {
		t.Errorf("Expected 3 IP addresses, got %d", len(csr.IPAddresses))
	}

	expectedIPs := map[string]bool{
		"54.123.45.67":  false,
		"203.45.67.89":  false,
		"10.0.1.5":      false,
	}

	for _, ip := range csr.IPAddresses {
		ipStr := ip.String()
		if _, exists := expectedIPs[ipStr]; exists {
			expectedIPs[ipStr] = true
		}
	}

	for ip, found := range expectedIPs {
		if !found {
			t.Errorf("Expected IP %s not found in CSR", ip)
		}
	}
}

func TestParseAndValidateCSR_InvalidCN(t *testing.T) {
	invalidCNs := []string{
		"invalid-client",
		"",
		"arn:invalid-format",
		"not-an-arn",
	}

	for _, cn := range invalidCNs {
		csrPEM := createTestCSR(t, cn, []string{"192.168.1.1"})
		_, err := parseAndValidateCSR(csrPEM)
		if err == nil {
			t.Errorf("Expected error for invalid CN '%s', got nil", cn)
		}
	}
}

func TestParseAndValidateCSR_NoIPs(t *testing.T) {
	privKey, _ := rsa.GenerateKey(rand.Reader, 2048)

	template := x509.CertificateRequest{
		Subject: pkix.Name{
			CommonName: "fluidity-client",
		},
		IPAddresses: []net.IP{}, // Empty IP list
	}

	csrBytes, _ := x509.CreateCertificateRequest(rand.Reader, &template, privKey)
	csrPEM := pem.EncodeToMemory(&pem.Block{
		Type:  "CERTIFICATE REQUEST",
		Bytes: csrBytes,
	})

	_, err := parseAndValidateCSR(string(csrPEM))
	if err == nil {
		t.Fatal("Expected error for CSR with no IP addresses, got nil")
	}
}

func TestParseAndValidateCSR_InvalidPEM(t *testing.T) {
	_, err := parseAndValidateCSR("not a valid PEM")
	if err == nil {
		t.Fatal("Expected error for invalid PEM, got nil")
	}
}

func TestSignCSR_Success(t *testing.T) {
	caCert, caKey := createTestCA(t)
	caConfig := &CAConfig{
		caCert: caCert,
		caKey:  caKey,
	}

	csrPEM := createTestCSR(t, "fluidity-client", []string{"192.168.1.1"})
	csr, err := parseAndValidateCSR(csrPEM)
	if err != nil {
		t.Fatalf("Failed to parse CSR: %v", err)
	}

	certPEM, err := signCSR(csr, caConfig)
	if err != nil {
		t.Fatalf("Expected no error, got: %v", err)
	}

	if len(certPEM) == 0 {
		t.Fatal("Expected certificate PEM, got empty")
	}

	// Parse and verify the signed certificate
	block, _ := pem.Decode(certPEM)
	if block == nil {
		t.Fatal("Failed to decode certificate PEM")
	}

	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		t.Fatalf("Failed to parse certificate: %v", err)
	}

	if cert.Subject.CommonName != "fluidity-client" {
		t.Errorf("Expected CN 'fluidity-client', got '%s'", cert.Subject.CommonName)
	}

	if len(cert.IPAddresses) != 1 {
		t.Errorf("Expected 1 IP address, got %d", len(cert.IPAddresses))
	}

	if cert.IPAddresses[0].String() != "192.168.1.1" {
		t.Errorf("Expected IP 192.168.1.1, got %s", cert.IPAddresses[0].String())
	}
}

func TestSignCSR_ARNWithMultipleIPs(t *testing.T) {
	caCert, caKey := createTestCA(t)
	caConfig := &CAConfig{
		caCert: caCert,
		caKey:  caKey,
	}

	arn := "arn:aws:ecs:us-east-1:123456789012:task/my-cluster/abc123"
	ips := []string{"54.123.45.67", "203.45.67.89"}
	csrPEM := createTestCSR(t, arn, ips)
	csr, err := parseAndValidateCSR(csrPEM)
	if err != nil {
		t.Fatalf("Failed to parse CSR: %v", err)
	}

	certPEM, err := signCSR(csr, caConfig)
	if err != nil {
		t.Fatalf("Expected no error, got: %v", err)
	}

	// Parse and verify the signed certificate
	block, _ := pem.Decode(certPEM)
	cert, _ := x509.ParseCertificate(block.Bytes)

	if cert.Subject.CommonName != arn {
		t.Errorf("Expected CN '%s', got '%s'", arn, cert.Subject.CommonName)
	}

	if len(cert.IPAddresses) != 2 {
		t.Errorf("Expected 2 IP addresses, got %d", len(cert.IPAddresses))
	}
}

func TestARNRegex(t *testing.T) {
	validARNs := []string{
		"arn:aws:ecs:us-east-1:123456789012:task/my-cluster/abc123",
		"arn:aws:ec2:eu-west-1:987654321098:instance/i-1234567890abcdef0",
		"arn:aws:lambda:ap-south-1:111222333444:function:my-function",
	}

	for _, arn := range validARNs {
		if !arnRegex.MatchString(arn) {
			t.Errorf("Expected ARN '%s' to be valid", arn)
		}
	}

	invalidARNs := []string{
		"not-an-arn",
		"arn:invalid",
		"arn:aws:ecs:us-east-1:abc:task/test", // non-numeric account
	}

	for _, arn := range invalidARNs {
		if arnRegex.MatchString(arn) {
			t.Errorf("Expected ARN '%s' to be invalid", arn)
		}
	}
}

func TestIPv4Regex(t *testing.T) {
	// Note: This regex is permissive and checks format only (xxx.xxx.xxx.xxx)
	// Actual IP validation is done by net.ParseIP in the validation function
	validFormats := []string{
		"192.168.1.1",
		"10.0.0.1",
		"54.123.45.67",
		"0.0.0.0",
		"255.255.255.255",
		"256.256.256.256", // Format is valid, but ParseIP will reject
	}

	for _, ip := range validFormats {
		if !ipv4Regex.MatchString(ip) {
			t.Errorf("Expected IP format '%s' to match regex", ip)
		}
	}

	invalidFormats := []string{
		"192.168.1",      // Missing octet
		"192.168.1.1.1",  // Too many octets
		"invalid",        // Not a number
		"",               // Empty
	}

	for _, ip := range invalidFormats {
		if ipv4Regex.MatchString(ip) {
			t.Errorf("Expected IP format '%s' to not match regex", ip)
		}
	}
}
