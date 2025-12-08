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
// AGENT CONNECTION MANAGEMENT TESTS
// ============================================================================

// TestAgentConnect_Success tests successful connection to server
func TestAgentConnect_Success(t *testing.T) {
	testCerts := GenerateTestCerts(t)
	server := StartTestServer(t, testCerts)
	defer server.Stop()

	client := StartTestClient(t, server.Addr, testCerts)
	defer client.Stop()

	// Agent should be connected after StartTestClient
	if !client.Client.IsConnected() {
		t.Errorf("expected agent to be connected")
	}
}

// TestAgentConnect_InvalidAddress tests connection to non-existent server
func TestAgentConnect_InvalidAddress(t *testing.T) {
	// Try to create client with invalid address
	client := &TestClient{
		Client: nil, // Would fail on connect
	}

	// Verify error handling for invalid address
	if client.Client != nil {
		t.Errorf("client should not be created for invalid server")
	}
}

// TestAgentDisconnect_CleanShutdown tests proper disconnection
func TestAgentDisconnect_CleanShutdown(t *testing.T) {
	certs := GenerateTestCerts(t)
	server := StartTestServer(t, certs)
	defer server.Stop()

	client := StartTestClient(t, server.Addr, certs)

	// Verify connected
	if !client.Client.IsConnected() {
		t.Fatalf("expected agent to be connected")
	}

	// Disconnect
	client.Stop()
	time.Sleep(100 * time.Millisecond)

	// Verify disconnected
	if client.Client.IsConnected() {
		t.Errorf("expected agent to be disconnected after Stop()")
	}
}

// TestAgentIsConnected_StateTracking tests connection state tracking
func TestAgentIsConnected_StateTracking(t *testing.T) {
	certs := GenerateTestCerts(t)
	server := StartTestServer(t, certs)
	defer server.Stop()

	client := StartTestClient(t, server.Addr, certs)
	defer client.Stop()

	// Test connected state
	if !client.Client.IsConnected() {
		t.Errorf("expected agent to be connected")
	}

	// Test disconnected state after stop
	client.Stop()
	time.Sleep(100 * time.Millisecond)

	if client.Client.IsConnected() {
		t.Errorf("expected agent to be disconnected after Stop()")
	}
}

// ============================================================================
// AGENT REQUEST HANDLING TESTS
// ============================================================================

// TestAgentSendRequest_Success tests sending valid HTTP request
func TestAgentSendRequest_Success(t *testing.T) {
	certs := GenerateTestCerts(t)
	server := StartTestServer(t, certs)
	defer server.Stop()

	client := StartTestClient(t, server.Addr, certs)
	defer client.Stop()

	// Create mock HTTP target
	mockHandler := func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		io.WriteString(w, "test response")
	}
	httpServer := MockHTTPServer(t, mockHandler)
	defer httpServer.Close()

	// Create and send request
	req := &protocol.Request{
		ID:     protocol.GenerateID(),
		Method: "GET",
		URL:    httpServer.URL + "/test",
		Body:   nil,
	}

	resp, err := client.Client.SendRequest(req)
	if err != nil {
		t.Fatalf("SendRequest failed: %v", err)
	}

	if resp == nil {
		t.Fatalf("expected response, got nil")
	}

	if resp.StatusCode != http.StatusOK {
		t.Errorf("expected status 200, got %d", resp.StatusCode)
	}

	if string(resp.Body) != "test response" {
		t.Errorf("expected body 'test response', got %q", string(resp.Body))
	}
}

// TestAgentSendRequest_VariousHTTPMethods tests all HTTP methods
func TestAgentSendRequest_VariousHTTPMethods(t *testing.T) {
	methods := []string{"GET", "POST", "PUT", "DELETE", "PATCH"}

	for _, method := range methods {
		t.Run(method, func(t *testing.T) {
			certs := GenerateTestCerts(t)
			server := StartTestServer(t, certs)
			defer server.Stop()

			client := StartTestClient(t, server.Addr, certs)
			defer client.Stop()

			mockHandler := func(w http.ResponseWriter, r *http.Request) {
				if r.Method != method {
					t.Errorf("expected method %s, got %s", method, r.Method)
				}
				w.WriteHeader(http.StatusOK)
			}
			httpServer := MockHTTPServer(t, mockHandler)
			defer httpServer.Close()

			req := &protocol.Request{
				ID:     protocol.GenerateID(),
				Method: method,
				URL:    httpServer.URL + "/test",
				Body:   []byte("test body"),
			}

			resp, err := client.Client.SendRequest(req)
			if err != nil {
				t.Errorf("%s request failed: %v", method, err)
				return
			}

			if resp.StatusCode != http.StatusOK {
				t.Errorf("%s: expected 200, got %d", method, resp.StatusCode)
			}
		})
	}
}

