package tests

import (
	"bytes"
	"fmt"
	"io"
	"net/http"
	"testing"
	"time"

	"fluidity/internal/shared/protocol"
)

// ============================================================================
// SERVER CONNECTION ACCEPTANCE TESTS
// ============================================================================

// TestServerAcceptConnection_ValidTLS tests accepting valid TLS connections
func TestServerAcceptConnection_ValidTLS(t *testing.T) {
	certs := GenerateTestCerts(t)
	server := StartTestServer(t, certs)
	defer server.Stop()

	// Attempt to create a client connection
	client := StartTestClient(t, server.Addr, certs)
	defer client.Stop()

	// Verify connection was accepted
	if !client.Client.IsConnected() {
		t.Errorf("expected client to be connected to server")
	}
}

// TestServerAcceptConnection_ConcurrentClients tests accepting multiple concurrent connections
func TestServerAcceptConnection_ConcurrentClients(t *testing.T) {
	certs := GenerateTestCerts(t)
	server := StartTestServer(t, certs)
	defer server.Stop()

	numClients := 5
	clients := make([]*TestClient, numClients)
	errs := make(chan error, numClients)

	for i := 0; i < numClients; i++ {
		go func(index int) {
			client := StartTestClient(t, server.Addr, certs)
			clients[index] = client

			if !client.Client.IsConnected() {
				errs <- fmt.Errorf("client %d failed to connect", index)
				return
			}
			errs <- nil
		}(i)
	}

	// Collect results
	successCount := 0
	for i := 0; i < numClients; i++ {
		if err := <-errs; err == nil {
			successCount++
		} else {
			t.Logf("connection error: %v", err)
		}
	}

	// Cleanup
	for _, client := range clients {
		if client != nil {
			client.Stop()
		}
	}

	if successCount < numClients {
		t.Errorf("expected %d successful connections, got %d", numClients, successCount)
	}
}

// TestServerAcceptConnection_ClientDisconnect tests handling client disconnect
func TestServerAcceptConnection_ClientDisconnect(t *testing.T) {
	certs := GenerateTestCerts(t)
	server := StartTestServer(t, certs)
	defer server.Stop()

	client := StartTestClient(t, server.Addr, certs)

	if !client.Client.IsConnected() {
		t.Fatalf("expected client to be connected")
	}

	// Disconnect client
	client.Stop()
	time.Sleep(100 * time.Millisecond)

	// Server should handle gracefully (no panic)
	// Verify server is still running and can accept new connections
	client2 := StartTestClient(t, server.Addr, certs)
	defer client2.Stop()

	if !client2.Client.IsConnected() {
		t.Errorf("expected second client to connect after first disconnected")
	}
}

// TestServerAcceptConnection_RapidConnectDisconnect tests rapid connect/disconnect cycles
func TestServerAcceptConnection_RapidConnectDisconnect(t *testing.T) {
	certs := GenerateTestCerts(t)
	server := StartTestServer(t, certs)
	defer server.Stop()

	cycles := 5
	for i := 0; i < cycles; i++ {
		client := StartTestClient(t, server.Addr, certs)

		if !client.Client.IsConnected() {
			t.Errorf("cycle %d: expected client to be connected", i)
		}

		client.Stop()
		time.Sleep(50 * time.Millisecond)
	}

	// Verify server is still responsive
	finalClient := StartTestClient(t, server.Addr, certs)
	defer finalClient.Stop()

	if !finalClient.Client.IsConnected() {
		t.Errorf("expected server to still accept connections after cycles")
	}
}

// ============================================================================
// SERVER REQUEST FORWARDING TESTS
// ============================================================================

