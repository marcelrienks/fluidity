package certs

import (
	"crypto/x509"
	"encoding/pem"
	"testing"
)

func TestGeneratePrivateKey(t *testing.T) {
	privKey, err := GeneratePrivateKey()
	if err != nil {
		t.Fatalf("Expected no error, got: %v", err)
	}

	if privKey == nil {
		t.Fatal("Expected private key, got nil")
	}

	if privKey.N.BitLen() != rsaKeySize {
		t.Errorf("Expected key size %d, got %d", rsaKeySize, privKey.N.BitLen())
	}
}

func TestGenerateCSR_Legacy(t *testing.T) {
	privKey, _ := GeneratePrivateKey()
	
	csrBytes, err := GenerateCSR("fluidity-client", "192.168.1.100", privKey)
	if err != nil {
		t.Fatalf("Expected no error, got: %v", err)
	}

	if len(csrBytes) == 0 {
		t.Fatal("Expected CSR bytes, got empty")
	}

	// Parse CSR to verify content
	csr, err := x509.ParseCertificateRequest(csrBytes)
	if err != nil {
		t.Fatalf("Failed to parse CSR: %v", err)
	}

	if csr.Subject.CommonName != "fluidity-client" {
		t.Errorf("Expected CN 'fluidity-client', got '%s'", csr.Subject.CommonName)
	}

	if len(csr.IPAddresses) != 1 {
		t.Fatalf("Expected 1 IP address, got %d", len(csr.IPAddresses))
	}

	if csr.IPAddresses[0].String() != "192.168.1.100" {
		t.Errorf("Expected IP 192.168.1.100, got %s", csr.IPAddresses[0].String())
	}
}

func TestGenerateCSR_Legacy_InvalidIP(t *testing.T) {
	privKey, _ := GeneratePrivateKey()
	
	_, err := GenerateCSR("fluidity-client", "invalid-ip", privKey)
	if err == nil {
		t.Fatal("Expected error for invalid IP, got nil")
	}
}

func TestGenerateCSRWithARNAndMultipleSANs_SingleIP(t *testing.T) {
	privKey, _ := GeneratePrivateKey()
	
	serverARN := "arn:aws:ecs:us-east-1:123456789012:task/my-cluster/abc123"
	ipAddresses := []string{"54.123.45.67"}

	csrBytes, err := GenerateCSRWithARNAndMultipleSANs(privKey, serverARN, ipAddresses)
	if err != nil {
		t.Fatalf("Expected no error, got: %v", err)
	}

	// Parse and verify CSR
	csr, err := x509.ParseCertificateRequest(csrBytes)
	if err != nil {
		t.Fatalf("Failed to parse CSR: %v", err)
	}

	if csr.Subject.CommonName != serverARN {
		t.Errorf("Expected CN '%s', got '%s'", serverARN, csr.Subject.CommonName)
	}

	if len(csr.IPAddresses) != 1 {
		t.Fatalf("Expected 1 IP address, got %d", len(csr.IPAddresses))
	}

	if csr.IPAddresses[0].String() != "54.123.45.67" {
		t.Errorf("Expected IP 54.123.45.67, got %s", csr.IPAddresses[0].String())
	}
}

func TestGenerateCSRWithARNAndMultipleSANs_MultipleIPs(t *testing.T) {
	privKey, _ := GeneratePrivateKey()
	
	serverARN := "arn:aws:ec2:eu-west-1:987654321098:instance/i-1234567890abcdef0"
	ipAddresses := []string{"54.123.45.67", "203.45.67.89", "10.0.1.5"}

	csrBytes, err := GenerateCSRWithARNAndMultipleSANs(privKey, serverARN, ipAddresses)
	if err != nil {
		t.Fatalf("Expected no error, got: %v", err)
	}

	csr, err := x509.ParseCertificateRequest(csrBytes)
	if err != nil {
		t.Fatalf("Failed to parse CSR: %v", err)
	}

	if csr.Subject.CommonName != serverARN {
		t.Errorf("Expected CN '%s', got '%s'", serverARN, csr.Subject.CommonName)
	}

	if len(csr.IPAddresses) != 3 {
		t.Fatalf("Expected 3 IP addresses, got %d", len(csr.IPAddresses))
	}

	expectedIPs := map[string]bool{
		"54.123.45.67":  false,
		"203.45.67.89":  false,
		"10.0.1.5":      false,
	}

	for _, ip := range csr.IPAddresses {
		ipStr := ip.String()
		if _, exists := expectedIPs[ipStr]; !exists {
			t.Errorf("Unexpected IP in CSR: %s", ipStr)
		}
		expectedIPs[ipStr] = true
	}

	for ip, found := range expectedIPs {
		if !found {
			t.Errorf("Expected IP %s not found in CSR", ip)
		}
	}
}

func TestGenerateCSRWithARNAndMultipleSANs_InvalidARN(t *testing.T) {
	privKey, _ := GeneratePrivateKey()
	
	invalidARNs := []string{
		"not-an-arn",
		"arn:invalid",
		"aws:ecs:us-east-1:123:task/abc",
		"",
	}

	for _, invalidARN := range invalidARNs {
		_, err := GenerateCSRWithARNAndMultipleSANs(privKey, invalidARN, []string{"54.123.45.67"})
		if err == nil {
			t.Errorf("Expected error for invalid ARN '%s', got nil", invalidARN)
		}
	}
}