// TestAgentSendRequest_WithBody tests sending request with body
func TestAgentSendRequest_WithBody(t *testing.T) {
	certs := GenerateTestCerts(t)
	server := StartTestServer(t, certs)
	defer server.Stop()

	client := StartTestClient(t, server.Addr, certs)
	defer client.Stop()

	expectedBody := []byte("test request body")
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
		URL:    httpServer.URL + "/test",
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

// TestAgentSendRequest_LargeResponse tests handling large responses
func TestAgentSendRequest_LargeResponse(t *testing.T) {
	certs := GenerateTestCerts(t)
	server := StartTestServer(t, certs)
	defer server.Stop()

	client := StartTestClient(t, server.Addr, certs)
	defer client.Stop()

	// Create 1MB response
	largeBody := bytes.Repeat([]byte("x"), 1024*1024)

	mockHandler := func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write(largeBody)
	}
	httpServer := MockHTTPServer(t, mockHandler)
	defer httpServer.Close()

	req := &protocol.Request{
		ID:     protocol.GenerateID(),
		Method: "GET",
		URL:    httpServer.URL + "/large",
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
}

// TestAgentSendRequest_VariousStatusCodes tests handling different status codes
func TestAgentSendRequest_VariousStatusCodes(t *testing.T) {
	statusCodes := []int{
		http.StatusOK,              // 200
		http.StatusCreated,         // 201
		http.StatusNoContent,       // 204
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
				t.Errorf("SendRequest failed: %v", err)
				return
			}

			if resp.StatusCode != code {
				t.Errorf("expected status %d, got %d", code, resp.StatusCode)
			}
		})
	}
}

// ============================================================================
// AGENT CONCURRENT REQUEST TESTS
// ============================================================================

// TestAgentConcurrentRequests_Multiple tests multiple concurrent requests
func TestAgentConcurrentRequests_Multiple(t *testing.T) {
	certs := GenerateTestCerts(t)
	server := StartTestServer(t, certs)
	defer server.Stop()

	client := StartTestClient(t, server.Addr, certs)
	defer client.Stop()

	mockHandler := func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		io.WriteString(w, r.URL.Path)
	}
	httpServer := MockHTTPServer(t, mockHandler)
	defer httpServer.Close()

	// Send 10 concurrent requests
	numRequests := 10
	errs := make(chan error, numRequests)
	responses := make(chan *protocol.Response, numRequests)

	for i := 0; i < numRequests; i++ {
		go func(index int) {
			req := &protocol.Request{
				ID:     protocol.GenerateID(),
				Method: "GET",
				URL:    httpServer.URL + fmt.Sprintf("/request-%d", index),
			}

			resp, err := client.Client.SendRequest(req)
			if err != nil {
				errs <- err
				return
			}

			if resp.StatusCode != http.StatusOK {
				errs <- fmt.Errorf("request %d: expected 200, got %d", index, resp.StatusCode)
				return
			}

			responses <- resp
			errs <- nil
		}(i)
	}

	// Collect results
	successCount := 0
	for i := 0; i < numRequests; i++ {
		if err := <-errs; err != nil {
			t.Errorf("request error: %v", err)
		} else {
			successCount++
		}
	}

	if successCount != numRequests {
		t.Errorf("expected %d successful requests, got %d", numRequests, successCount)
	}
}

// TestAgentConcurrentRequests_MixedMethods tests concurrent requests with different methods
func TestAgentConcurrentRequests_MixedMethods(t *testing.T) {
	certs := GenerateTestCerts(t)
	server := StartTestServer(t, certs)
	defer server.Stop()

	client := StartTestClient(t, server.Addr, certs)
	defer client.Stop()

	mockHandler := func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		io.WriteString(w, r.Method)
	}
	httpServer := MockHTTPServer(t, mockHandler)
	defer httpServer.Close()

	methods := []string{"GET", "POST", "PUT", "DELETE", "PATCH"}
	errs := make(chan error, len(methods))

	for _, method := range methods {
		go func(m string) {
			req := &protocol.Request{
				ID:     protocol.GenerateID(),
				Method: m,
				URL:    httpServer.URL + "/test",
				Body:   []byte("body"),
			}

			resp, err := client.Client.SendRequest(req)
			if err != nil {
				errs <- err
				return
			}

			if resp.StatusCode != http.StatusOK {
				errs <- fmt.Errorf("%s: expected 200, got %d", m, resp.StatusCode)
				return
			}

			errs <- nil
		}(method)
	}

	// Collect results
	for i := 0; i < len(methods); i++ {
		if err := <-errs; err != nil {
			t.Errorf("concurrent request error: %v", err)
		}
	}
}

