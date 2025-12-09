package tests

import (
	"bufio"
	"bytes"
	"crypto/tls"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"
)

func TestProxyHTTPRequest(t *testing.T) {
	t.Parallel()

	certs := GenerateTestCerts(t)

	// Start mock target server
	targetServer := MockHTTPServer(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("Target server response"))
	})

	// Start tunnel server
	tunnelServer := StartTestServer(t, certs)
	defer tunnelServer.Stop()

	// Start agent (includes proxy)
	agent := StartTestClient(t, tunnelServer.Addr, certs)
	defer agent.Stop()

	// Wait for proxy to start
	time.Sleep(500 * time.Millisecond)

	// Create HTTP client with proxy
	proxyURL := fmt.Sprintf("http://localhost:%d", agent.ProxyPort)
	transport := &http.Transport{
		Proxy: func(req *http.Request) (*url.URL, error) {
			return url.Parse(proxyURL)
		},
	}
	client := &http.Client{Transport: transport}

	// Make request through proxy
	resp, err := client.Get(targetServer.URL)
	AssertNoError(t, err, "Proxy request should not fail")
	defer resp.Body.Close()

	AssertEqual(t, 200, resp.StatusCode, "HTTP status code")

	body, _ := io.ReadAll(resp.Body)
	if !bytes.Contains(body, []byte("Target server response")) {
		t.Fatalf("Unexpected response body: %s", string(body))
	}

	t.Log("HTTP request through proxy successful")
}

func TestProxyCONNECTRequest(t *testing.T) {
	t.Parallel()

	certs := GenerateTestCerts(t)

	// Start mock HTTPS target server
	targetServer := MockHTTPSServer(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("Secure target response"))
	})

	// Start tunnel server
	tunnelServer := StartTestServer(t, certs)
	defer tunnelServer.Stop()

	// Start agent
	agent := StartTestClient(t, tunnelServer.Addr, certs)
	defer agent.Stop()

	time.Sleep(500 * time.Millisecond)

	// Extract host:port from HTTPS URL
	targetHost := strings.TrimPrefix(targetServer.URL, "https://")

	// Connect to proxy
	proxyAddr := fmt.Sprintf("localhost:%d", agent.ProxyPort)
	conn, err := net.Dial("tcp", proxyAddr)
	AssertNoError(t, err, "Connect to proxy should not fail")
	defer conn.Close()

	// Send CONNECT request
	connectReq := fmt.Sprintf("CONNECT %s HTTP/1.1\r\nHost: %s\r\n\r\n", targetHost, targetHost)
	_, err = conn.Write([]byte(connectReq))
	AssertNoError(t, err, "CONNECT request should not fail")

	// Read CONNECT response
	reader := bufio.NewReader(conn)
	connectResp, err := http.ReadResponse(reader, nil)
	AssertNoError(t, err, "Read CONNECT response should not fail")
	AssertEqual(t, 200, connectResp.StatusCode, "CONNECT status code")

	// Upgrade to TLS
	tlsConn := tls.Client(conn, &tls.Config{})
	err = tlsConn.Handshake()
	AssertNoError(t, err, "TLS handshake should not fail")
	defer tlsConn.Close()

	// Send HTTP request over TLS tunnel
	httpReq := "GET / HTTP/1.1\r\nHost: " + targetHost + "\r\n\r\n"
	_, err = tlsConn.Write([]byte(httpReq))
	AssertNoError(t, err, "HTTP over tunnel should not fail")

	// Read response
	tlsReader := bufio.NewReader(tlsConn)
	httpResp, err := http.ReadResponse(tlsReader, nil)
	AssertNoError(t, err, "Read HTTP response should not fail")
	defer httpResp.Body.Close()

	AssertEqual(t, 200, httpResp.StatusCode, "HTTP status code")

	body, _ := io.ReadAll(httpResp.Body)
	if !bytes.Contains(body, []byte("Secure target response")) {
		t.Fatalf("Unexpected response body: %s", string(body))
	}

	t.Log("HTTPS CONNECT through proxy successful")
}

func TestProxyInvalidTarget(t *testing.T) {
	t.Parallel()

	certs := GenerateTestCerts(t)

	// Start tunnel server
	tunnelServer := StartTestServer(t, certs)
	defer tunnelServer.Stop()

	// Start agent
	agent := StartTestClient(t, tunnelServer.Addr, certs)
	defer agent.Stop()

	time.Sleep(500 * time.Millisecond)

	// Try to connect to non-existent target
	proxyURL := fmt.Sprintf("http://localhost:%d", agent.ProxyPort)
	transport := &http.Transport{
		Proxy: func(req *http.Request) (*url.URL, error) {
			return url.Parse(proxyURL)
		},
	}
	client := &http.Client{
		Transport: transport,
		Timeout:   5 * time.Second,
	}

	// Request to invalid target
	resp, err := client.Get("http://invalid-target-that-does-not-exist.local")

	// Should get error or non-200 status
	if err == nil && resp != nil && resp.StatusCode == 200 {
		t.Fatal("Should fail for invalid target")
	}

	t.Logf("Invalid target correctly failed: %v", err)
}

