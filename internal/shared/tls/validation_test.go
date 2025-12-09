package tls

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"crypto/x509/pkix"
	"math/big"
	"net"
	"testing"
	"time"
)

// Helper to create a test certificate
func createTestCert(cn string, ipAddresses []string) (*x509.Certificate, error) {
	privKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return nil, err
	}

	var ips []net.IP
	for _, ipStr := range ipAddresses {
		ip := net.ParseIP(ipStr)
		if ip != nil {
			ips = append(ips, ip)
		}
	}

	template := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject: pkix.Name{
			CommonName: cn,
		},
		NotBefore:   time.Now(),
		NotAfter:    time.Now().Add(24 * time.Hour),
		IPAddresses: ips,
	}

	certBytes, err := x509.CreateCertificate(rand.Reader, template, template, &privKey.PublicKey, privKey)
	if err != nil {
		return nil, err
	}

	return x509.ParseCertificate(certBytes)
}

func TestValidateServerCertificateARN_Success(t *testing.T) {
	expectedARN := "arn:aws:ecs:us-east-1:123456789012:task/cluster/task123"
	cert, err := createTestCert(expectedARN, []string{"54.123.45.67"})
	if err != nil {
		t.Fatalf("Failed to create test cert: %v", err)
	}

	err = ValidateServerCertificateARN(cert, expectedARN)
	if err != nil {
		t.Errorf("Expected validation to pass, got error: %v", err)
	}
}

func TestValidateServerCertificateARN_Mismatch(t *testing.T) {
	actualARN := "arn:aws:ecs:us-east-1:123456789012:task/cluster/task123"
	expectedARN := "arn:aws:ecs:us-east-1:999999999999:task/cluster/task999"
	
	cert, err := createTestCert(actualARN, []string{"54.123.45.67"})
	if err != nil {
		t.Fatalf("Failed to create test cert: %v", err)
	}

	err = ValidateServerCertificateARN(cert, expectedARN)
	if err == nil {
		t.Error("Expected validation to fail for mismatched ARN, got nil")
	}
}

func TestValidateServerCertificateARN_NilCert(t *testing.T) {
	err := ValidateServerCertificateARN(nil, "arn:aws:ecs:us-east-1:123:task/c/t")
	if err == nil {
		t.Error("Expected error for nil certificate, got nil")
	}
}

func TestValidateServerCertificateIP_Success(t *testing.T) {
	cert, err := createTestCert("test-server", []string{"54.123.45.67", "10.0.0.1"})
	if err != nil {
		t.Fatalf("Failed to create test cert: %v", err)
	}

	err = ValidateServerCertificateIP(cert, "54.123.45.67")
	if err != nil {
		t.Errorf("Expected validation to pass, got error: %v", err)
	}

	err = ValidateServerCertificateIP(cert, "10.0.0.1")
	if err != nil {
		t.Errorf("Expected validation to pass for second IP, got error: %v", err)
	}
}

func TestValidateServerCertificateIP_NotInSAN(t *testing.T) {
	cert, err := createTestCert("test-server", []string{"54.123.45.67"})
	if err != nil {
		t.Fatalf("Failed to create test cert: %v", err)
	}

	err = ValidateServerCertificateIP(cert, "192.168.1.1")
	if err == nil {
		t.Error("Expected validation to fail for IP not in SAN, got nil")
	}
}

func TestValidateServerCertificateIP_InvalidIP(t *testing.T) {
	cert, err := createTestCert("test-server", []string{"54.123.45.67"})
	if err != nil {
		t.Fatalf("Failed to create test cert: %v", err)
	}

	err = ValidateServerCertificateIP(cert, "invalid-ip")
	if err == nil {
		t.Error("Expected error for invalid IP format, got nil")
	}
}

func TestValidateServerCertificateIP_NilCert(t *testing.T) {
	err := ValidateServerCertificateIP(nil, "54.123.45.67")
	if err == nil {
		t.Error("Expected error for nil certificate, got nil")
	}
}

func TestValidateClientCertificateARN_Success(t *testing.T) {
	serverARN := "arn:aws:ecs:us-east-1:123456789012:task/cluster/task123"
	cert, err := createTestCert(serverARN, []string{"192.168.1.1"})
	if err != nil {
		t.Fatalf("Failed to create test cert: %v", err)
	}

	err = ValidateClientCertificateARN(cert, serverARN)
	if err != nil {
		t.Errorf("Expected validation to pass, got error: %v", err)
	}
}

func TestValidateClientCertificateARN_Mismatch(t *testing.T) {
	actualARN := "arn:aws:ecs:us-east-1:123456789012:task/cluster/task123"
	expectedARN := "arn:aws:ecs:us-east-1:999999999999:task/cluster/task999"
	
	cert, err := createTestCert(actualARN, []string{"192.168.1.1"})
	if err != nil {
		t.Fatalf("Failed to create test cert: %v", err)
	}

	err = ValidateClientCertificateARN(cert, expectedARN)
	if err == nil {
		t.Error("Expected validation to fail for mismatched ARN, got nil")
	}
}

func TestValidateClientCertificateIP_Success(t *testing.T) {
	cert, err := createTestCert("test-client", []string{"192.168.1.100", "10.0.0.5"})
	if err != nil {
		t.Fatalf("Failed to create test cert: %v", err)
	}

	err = ValidateClientCertificateIP(cert, "192.168.1.100")
	if err != nil {
		t.Errorf("Expected validation to pass, got error: %v", err)
	}

	err = ValidateClientCertificateIP(cert, "10.0.0.5")
	if err != nil {
		t.Errorf("Expected validation to pass for second IP, got error: %v", err)
	}
}

func TestValidateClientCertificateIP_NotInSAN(t *testing.T) {
	cert, err := createTestCert("test-client", []string{"192.168.1.100"})
	if err != nil {
		t.Fatalf("Failed to create test cert: %v", err)
	}

	err = ValidateClientCertificateIP(cert, "192.168.1.200")
	if err == nil {
		t.Error("Expected validation to fail for IP not in SAN, got nil")
	}
}

func TestValidateClientCertificateIP_InvalidIP(t *testing.T) {
	cert, err := createTestCert("test-client", []string{"192.168.1.100"})
	if err != nil {
		t.Fatalf("Failed to create test cert: %v", err)
	}

	err = ValidateClientCertificateIP(cert, "not-an-ip")
	if err == nil {
		t.Error("Expected error for invalid IP format, got nil")
	}
}

func TestValidateClientIPOnConnection(t *testing.T) {
	cert, err := createTestCert("test-client", []string{"203.0.113.42"})
	if err != nil {
		t.Fatalf("Failed to create test cert: %v", err)
	}

	// Should pass
	err = ValidateClientIPOnConnection(cert, "203.0.113.42")
	if err != nil {
		t.Errorf("Expected validation to pass, got error: %v", err)
	}

	// Should fail
	err = ValidateClientIPOnConnection(cert, "203.0.113.99")
	if err == nil {
		t.Error("Expected validation to fail for different IP, got nil")
	}
}