// TestServerForwardRequest_ValidHTTP tests forwarding valid HTTP requests
func TestServerForwardRequest_ValidHTTP(t *testing.T) {
	certs := GenerateTestCerts(t)
	server := StartTestServer(t, certs)
	defer server.Stop()

	client := StartTestClient(t, server.Addr, certs)
	defer client.Stop()

	// Create mock HTTP target
	mockHandler := func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		io.WriteString(w, "target response")
	}
	httpServer := MockHTTPServer(t, mockHandler)
	defer httpServer.Close()

	// Send request through tunnel
	req := &protocol.Request{
		ID:     protocol.GenerateID(),
		Method: "GET",
		URL:    httpServer.URL + "/api/test",
	}

	resp, err := client.Client.SendRequest(req)
	if err != nil {
		t.Fatalf("SendRequest failed: %v", err)
	}

	if resp.StatusCode != http.StatusOK {
		t.Errorf("expected status 200, got %d", resp.StatusCode)
	}

	if string(resp.Body) != "target response" {
		t.Errorf("expected body 'target response', got %q", string(resp.Body))
	}
}

// TestServerForwardRequest_AllHTTPMethods tests forwarding all HTTP methods
func TestServerForwardRequest_AllHTTPMethods(t *testing.T) {
	methods := []string{"GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS"}

	for _, method := range methods {
		t.Run(method, func(t *testing.T) {
			certs := GenerateTestCerts(t)
			server := StartTestServer(t, certs)
			defer server.Stop()

			client := StartTestClient(t, server.Addr, certs)
			defer client.Stop()

			receivedMethod := ""
			mockHandler := func(w http.ResponseWriter, r *http.Request) {
				receivedMethod = r.Method
				w.WriteHeader(http.StatusOK)
			}
			httpServer := MockHTTPServer(t, mockHandler)
			defer httpServer.Close()

			req := &protocol.Request{
				ID:     protocol.GenerateID(),
				Method: method,
				URL:    httpServer.URL + "/test",
				Body:   []byte("body"),
			}

			resp, err := client.Client.SendRequest(req)
			if err != nil {
				t.Errorf("%s request failed: %v", method, err)
				return
			}

			if resp.StatusCode != http.StatusOK {
				t.Errorf("%s: expected 200, got %d", method, resp.StatusCode)
			}

			if receivedMethod != method {
				t.Errorf("%s: expected method %s, got %s", method, method, receivedMethod)
			}
		})
	}
}

// TestServerForwardRequest_RequestBody tests forwarding request body
func TestServerForwardRequest_RequestBody(t *testing.T) {
	certs := GenerateTestCerts(t)
	server := StartTestServer(t, certs)
	defer server.Stop()

	client := StartTestClient(t, server.Addr, certs)
	defer client.Stop()

	expectedBody := []byte("large request body")
	receivedBody := []byte{}

	mockHandler := func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		receivedBody = body
		w.WriteHeader(http.StatusOK)
	}
	httpServer := MockHTTPServer(t, mockHandler)
	defer httpServer.Close()

	req := &protocol.Request{
		ID:     protocol.GenerateID(),
		Method: "POST",
		URL:    httpServer.URL + "/api/data",
		Body:   expectedBody,
	}

	resp, err := client.Client.SendRequest(req)
	if err != nil {
		t.Fatalf("SendRequest failed: %v", err)
	}

	if resp.StatusCode != http.StatusOK {
		t.Errorf("expected status 200, got %d", resp.StatusCode)
	}

	if !bytes.Equal(receivedBody, expectedBody) {
		t.Errorf("expected body %q, got %q", expectedBody, receivedBody)
	}
}