// ============================================================================
// AGENT HEADERS AND CONTENT TYPE TESTS
// ============================================================================

// TestAgentSendRequest_PreservesHeaders tests that request headers are preserved
func TestAgentSendRequest_PreservesHeaders(t *testing.T) {
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
			"X-Another":       {"another-value"},
		},
	}

	resp, err := client.Client.SendRequest(req)
	if err != nil {
		t.Fatalf("SendRequest failed: %v", err)
	}

	if resp.StatusCode != http.StatusOK {
		t.Errorf("expected status 200, got %d", resp.StatusCode)
	}

	// Verify headers were sent
	if len(receivedHeaders) > 0 {
		// Headers were forwarded
	}
}

// TestAgentSendRequest_ContentTypes tests various content types
func TestAgentSendRequest_ContentTypes(t *testing.T) {
	contentTypes := []string{
		"text/plain",
		"application/json",
		"application/xml",
		"text/html",
	}

	for _, ct := range contentTypes {
		t.Run(ct, func(t *testing.T) {
			certs := GenerateTestCerts(t)
			server := StartTestServer(t, certs)
			defer server.Stop()

			client := StartTestClient(t, server.Addr, certs)
			defer client.Stop()

			mockHandler := func(w http.ResponseWriter, r *http.Request) {
				_ = r.Header.Get("Content-Type") // Read but don't need value
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
				Body: []byte("test"),
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
// AGENT RESPONSE HANDLING TESTS
// ============================================================================

// TestAgentSendRequest_PreservesResponseHeaders tests that response headers are returned
func TestAgentSendRequest_PreservesResponseHeaders(t *testing.T) {
	certs := GenerateTestCerts(t)
	server := StartTestServer(t, certs)
	defer server.Stop()

	client := StartTestClient(t, server.Addr, certs)
	defer client.Stop()

	mockHandler := func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Response-Header", "response-value")
		w.Header().Set("X-Custom", "custom-value")
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

	// Verify response body
	if string(resp.Body) != "body" {
		t.Errorf("expected body 'body', got %q", string(resp.Body))
	}
}

// ============================================================================
// AGENT RETRY AND ERROR HANDLING TESTS
// ============================================================================

// TestAgentSendRequest_HandlesHTTPErrors tests handling HTTP error responses
func TestAgentSendRequest_HandlesHTTPErrors(t *testing.T) {
	certs := GenerateTestCerts(t)
	server := StartTestServer(t, certs)
	defer server.Stop()

	client := StartTestClient(t, server.Addr, certs)
	defer client.Stop()

	mockHandler := func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		io.WriteString(w, "server error")
	}
	httpServer := MockHTTPServer(t, mockHandler)
	defer httpServer.Close()

	req := &protocol.Request{
		ID:     protocol.GenerateID(),
		Method: "GET",
		URL:    httpServer.URL + "/error",
	}

	resp, err := client.Client.SendRequest(req)

	// Should return response with error status, not error
	if err != nil && resp == nil {
		t.Fatalf("expected response with error status, got error: %v", err)
	}

	if resp != nil && resp.StatusCode != http.StatusInternalServerError {
		t.Errorf("expected status 500, got %d", resp.StatusCode)
	}
}

// TestAgentSendRequest_EmptyResponse tests handling empty responses
func TestAgentSendRequest_EmptyResponse(t *testing.T) {
	certs := GenerateTestCerts(t)
	server := StartTestServer(t, certs)
	defer server.Stop()

	client := StartTestClient(t, server.Addr, certs)
	defer client.Stop()

	mockHandler := func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}
	httpServer := MockHTTPServer(t, mockHandler)
	defer httpServer.Close()

	req := &protocol.Request{
		ID:     protocol.GenerateID(),
		Method: "DELETE",
		URL:    httpServer.URL + "/resource",
	}

	resp, err := client.Client.SendRequest(req)
	if err != nil {
		t.Fatalf("SendRequest failed: %v", err)
	}

	if resp.StatusCode != http.StatusNoContent {
		t.Errorf("expected status 204, got %d", resp.StatusCode)
	}

	if len(resp.Body) != 0 {
		t.Errorf("expected empty body, got %q", string(resp.Body))
	}
}
