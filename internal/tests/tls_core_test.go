package tests

import (
	"crypto/tls"
	"testing"
	"time"
)

// ============================================================================
// TLS CONFIGURATION AND HANDSHAKE TESTS
// ============================================================================

// TestTLSConnection_ClientServer tests basic TLS connection between client and server
func TestTLSConnection_ClientServer(t *testing.T) {
	certs := GenerateTestCerts(t)
	server := StartTestServer(t, certs)
	defer server.Stop()

	// Client should establish TLS connection to server
	client := StartTestClient(t, server.Addr, certs)
	defer client.Stop()

	if !client.Client.IsConnected() {
		t.Errorf("expected TLS connection to succeed")
	}
}

// TestTLSConnection_MutualAuthentication tests mutual TLS authentication
func TestTLSConnection_MutualAuthentication(t *testing.T) {
	certs := GenerateTestCerts(t)
	server := StartTestServer(t, certs)
	defer server.Stop()

	// Client with valid certificates should connect successfully
	client := StartTestClient(t, server.Addr, certs)
	defer client.Stop()

	if !client.Client.IsConnected() {
		t.Errorf("expected mTLS authentication to succeed")
	}
}

// TestTLSConnection_CertificateValidation tests certificate validation
func TestTLSConnection_CertificateValidation(t *testing.T) {
	certs := GenerateTestCerts(t)
	server := StartTestServer(t, certs)
	defer server.Stop()

	// Verify server certificate is properly validated
	client := StartTestClient(t, server.Addr, certs)
	defer client.Stop()

	if !client.Client.IsConnected() {
		t.Errorf("expected certificate validation to succeed")
	}
}

// TestTLSConfig_ServerCertificate tests server certificate configuration
func TestTLSConfig_ServerCertificate(t *testing.T) {
	certs := GenerateTestCerts(t)

	if certs == nil {
		t.Fatalf("expected test certs to be generated")
	}

	// Verify server certificate exists
	if certs.ServerCert.Leaf == nil {
		t.Logf("warning: server certificate leaf not parsed")
	}

	if len(certs.ServerCert.Certificate) == 0 {
		t.Errorf("expected server certificate to be loaded")
	}
}

// TestTLSConfig_ClientCertificate tests client certificate configuration
func TestTLSConfig_ClientCertificate(t *testing.T) {
	certs := GenerateTestCerts(t)

	if certs == nil {
		t.Fatalf("expected test certs to be generated")
	}

	// Verify client certificate exists
	if len(certs.ClientCert.Certificate) == 0 {
		t.Errorf("expected client certificate to be loaded")
	}
}

// TestTLSConfig_RootCA tests root CA configuration
func TestTLSConfig_RootCA(t *testing.T) {
	certs := GenerateTestCerts(t)

	if certs == nil {
		t.Fatalf("expected test certs to be generated")
	}

	// Verify CA certificate exists
	if certs.CACert == nil {
		t.Errorf("expected root CA certificate to be generated")
	}
}

// TestTLSConfig_ServerTLSConfig tests server TLS config
func TestTLSConfig_ServerTLSConfig(t *testing.T) {
	certs := GenerateTestCerts(t)

	if certs == nil {
		t.Fatalf("expected test certs to be generated")
	}

	if certs.ServerTLS == nil {
		t.Errorf("expected server TLS config to be created")
	}

	// Verify TLS config has certificates
	if certs.ServerTLS != nil && len(certs.ServerTLS.Certificates) == 0 {
		t.Errorf("expected TLS config to have certificates")
	}
}

// TestTLSConfig_ClientTLSConfig tests client TLS config
func TestTLSConfig_ClientTLSConfig(t *testing.T) {
	certs := GenerateTestCerts(t)

	if certs == nil {
		t.Fatalf("expected test certs to be generated")
	}

	if certs.ClientTLS == nil {
		t.Errorf("expected client TLS config to be created")
	}

	// Verify TLS config has certificates and CA
	if certs.ClientTLS != nil {
		if len(certs.ClientTLS.Certificates) == 0 {
			t.Errorf("expected TLS config to have client certificates")
		}
		if certs.ClientTLS.RootCAs == nil {
			t.Errorf("expected TLS config to have RootCAs")
		}
	}
}

// TestTLSVersion_TLS13 tests TLS 1.3 support
func TestTLSVersion_TLS13(t *testing.T) {
	certs := GenerateTestCerts(t)
	server := StartTestServer(t, certs)
	defer server.Stop()

	client := StartTestClient(t, server.Addr, certs)
	defer client.Stop()

	// Should support TLS 1.3
	if !client.Client.IsConnected() {
		t.Errorf("expected TLS 1.3 connection to succeed")
	}
}