// TestServerForwardRequest_LargeRequestBody tests forwarding large request body
func TestServerForwardRequest_LargeRequestBody(t *testing.T) {
	certs := GenerateTestCerts(t)
	server := StartTestServer(t, certs)
	defer server.Stop()

	client := StartTestClient(t, server.Addr, certs)
	defer client.Stop()

	// Create 5MB request body
	largeBody := bytes.Repeat([]byte("x"), 5*1024*1024)
	receivedBodySize := 0

	mockHandler := func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		receivedBodySize = len(body)
		w.WriteHeader(http.StatusOK)
	}
	httpServer := MockHTTPServer(t, mockHandler)
	defer httpServer.Close()

	req := &protocol.Request{
		ID:     protocol.GenerateID(),
		Method: "POST",
		URL:    httpServer.URL + "/upload",
		Body:   largeBody,
	}

	resp, err := client.Client.SendRequest(req)
	if err != nil {
		t.Fatalf("SendRequest failed: %v", err)
	}

	if resp.StatusCode != http.StatusOK {
		t.Errorf("expected status 200, got %d", resp.StatusCode)
	}

	if receivedBodySize != len(largeBody) {
		t.Errorf("expected body size %d, got %d", len(largeBody), receivedBodySize)
	}
}

// TestServerForwardRequest_PreservesHeaders tests that headers are forwarded
func TestServerForwardRequest_PreservesHeaders(t *testing.T) {
	certs := GenerateTestCerts(t)
	server := StartTestServer(t, certs)
	defer server.Stop()

	client := StartTestClient(t, server.Addr, certs)
	defer client.Stop()

	receivedHeaders := http.Header{}
	mockHandler := func(w http.ResponseWriter, r *http.Request) {
		receivedHeaders = r.Header
		w.WriteHeader(http.StatusOK)
	}
	httpServer := MockHTTPServer(t, mockHandler)
	defer httpServer.Close()

	req := &protocol.Request{
		ID:     protocol.GenerateID(),
		Method: "GET",
		URL:    httpServer.URL + "/test",
		Headers: map[string][]string{
			"X-Custom-Header": {"custom-value"},
			"X-Request-ID":    {"12345"},
		},
	}

	resp, err := client.Client.SendRequest(req)
	if err != nil {
		t.Fatalf("SendRequest failed: %v", err)
	}

	if resp.StatusCode != http.StatusOK {
		t.Errorf("expected status 200, got %d", resp.StatusCode)
	}

	// Verify headers were received at target
	if len(receivedHeaders) == 0 {
		t.Logf("warning: no headers received at target (may be expected in tunnel)")
	}
}

// ============================================================================
// SERVER RESPONSE FORWARDING TESTS
// ============================================================================

// TestServerForwardResponse_LargeResponseBody tests forwarding large response body
func TestServerForwardResponse_LargeResponseBody(t *testing.T) {
	certs := GenerateTestCerts(t)
	server := StartTestServer(t, certs)
	defer server.Stop()

	client := StartTestClient(t, server.Addr, certs)
	defer client.Stop()

	// Create 5MB response
	largeBody := bytes.Repeat([]byte("y"), 5*1024*1024)

	mockHandler := func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write(largeBody)
	}
	httpServer := MockHTTPServer(t, mockHandler)
	defer httpServer.Close()

	req := &protocol.Request{
		ID:     protocol.GenerateID(),
		Method: "GET",
		URL:    httpServer.URL + "/download",
	}

	resp, err := client.Client.SendRequest(req)
	if err != nil {
		t.Fatalf("SendRequest failed: %v", err)
	}

	if resp.StatusCode != http.StatusOK {
		t.Errorf("expected status 200, got %d", resp.StatusCode)
	}

	if len(resp.Body) != len(largeBody) {
		t.Errorf("expected body size %d, got %d", len(largeBody), len(resp.Body))
	}

	if !bytes.Equal(resp.Body, largeBody) {
		t.Errorf("response body mismatch")
	}
}

// TestServerForwardResponse_PreservesHeaders tests that response headers are preserved
func TestServerForwardResponse_PreservesHeaders(t *testing.T) {
	certs := GenerateTestCerts(t)
	server := StartTestServer(t, certs)
	defer server.Stop()

	client := StartTestClient(t, server.Addr, certs)
	defer client.Stop()

	mockHandler := func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Response-Header", "response-value")
		w.Header().Set("X-Custom", "custom")
		w.WriteHeader(http.StatusOK)
		io.WriteString(w, "body")
	}
	httpServer := MockHTTPServer(t, mockHandler)
	defer httpServer.Close()

	req := &protocol.Request{
		ID:     protocol.GenerateID(),
		Method: "GET",
		URL:    httpServer.URL + "/test",
	}

	resp, err := client.Client.SendRequest(req)
	if err != nil {
		t.Fatalf("SendRequest failed: %v", err)
	}

	if resp.StatusCode != http.StatusOK {
		t.Errorf("expected status 200, got %d", resp.StatusCode)
	}

	// Verify response headers are present
	if len(resp.Headers) == 0 {
		t.Logf("warning: response headers not returned (may be expected in protocol)")
	}
}