func TestProxyMultipleConcurrentRequests(t *testing.T) {
	t.Parallel()

	certs := GenerateTestCerts(t)

	// Start mock target server
	targetServer := MockHTTPServer(t, func(w http.ResponseWriter, r *http.Request) {
		// Simulate processing
		time.Sleep(100 * time.Millisecond)
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("Response"))
	})

	// Start tunnel
	tunnelServer := StartTestServer(t, certs)
	defer tunnelServer.Stop()

	agent := StartTestClient(t, tunnelServer.Addr, certs)
	defer agent.Stop()

	time.Sleep(500 * time.Millisecond)

	// Create HTTP client with proxy
	proxyURL := fmt.Sprintf("http://localhost:%d", agent.ProxyPort)
	transport := &http.Transport{
		Proxy: func(req *http.Request) (*url.URL, error) {
			return url.Parse(proxyURL)
		},
	}
	client := &http.Client{Transport: transport}

	// Send multiple concurrent requests
	numRequests := 10
	results := make(chan error, numRequests)

	for i := 0; i < numRequests; i++ {
		go func(id int) {
			resp, err := client.Get(targetServer.URL)
			if err != nil {
				results <- err
				return
			}
			defer resp.Body.Close()

			if resp.StatusCode != 200 {
				results <- fmt.Errorf("unexpected status: %d", resp.StatusCode)
				return
			}

			results <- nil
		}(i)
	}

	// Wait for all requests
	for i := 0; i < numRequests; i++ {
		select {
		case err := <-results:
			if err != nil {
				t.Errorf("Request %d failed: %v", i, err)
			}
		case <-time.After(10 * time.Second):
			t.Fatal("Timeout waiting for concurrent requests")
		}
	}

	t.Logf("All %d concurrent proxy requests completed", numRequests)
}

func TestProxyLargeResponse(t *testing.T) {
	t.Parallel()

	certs := GenerateTestCerts(t)

	// Create large response (1MB)
	largeBody := make([]byte, 1024*1024)
	for i := range largeBody {
		largeBody[i] = byte(i % 256)
	}

	// Start mock server
	targetServer := MockHTTPServer(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write(largeBody)
	})

	// Start tunnel
	tunnelServer := StartTestServer(t, certs)
	defer tunnelServer.Stop()

	agent := StartTestClient(t, tunnelServer.Addr, certs)
	defer agent.Stop()

	time.Sleep(500 * time.Millisecond)

	// Make request through proxy
	proxyURL := fmt.Sprintf("http://localhost:%d", agent.ProxyPort)
	transport := &http.Transport{
		Proxy: func(req *http.Request) (*url.URL, error) {
			return url.Parse(proxyURL)
		},
	}
	client := &http.Client{Transport: transport}

	resp, err := client.Get(targetServer.URL)
	AssertNoError(t, err, "Large response request should not fail")
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	AssertNoError(t, err, "Read large response should not fail")
	AssertEqual(t, len(largeBody), len(body), "Response body size")

	t.Logf("Successfully received %d bytes through proxy", len(body))
}

func TestProxyCustomHeaders(t *testing.T) {
	t.Parallel()

	certs := GenerateTestCerts(t)

	// Start mock server that echoes headers
	var receivedHeaders http.Header
	targetServer := MockHTTPServer(t, func(w http.ResponseWriter, r *http.Request) {
		receivedHeaders = r.Header
		w.WriteHeader(http.StatusOK)
	})

	// Start tunnel
	tunnelServer := StartTestServer(t, certs)
	defer tunnelServer.Stop()

	agent := StartTestClient(t, tunnelServer.Addr, certs)
	defer agent.Stop()

	time.Sleep(500 * time.Millisecond)

	// Create request with custom headers
	proxyURL := fmt.Sprintf("http://localhost:%d", agent.ProxyPort)
	transport := &http.Transport{
		Proxy: func(req *http.Request) (*url.URL, error) {
			return url.Parse(proxyURL)
		},
	}
	client := &http.Client{Transport: transport}

	req, err := http.NewRequest("GET", targetServer.URL, nil)
	AssertNoError(t, err, "Create request should not fail")

	req.Header.Set("X-Custom-Header", "test-value")
	req.Header.Set("User-Agent", "integration-test")

	resp, err := client.Do(req)
	AssertNoError(t, err, "Request with headers should not fail")
	defer resp.Body.Close()

	AssertEqual(t, 200, resp.StatusCode, "HTTP status code")

	// Verify headers were forwarded
	if receivedHeaders.Get("X-Custom-Header") != "test-value" {
		t.Errorf("Custom header not forwarded correctly")
	}

	t.Log("Custom headers forwarded successfully")
}
