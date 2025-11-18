package tests

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"fmt"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"fluidity/internal/core/agent"
	"fluidity/internal/core/server"
)

// TestCerts holds test certificates for mTLS
type TestCerts struct {
	CACert     *x509.Certificate
	CAKey      *rsa.PrivateKey
	ServerCert tls.Certificate
	ClientCert tls.Certificate
	ServerTLS  *tls.Config
	ClientTLS  *tls.Config
}

// GenerateTestCerts creates test certificates for mTLS testing
func GenerateTestCerts(t *testing.T) *TestCerts {
	t.Helper()

	// Generate CA
	caKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("Failed to generate CA key: %v", err)
	}

	caTemplate := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject: pkix.Name{
			CommonName:   "Test CA",
			Organization: []string{"Fluidity Test"},
		},
		NotBefore:             time.Now(),
		NotAfter:              time.Now().Add(24 * time.Hour),
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature,
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

	// Generate server certificate
	serverKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("Failed to generate server key: %v", err)
	}

	serverTemplate := &x509.Certificate{
		SerialNumber: big.NewInt(2),
		Subject: pkix.Name{
			CommonName:   "localhost",
			Organization: []string{"Fluidity Test"},
		},
		NotBefore:   time.Now(),
		NotAfter:    time.Now().Add(24 * time.Hour),
		KeyUsage:    x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		DNSNames:    []string{"localhost"},
		IPAddresses: []net.IP{net.ParseIP("127.0.0.1")},
	}

	serverCertBytes, err := x509.CreateCertificate(rand.Reader, serverTemplate, caCert, &serverKey.PublicKey, caKey)
	if err != nil {
		t.Fatalf("Failed to create server certificate: %v", err)
	}

	serverCert := tls.Certificate{
		Certificate: [][]byte{serverCertBytes},
		PrivateKey:  serverKey,
	}

	// Generate client certificate
	clientKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("Failed to generate client key: %v", err)
	}

	clientTemplate := &x509.Certificate{
		SerialNumber: big.NewInt(3),
		Subject: pkix.Name{
			CommonName:   "test-client",
			Organization: []string{"Fluidity Test"},
		},
		NotBefore:   time.Now(),
		NotAfter:    time.Now().Add(24 * time.Hour),
		KeyUsage:    x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
	}

	clientCertBytes, err := x509.CreateCertificate(rand.Reader, clientTemplate, caCert, &clientKey.PublicKey, caKey)
	if err != nil {
		t.Fatalf("Failed to create client certificate: %v", err)
	}

	clientCert := tls.Certificate{
		Certificate: [][]byte{clientCertBytes},
		PrivateKey:  clientKey,
	}

	// Create CA pool
	caPool := x509.NewCertPool()
	caPool.AddCert(caCert)

	// Server TLS config
	serverTLSConfig := &tls.Config{
		Certificates: []tls.Certificate{serverCert},
		ClientAuth:   tls.RequireAndVerifyClientCert,
		ClientCAs:    caPool,
		MinVersion:   tls.VersionTLS13,
	}

	// Client TLS config
	clientTLSConfig := &tls.Config{
		Certificates: []tls.Certificate{clientCert},
		RootCAs:      caPool,
		MinVersion:   tls.VersionTLS13,
	}

	return &TestCerts{
		CACert:     caCert,
		CAKey:      caKey,
		ServerCert: serverCert,
		ClientCert: clientCert,
		ServerTLS:  serverTLSConfig,
		ClientTLS:  clientTLSConfig,
	}
}

// TestServer wraps a test tunnel server
type TestServer struct {
	Server *server.Server
	Addr   string
	t      *testing.T
}

// StartTestServer creates and starts a test tunnel server
func StartTestServer(t *testing.T, certs *TestCerts) *TestServer {
	t.Helper()

	// Use port 0 to get a random free port
	srv, err := server.NewServerWithTestMode(certs.ServerTLS, "127.0.0.1:0", 10, "error", true)
	if err != nil {
		t.Fatalf("Failed to create test server: %v", err)
	}

	// Start in goroutine
	go func() {
		if err := srv.Start(); err != nil {
			t.Logf("Server stopped with error: %v", err)
		}
	}()

	// Wait a bit for server to start
	time.Sleep(200 * time.Millisecond)

	// Get the actual listening address from the server's listener
	// The server creates its listener in NewServer, we need to access it
	// For now, use a workaround with a known test port
	testPort := GetFreePort(t)
	addr := fmt.Sprintf("127.0.0.1:%d", testPort)

	// Recreate server with the specific port so we know the address
	srv.Stop()
	time.Sleep(50 * time.Millisecond)

	srv, err = server.NewServerWithTestMode(certs.ServerTLS, addr, 10, "error", true)
	if err != nil {
		t.Fatalf("Failed to recreate test server: %v", err)
	}

	// Start again
	go func() {
		if err := srv.Start(); err != nil {
			t.Logf("Server stopped with error: %v", err)
		}
	}()

	// Wait for server to be ready
	time.Sleep(200 * time.Millisecond)

	ts := &TestServer{
		Server: srv,
		Addr:   addr,
		t:      t,
	}

	return ts
}