func TestGenerateCSRWithARNAndMultipleSANs_InvalidIP(t *testing.T) {
	privKey, _ := GeneratePrivateKey()
	
	serverARN := "arn:aws:ecs:us-east-1:123456789012:task/my-cluster/abc123"
	invalidIPs := []string{
		"invalid-ip",
		"256.256.256.256",
		"192.168.1",
		"",
		"192.168.1.1.1",
	}

	for _, invalidIP := range invalidIPs {
		_, err := GenerateCSRWithARNAndMultipleSANs(privKey, serverARN, []string{invalidIP})
		if err == nil {
			t.Errorf("Expected error for invalid IP '%s', got nil", invalidIP)
		}
	}
}

func TestGenerateCSRWithARNAndMultipleSANs_NoIPs(t *testing.T) {
	privKey, _ := GeneratePrivateKey()
	
	serverARN := "arn:aws:ecs:us-east-1:123456789012:task/my-cluster/abc123"
	
	_, err := GenerateCSRWithARNAndMultipleSANs(privKey, serverARN, []string{})
	if err == nil {
		t.Fatal("Expected error for empty IP list, got nil")
	}
}

func TestEncodeCSRToPEM(t *testing.T) {
	privKey, _ := GeneratePrivateKey()
	csrBytes, _ := GenerateCSR("test", "192.168.1.1", privKey)
	
	pemBytes := EncodeCSRToPEM(csrBytes)
	
	if len(pemBytes) == 0 {
		t.Fatal("Expected PEM bytes, got empty")
	}

	block, _ := pem.Decode(pemBytes)
	if block == nil {
		t.Fatal("Failed to decode PEM block")
	}

	if block.Type != "CERTIFICATE REQUEST" {
		t.Errorf("Expected type 'CERTIFICATE REQUEST', got '%s'", block.Type)
	}
}

func TestEncodePrivateKeyToPEM(t *testing.T) {
	privKey, _ := GeneratePrivateKey()
	
	pemBytes := EncodePrivateKeyToPEM(privKey)
	
	if len(pemBytes) == 0 {
		t.Fatal("Expected PEM bytes, got empty")
	}

	block, _ := pem.Decode(pemBytes)
	if block == nil {
		t.Fatal("Failed to decode PEM block")
	}

	if block.Type != "RSA PRIVATE KEY" {
		t.Errorf("Expected type 'RSA PRIVATE KEY', got '%s'", block.Type)
	}
}

func TestDecodePrivateKeyFromPEM(t *testing.T) {
	privKey, _ := GeneratePrivateKey()
	pemBytes := EncodePrivateKeyToPEM(privKey)
	
	decodedKey, err := DecodePrivateKeyFromPEM(pemBytes)
	if err != nil {
		t.Fatalf("Expected no error, got: %v", err)
	}

	if decodedKey.N.Cmp(privKey.N) != 0 {
		t.Error("Decoded key does not match original key")
	}
}

func TestDecodePrivateKeyFromPEM_Invalid(t *testing.T) {
	_, err := DecodePrivateKeyFromPEM([]byte("invalid pem data"))
	if err == nil {
		t.Fatal("Expected error for invalid PEM, got nil")
	}
}

func TestAppendIPsToSAN(t *testing.T) {
	existing := []string{"192.168.1.1", "10.0.0.1"}
	new := []string{"172.16.0.1", "192.168.1.1"} // 192.168.1.1 is duplicate

	result := AppendIPsToSAN(existing, new...)

	// Should have 3 unique IPs
	if len(result) != 3 {
		t.Errorf("Expected 3 unique IPs, got %d", len(result))
	}

	// Check all expected IPs are present
	expectedIPs := map[string]bool{
		"192.168.1.1": false,
		"10.0.0.1":    false,
		"172.16.0.1":  false,
	}

	for _, ip := range result {
		if _, exists := expectedIPs[ip]; !exists {
			t.Errorf("Unexpected IP in result: %s", ip)
		}
		expectedIPs[ip] = true
	}

	for ip, found := range expectedIPs {
		if !found {
			t.Errorf("Expected IP %s not found in result", ip)
		}
	}
}

func TestValidateARN_Valid(t *testing.T) {
	validARNs := []string{
		"arn:aws:ecs:us-east-1:123456789012:task/my-cluster/abc123",
		"arn:aws:ec2:eu-west-1:987654321098:instance/i-1234567890abcdef0",
		"arn:aws:lambda:ap-south-1:111222333444:function:my-function",
	}

	for _, arn := range validARNs {
		err := ValidateARN(arn)
		if err != nil {
			t.Errorf("Expected valid ARN '%s', got error: %v", arn, err)
		}
	}
}

func TestValidateARN_Invalid(t *testing.T) {
	invalidARNs := []string{
		"not-an-arn",
		"arn:invalid",
		"aws:ecs:us-east-1:123:task/abc",
		"",
		"arn:aws:ecs:us-east-1:abc:task/test", // non-numeric account ID
	}

	for _, arn := range invalidARNs {
		err := ValidateARN(arn)
		if err == nil {
			t.Errorf("Expected error for invalid ARN '%s', got nil", arn)
		}
	}
}

func TestValidateIPv4_Valid(t *testing.T) {
	validIPs := []string{
		"192.168.1.1",
		"10.0.0.1",
		"172.16.0.1",
		"54.123.45.67",
		"0.0.0.0",
		"255.255.255.255",
	}

	for _, ip := range validIPs {
		err := ValidateIPv4(ip)
		if err != nil {
			t.Errorf("Expected valid IP '%s', got error: %v", ip, err)
		}
	}
}

func TestValidateIPv4_Invalid(t *testing.T) {
	invalidIPs := []string{
		"256.256.256.256",
		"192.168.1",
		"192.168.1.1.1",
		"invalid",
		"",
		"192.168.-1.1",
	}

	for _, ip := range invalidIPs {
		err := ValidateIPv4(ip)
		if err == nil {
			t.Errorf("Expected error for invalid IP '%s', got nil", ip)
		}
	}
}