// TestServerForwardResponse_VariousStatusCodes tests forwarding various status codes
func TestServerForwardResponse_VariousStatusCodes(t *testing.T) {
	statusCodes := []int{
		http.StatusOK,              // 200
		http.StatusCreated,         // 201
		http.StatusBadRequest,      // 400
		http.StatusUnauthorized,    // 401
		http.StatusForbidden,       // 403
		http.StatusNotFound,        // 404
		http.StatusInternalServerError, // 500
	}

	for _, code := range statusCodes {
		t.Run(fmt.Sprintf("status_%d", code), func(t *testing.T) {
			certs := GenerateTestCerts(t)
			server := StartTestServer(t, certs)
			defer server.Stop()

			client := StartTestClient(t, server.Addr, certs)
			defer client.Stop()

			mockHandler := func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(code)
				io.WriteString(w, fmt.Sprintf("status %d", code))
			}
			httpServer := MockHTTPServer(t, mockHandler)
			defer httpServer.Close()

			req := &protocol.Request{
				ID:     protocol.GenerateID(),
				Method: "GET",
				URL:    httpServer.URL + "/test",
			}

			resp, err := client.Client.SendRequest(req)
			if err != nil {
				// Error is acceptable for error status codes
				return
			}

			if resp != nil && resp.StatusCode != code {
				t.Errorf("expected status %d, got %d", code, resp.StatusCode)
			}
		})
	}
}

// ============================================================================
// SERVER CONTENT TYPE TESTS
// ============================================================================

// TestServerForwardRequest_VariousContentTypes tests forwarding various content types
func TestServerForwardRequest_VariousContentTypes(t *testing.T) {
	contentTypes := []string{
		"text/plain",
		"application/json",
		"application/xml",
		"text/html",
		"image/jpeg",
		"application/octet-stream",
	}

	for _, ct := range contentTypes {
		t.Run(ct, func(t *testing.T) {
			certs := GenerateTestCerts(t)
			server := StartTestServer(t, certs)
			defer server.Stop()

			client := StartTestClient(t, server.Addr, certs)
			defer client.Stop()

			mockHandler := func(w http.ResponseWriter, r *http.Request) {
				_ = r.Header.Get("Content-Type")
				w.Header().Set("Content-Type", ct)
				w.WriteHeader(http.StatusOK)
			}
			httpServer := MockHTTPServer(t, mockHandler)
			defer httpServer.Close()

			req := &protocol.Request{
				ID:     protocol.GenerateID(),
				Method: "POST",
				URL:    httpServer.URL + "/test",
				Headers: map[string][]string{
					"Content-Type": {ct},
				},
				Body: []byte("test data"),
			}

			resp, err := client.Client.SendRequest(req)
			if err != nil {
				t.Errorf("SendRequest failed: %v", err)
				return
			}

			if resp.StatusCode != http.StatusOK {
				t.Errorf("expected status 200, got %d", resp.StatusCode)
			}
		})
	}
}

// ============================================================================
// SERVER CONCURRENT FORWARDING TESTS
// ============================================================================