// Stop stops the test server
func (ts *TestServer) Stop() {
	if ts.Server != nil {
		ts.Server.Stop()
	}
}

// TestClient wraps a test tunnel client and proxy
type TestClient struct {
	Client    *agent.Client
	Proxy     *agent.Server
	ProxyPort int
	t         *testing.T
}

// StartTestClient creates and starts a test tunnel client with proxy
func StartTestClient(t *testing.T, serverAddr string, certs *TestCerts) *TestClient {
	t.Helper()

	client := agent.NewClient(certs.ClientTLS, serverAddr, "error")

	err := client.Connect()
	if err != nil {
		t.Fatalf("Failed to connect test client: %v", err)
	}

	// Get a free port for the proxy
	proxyPort := GetFreePort(t)

	// Create and start proxy server
	proxyServer := agent.NewServer(proxyPort, client, "error")
	err = proxyServer.Start()
	if err != nil {
		client.Disconnect()
		t.Fatalf("Failed to start test proxy: %v", err)
	}

	// Wait for proxy to be ready
	time.Sleep(200 * time.Millisecond)

	tc := &TestClient{
		Client:    client,
		Proxy:     proxyServer,
		ProxyPort: proxyPort,
		t:         t,
	}

	return tc
}

// Stop stops the test client and proxy
func (tc *TestClient) Stop() {
	if tc.Proxy != nil {
		tc.Proxy.Stop()
	}
	if tc.Client != nil {
		tc.Client.Disconnect()
	}
}

// MockHTTPServer creates a mock HTTP server for testing
func MockHTTPServer(t *testing.T, handler http.HandlerFunc) *httptest.Server {
	t.Helper()

	if handler == nil {
		handler = func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusOK)
			fmt.Fprintf(w, `{"status":"ok","method":"%s","url":"%s"}`, r.Method, r.URL.String())
		}
	}

	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)

	return server
}

// MockHTTPSServer creates a mock HTTPS server for testing
func MockHTTPSServer(t *testing.T, handler http.HandlerFunc) *httptest.Server {
	t.Helper()

	if handler == nil {
		handler = func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusOK)
			fmt.Fprintf(w, `{"status":"ok","method":"%s","url":"%s"}`, r.Method, r.URL.String())
		}
	}

	server := httptest.NewTLSServer(handler)
	t.Cleanup(server.Close)

	return server
}

// AssertNoError fails the test if err is not nil
func AssertNoError(t *testing.T, err error, msg string) {
	t.Helper()
	if err != nil {
		t.Fatalf("%s: %v", msg, err)
	}
}

// AssertError fails the test if err is nil
func AssertError(t *testing.T, err error, msg string) {
	t.Helper()
	if err == nil {
		t.Fatalf("%s: expected error but got nil", msg)
	}
}

// AssertEqual fails the test if expected != actual
func AssertEqual(t *testing.T, expected, actual interface{}, msg string) {
	t.Helper()
	if expected != actual {
		t.Fatalf("%s: expected %v, got %v", msg, expected, actual)
	}
}

// GetFreePort finds an available port
func GetFreePort(t *testing.T) int {
	t.Helper()

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("Failed to find free port: %v", err)
	}
	defer listener.Close()

	addr := listener.Addr().(*net.TCPAddr)
	return addr.Port
}

// WaitForPort waits for a port to be available or timeout
func WaitForPort(t *testing.T, addr string, timeout time.Duration) error {
	t.Helper()

	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		conn, err := net.DialTimeout("tcp", addr, 100*time.Millisecond)
		if err == nil {
			conn.Close()
			return nil
		}
		time.Sleep(50 * time.Millisecond)
	}

	return fmt.Errorf("timeout waiting for port %s", addr)
}

// EncodePEM encodes a certificate to PEM format
func EncodePEM(cert *x509.Certificate) []byte {
	return pem.EncodeToMemory(&pem.Block{
		Type:  "CERTIFICATE",
		Bytes: cert.Raw,
	})
}

// EncodePrivateKeyPEM encodes a private key to PEM format
func EncodePrivateKeyPEM(key *rsa.PrivateKey) []byte {
	return pem.EncodeToMemory(&pem.Block{
		Type:  "RSA PRIVATE KEY",
		Bytes: x509.MarshalPKCS1PrivateKey(key),
	})
}