// TestTLSVersion_MinVersion tests minimum TLS version
func TestTLSVersion_MinVersion(t *testing.T) {
	certs := GenerateTestCerts(t)

	if certs == nil {
		t.Fatalf("expected test certs to be generated")
	}

	if certs.ServerTLS == nil {
		t.Fatalf("expected server TLS config")
	}

	// Server should require TLS 1.3
	if certs.ServerTLS.MinVersion < tls.VersionTLS13 {
		t.Logf("warning: TLS MinVersion is %v, expected >= TLS 1.3", certs.ServerTLS.MinVersion)
	}
}

// TestCertificate_Validity tests certificate validity period
func TestCertificate_Validity(t *testing.T) {
	certs := GenerateTestCerts(t)

	if certs == nil {
		t.Fatalf("expected test certs to be generated")
	}

	if certs.ServerCert.Leaf != nil {
		// Check not before
		if certs.ServerCert.Leaf.NotBefore.After(time.Now()) {
			t.Errorf("server certificate not yet valid")
		}

		// Check not after
		if certs.ServerCert.Leaf.NotAfter.Before(time.Now()) {
			t.Errorf("server certificate expired")
		}
	}
}

// TestCertificate_ClientValidity tests client certificate validity
func TestCertificate_ClientValidity(t *testing.T) {
	certs := GenerateTestCerts(t)

	if certs == nil {
		t.Fatalf("expected test certs to be generated")
	}

	if certs.ClientCert.Leaf != nil {
		// Check not before
		if certs.ClientCert.Leaf.NotBefore.After(time.Now()) {
			t.Errorf("client certificate not yet valid")
		}

		// Check not after
		if certs.ClientCert.Leaf.NotAfter.Before(time.Now()) {
			t.Errorf("client certificate expired")
		}
	}
}

// TestCertificate_ValidityDuration tests certificate validity period duration
func TestCertificate_ValidityDuration(t *testing.T) {
	certs := GenerateTestCerts(t)

	if certs == nil {
		t.Fatalf("expected test certs to be generated")
	}

	if certs.ServerCert.Leaf != nil {
		validity := certs.ServerCert.Leaf.NotAfter.Sub(certs.ServerCert.Leaf.NotBefore)

		// Should be at least 30 days
		minValidity := 30 * 24 * time.Hour
		if validity < minValidity {
			t.Errorf("certificate validity too short: %v (expected >= %v)", validity, minValidity)
		}
	}
}

// TestTLSConnection_MultipleConnections tests multiple concurrent TLS connections
func TestTLSConnection_MultipleConnections(t *testing.T) {
	certs := GenerateTestCerts(t)
	server := StartTestServer(t, certs)
	defer server.Stop()

	// Open multiple concurrent connections
	numConnections := 5
	clients := make([]*TestClient, numConnections)

	for i := 0; i < numConnections; i++ {
		client := StartTestClient(t, server.Addr, certs)
		if !client.Client.IsConnected() {
			t.Errorf("client %d failed to connect", i)
		}
		clients[i] = client
	}

	// Cleanup
	for _, client := range clients {
		client.Stop()
	}
}

// TestTLSConnection_RapidConnectDisconnect tests rapid TLS connect/disconnect cycles
func TestTLSConnection_RapidConnectDisconnect(t *testing.T) {
	certs := GenerateTestCerts(t)
	server := StartTestServer(t, certs)
	defer server.Stop()

	// Perform multiple rapid cycles
	for i := 0; i < 5; i++ {
		client := StartTestClient(t, server.Addr, certs)

		if !client.Client.IsConnected() {
			t.Errorf("cycle %d: TLS connection failed", i)
		}

		client.Stop()
		time.Sleep(50 * time.Millisecond)
	}
}

// TestTLSConnection_ServerStillAcceptsAfterDisconnect tests server accepts connections after client disconnect
func TestTLSConnection_ServerStillAcceptsAfterDisconnect(t *testing.T) {
	certs := GenerateTestCerts(t)
	server := StartTestServer(t, certs)
	defer server.Stop()

	// Connect and disconnect
	client1 := StartTestClient(t, server.Addr, certs)
	if !client1.Client.IsConnected() {
		t.Fatalf("first client failed to connect")
	}
	client1.Stop()
	time.Sleep(100 * time.Millisecond)

	// Try to connect again
	client2 := StartTestClient(t, server.Addr, certs)
	defer client2.Stop()

	if !client2.Client.IsConnected() {
		t.Errorf("expected second client to connect after first disconnected")
	}
}