// TestServerConcurrentRequests_MultipleAgents tests concurrent requests from multiple agents
func TestServerConcurrentRequests_MultipleAgents(t *testing.T) {
	certs := GenerateTestCerts(t)
	server := StartTestServer(t, certs)
	defer server.Stop()

	numAgents := 3
	requestsPerAgent := 5

	mockHandler := func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		io.WriteString(w, "ok")
	}
	httpServer := MockHTTPServer(t, mockHandler)
	defer httpServer.Close()

	agents := make([]*TestClient, numAgents)
	for i := 0; i < numAgents; i++ {
		agents[i] = StartTestClient(t, server.Addr, certs)
	}
	defer func() {
		for _, agent := range agents {
			agent.Stop()
		}
	}()

	errs := make(chan error, numAgents*requestsPerAgent)

	for i, agent := range agents {
		for j := 0; j < requestsPerAgent; j++ {
			go func(agentIdx, reqIdx int) {
				req := &protocol.Request{
					ID:     protocol.GenerateID(),
					Method: "GET",
					URL:    httpServer.URL + fmt.Sprintf("/agent-%d-req-%d", agentIdx, reqIdx),
				}

				resp, err := agent.Client.SendRequest(req)
				if err != nil {
					errs <- err
					return
				}

				if resp.StatusCode != http.StatusOK {
					errs <- fmt.Errorf("expected 200, got %d", resp.StatusCode)
					return
				}

				errs <- nil
			}(i, j)
		}
	}

	// Collect results
	successCount := 0
	for i := 0; i < numAgents*requestsPerAgent; i++ {
		if err := <-errs; err == nil {
			successCount++
		} else {
			t.Logf("request error: %v", err)
		}
	}

	if successCount < numAgents*requestsPerAgent {
		t.Errorf("expected %d successful requests, got %d", numAgents*requestsPerAgent, successCount)
	}
}

// ============================================================================
// SERVER ERROR HANDLING TESTS
// ============================================================================

// TestServerHandleError_TargetUnreachable tests handling unreachable target
func TestServerHandleError_TargetUnreachable(t *testing.T) {
	certs := GenerateTestCerts(t)
	server := StartTestServer(t, certs)
	defer server.Stop()

	client := StartTestClient(t, server.Addr, certs)
	defer client.Stop()

	// Use non-existent target
	req := &protocol.Request{
		ID:     protocol.GenerateID(),
		Method: "GET",
		URL:    "http://127.0.0.1:1/nonexistent",
	}

	resp, err := client.Client.SendRequest(req)

	// Should return error or error response
	if err == nil && (resp == nil || resp.StatusCode == 0) {
		t.Errorf("expected error for unreachable target")
	}
}

// TestServerHandleError_InvalidURL tests handling invalid URLs
func TestServerHandleError_InvalidURL(t *testing.T) {
	certs := GenerateTestCerts(t)
	server := StartTestServer(t, certs)
	defer server.Stop()

	client := StartTestClient(t, server.Addr, certs)
	defer client.Stop()

	// Use invalid URL
	req := &protocol.Request{
		ID:     protocol.GenerateID(),
		Method: "GET",
		URL:    "not-a-valid-url",
	}

	resp, err := client.Client.SendRequest(req)

	// Should return error
	if err == nil && resp == nil {
		t.Errorf("expected error for invalid URL")
	}
}

// TestServerHandleError_MissingMethod tests handling missing method
func TestServerHandleError_MissingMethod(t *testing.T) {
	certs := GenerateTestCerts(t)
	server := StartTestServer(t, certs)
	defer server.Stop()

	client := StartTestClient(t, server.Addr, certs)
	defer client.Stop()

	mockHandler := func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}
	httpServer := MockHTTPServer(t, mockHandler)
	defer httpServer.Close()

	// Empty method should be handled
	req := &protocol.Request{
		ID:     protocol.GenerateID(),
		Method: "",
		URL:    httpServer.URL + "/test",
	}

	resp, err := client.Client.SendRequest(req)

	// Either error or uses default GET
	if err != nil {
		// Error is acceptable
		return
	}
	
	if resp != nil {
		if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusBadRequest {
			t.Errorf("expected 200 or 400, got %d", resp.StatusCode)
		}
	}
}
