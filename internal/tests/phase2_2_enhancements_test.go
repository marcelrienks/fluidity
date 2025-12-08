package tests

import (
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"fluidity/internal/shared/circuitbreaker"
)

// ============================================================================
// PHASE 2.2: CIRCUIT BREAKER ENHANCEMENTS
// ============================================================================

// TestCircuitBreakerMetrics_TrackingFailures verifies metrics collection
func TestCircuitBreakerMetrics_TrackingFailures(t *testing.T) {
	config := circuitbreaker.Config{
		MaxFailures:     3,
		ResetTimeout:    100 * time.Millisecond,
		HalfOpenTimeout: 500 * time.Millisecond,
		MaxHalfOpenReqs: 2,
	}
	cb := circuitbreaker.New(config)

	testErr := errors.New("test error")

	// Execute 3 failures to trip the circuit
	for i := 0; i < 3; i++ {
		_ = cb.Execute(func() error {
			return testErr
		})
	}

	// Circuit should now be open
	if cb.GetState() != circuitbreaker.StateOpen {
		t.Error("Expected circuit to be open after 3 failures")
	}

	if cb.GetFailures() < 3 {
		t.Errorf("Expected at least 3 failures tracked, got %d", cb.GetFailures())
	}
}

// TestCircuitBreakerMetrics_SuccessResets verifies success resets failures
func TestCircuitBreakerMetrics_SuccessResets(t *testing.T) {
	config := circuitbreaker.Config{
		MaxFailures:     5,
		ResetTimeout:    100 * time.Millisecond,
		HalfOpenTimeout: 500 * time.Millisecond,
		MaxHalfOpenReqs: 2,
	}
	cb := circuitbreaker.New(config)

	testErr := errors.New("test error")

	// Fail twice
	for i := 0; i < 2; i++ {
		_ = cb.Execute(func() error {
			return testErr
		})
	}

	if cb.GetFailures() != 2 {
		t.Errorf("Expected 2 failures, got %d", cb.GetFailures())
	}

	// Succeed once
	_ = cb.Execute(func() error {
		return nil
	})

	// Failure count should reset to 0 in closed state
	if cb.GetFailures() != 0 {
		t.Errorf("Expected failure count to reset on success, got %d", cb.GetFailures())
	}
}

// TestCircuitBreakerConcurrency_RaceConditions verifies thread safety
func TestCircuitBreakerConcurrency_RaceConditions(t *testing.T) {
	config := circuitbreaker.Config{
		MaxFailures:     100,
		ResetTimeout:    500 * time.Millisecond,
		HalfOpenTimeout: 200 * time.Millisecond,
		MaxHalfOpenReqs: 50,
	}
	cb := circuitbreaker.New(config)

	var wg sync.WaitGroup
	successCount := atomic.Int32{}
	failureCount := atomic.Int32{}
	blockedCount := atomic.Int32{}

	// Run 50 concurrent goroutines
	for i := 0; i < 50; i++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()

			// Fail on odd IDs, succeed on even
			shouldFail := id%2 == 1

			err := cb.Execute(func() error {
				if shouldFail {
					return errors.New("simulated failure")
				}
				return nil
			})

			if err == circuitbreaker.ErrCircuitOpen || err == circuitbreaker.ErrTooManyRequests {
				blockedCount.Add(1)
			} else if err != nil {
				failureCount.Add(1)
			} else {
				successCount.Add(1)
			}
		}(i)
	}

	wg.Wait()

	// Verify all requests were accounted for
	total := successCount.Load() + failureCount.Load() + blockedCount.Load()
	if total != 50 {
		t.Errorf("Expected 50 total requests, got %d (success: %d, fail: %d, blocked: %d)",
			total, successCount.Load(), failureCount.Load(), blockedCount.Load())
	}
}

// TestCircuitBreakerEdgeCases_ZeroConfig verifies default config application
func TestCircuitBreakerEdgeCases_ZeroConfig(t *testing.T) {
	config := circuitbreaker.Config{
		MaxFailures:     0, // Should default
		ResetTimeout:    0, // Should default
		HalfOpenTimeout: 0, // Should default
		MaxHalfOpenReqs: 0, // Should default
	}
	cb := circuitbreaker.New(config)

	// Should have defaults applied
	if cb.GetState() != circuitbreaker.StateClosed {
		t.Errorf("Expected initial state Closed, got %v", cb.GetState())
	}

	// Verify it works with defaults
	err := cb.Execute(func() error {
		return nil
	})
	if err != nil {
		t.Errorf("Expected no error with default config, got %v", err)
	}
}

// TestCircuitBreakerEdgeCases_NegativeConfig verifies negative values handled
func TestCircuitBreakerEdgeCases_NegativeConfig(t *testing.T) {
	config := circuitbreaker.Config{
		MaxFailures:     -5,      // Should default
		ResetTimeout:    -100,    // Should default
		HalfOpenTimeout: -50,     // Should default
		MaxHalfOpenReqs: -10,     // Should default
	}
	cb := circuitbreaker.New(config)

	if cb.GetState() != circuitbreaker.StateClosed {
		t.Error("Expected initial state to be Closed with negative config")
	}

	// Should work correctly
	err := cb.Execute(func() error {
		return nil
	})
	if err != nil {
		t.Errorf("Expected no error with negative config defaults, got %v", err)
	}
}

// TestCircuitBreakerStateTransition_ClosedToHalfOpenToOpenCycle
func TestCircuitBreakerStateTransition_ClosedToHalfOpenToOpenCycle(t *testing.T) {
	config := circuitbreaker.Config{
		MaxFailures:     2,
		ResetTimeout:    100 * time.Millisecond,
		HalfOpenTimeout: 500 * time.Millisecond,
		MaxHalfOpenReqs: 2,
	}
	cb := circuitbreaker.New(config)

	testErr := errors.New("test error")

	// Phase 1: Closed state
	if cb.GetState() != circuitbreaker.StateClosed {
		t.Error("Expected initial state Closed")
	}

	// Phase 2: Transition to Open
	for i := 0; i < 2; i++ {
		_ = cb.Execute(func() error {
			return testErr
		})
	}

	if cb.GetState() != circuitbreaker.StateOpen {
		t.Error("Expected state Open after failures")
	}

	// Phase 3: Blocked requests
	err := cb.Execute(func() error {
		return nil
	})
	if err != circuitbreaker.ErrCircuitOpen {
		t.Errorf("Expected ErrCircuitOpen when open, got %v", err)
	}

	// Phase 4: Wait for reset timeout and transition to HalfOpen
	time.Sleep(150 * time.Millisecond)

	err = cb.Execute(func() error {
		return nil
	})
	if err != nil {
		t.Errorf("Expected success in half-open, got %v", err)
	}

	if cb.GetState() != circuitbreaker.StateHalfOpen {
		t.Errorf("Expected state HalfOpen, got %v", cb.GetState())
	}

	// Phase 5: Failure in HalfOpen transitions back to Open
	_ = cb.Execute(func() error {
		return testErr
	})

	if cb.GetState() != circuitbreaker.StateOpen {
		t.Error("Expected state Open after failure in HalfOpen")
	}
}

// TestCircuitBreakerHalfOpenLimit_ExceedsMaxRequests verifies request limiting
func TestCircuitBreakerHalfOpenLimit_ExceedsMaxRequests(t *testing.T) {
	config := circuitbreaker.Config{
		MaxFailures:     2,
		ResetTimeout:    100 * time.Millisecond,
		HalfOpenTimeout: 500 * time.Millisecond,
		MaxHalfOpenReqs: 2,
	}
	cb := circuitbreaker.New(config)

	testErr := errors.New("test error")

	// Open circuit
	for i := 0; i < 2; i++ {
		_ = cb.Execute(func() error {
			return testErr
		})
	}

	time.Sleep(150 * time.Millisecond)

	// Succeed twice (reaching MaxHalfOpenReqs)
	for i := 0; i < 2; i++ {
		err := cb.Execute(func() error {
			return nil
		})
		if err != nil {
			t.Errorf("Request %d should succeed, got %v", i, err)
		}
	}

	// Circuit should now be closed
	if cb.GetState() != circuitbreaker.StateClosed {
		t.Errorf("Expected state Closed after max half-open successes, got %v", cb.GetState())
	}

	// New requests should execute normally
	err := cb.Execute(func() error {
		return nil
	})
	if err != nil {
		t.Errorf("Expected normal execution after closing, got %v", err)
	}
}

// TestCircuitBreakerStateValidation verifies state transitions are correct
func TestCircuitBreakerStateValidation(t *testing.T) {
	config := circuitbreaker.Config{
		MaxFailures:     1,
		ResetTimeout:    200 * time.Millisecond,
		HalfOpenTimeout: 200 * time.Millisecond,
		MaxHalfOpenReqs: 1,
	}
	cb := circuitbreaker.New(config)

	// Verify initial closed state
	if cb.GetState() != circuitbreaker.StateClosed {
		t.Error("Expected initial state Closed")
	}

	// Transition to Open
	_ = cb.Execute(func() error {
		return errors.New("fail")
	})

	if cb.GetState() != circuitbreaker.StateOpen {
		t.Error("Expected state Open after failure")
	}

	// Verify Open state blocks requests
	err := cb.Execute(func() error {
		return nil
	})
	if err != circuitbreaker.ErrCircuitOpen {
		t.Error("Expected ErrCircuitOpen when open")
	}
}

// TestCircuitBreakerConcurrency_SimultaneousStateCheck verifies no race on GetState
func TestCircuitBreakerConcurrency_SimultaneousStateCheck(t *testing.T) {
	cb := circuitbreaker.New(circuitbreaker.DefaultConfig())

	states := make(chan circuitbreaker.State, 100)
	var wg sync.WaitGroup

	// 50 concurrent state checks
	for i := 0; i < 50; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			states <- cb.GetState()
		}()
	}

	wg.Wait()
	close(states)

	// All should be StateClosed
	for state := range states {
		if state != circuitbreaker.StateClosed {
			t.Errorf("Expected StateClosed from concurrent reads, got %v", state)
		}
	}
}

// ============================================================================
// PHASE 2.2: CONFIGURATION EDGE CASES
// ============================================================================

// TestConfigValidation_LargeValues verifies handling of very large configs
func TestConfigValidation_LargeValues(t *testing.T) {
	config := circuitbreaker.Config{
		MaxFailures:     1000,
		ResetTimeout:    1 * time.Hour,
		HalfOpenTimeout: 30 * time.Minute,
		MaxHalfOpenReqs: 500,
	}
	cb := circuitbreaker.New(config)

	// Should not panic or error
	if cb.GetState() != circuitbreaker.StateClosed {
		t.Error("Expected initial state Closed with large config")
	}

	err := cb.Execute(func() error {
		return nil
	})
	if err != nil {
		t.Errorf("Expected normal execution with large config, got %v", err)
	}
}

// TestConfigValidation_EdgeCaseHandling verifies config edge cases
func TestConfigValidation_EdgeCaseHandling(t *testing.T) {
	// Test with all minimal values
	config := circuitbreaker.Config{
		MaxFailures:     1,
		ResetTimeout:    10 * time.Millisecond,
		HalfOpenTimeout: 10 * time.Millisecond,
		MaxHalfOpenReqs: 1,
	}
	cb := circuitbreaker.New(config)

	if cb.GetState() != circuitbreaker.StateClosed {
		t.Error("Expected initial state Closed")
	}

	// Single failure should open
	_ = cb.Execute(func() error {
		return errors.New("fail")
	})

	if cb.GetState() != circuitbreaker.StateOpen {
		t.Error("Expected state Open after 1 failure")
	}

	// Verify circuit is properly open
	err := cb.Execute(func() error {
		t.Error("Function should not execute when circuit is open")
		return nil
	})

	if err != circuitbreaker.ErrCircuitOpen {
		t.Errorf("Expected ErrCircuitOpen, got %v", err)
	}
}

// ============================================================================
// PHASE 2.2: RETRY LOGIC COVERAGE
// ============================================================================

// TestRetryLogic_SimpleRetry verifies basic retry functionality
func TestRetryLogic_SimpleRetry(t *testing.T) {
	attempts := 0
	cb := circuitbreaker.New(circuitbreaker.DefaultConfig())

	// Circuit breaker allows retries - test with manual retry loop
	maxAttempts := 3
	var lastErr error

	for attempt := 0; attempt < maxAttempts; attempt++ {
		attempts++
		lastErr = cb.Execute(func() error {
			if attempts < 3 {
				return errors.New("temporary failure")
			}
			return nil
		})

		if lastErr == nil {
			break
		}
	}

	if attempts != 3 {
		t.Errorf("Expected 3 attempts, got %d", attempts)
	}

	if lastErr != nil {
		t.Errorf("Expected success after retry, got %v", lastErr)
	}
}

// TestRetryLogic_CircuitBreakerPreventsRetry verifies CB stops retries
func TestRetryLogic_CircuitBreakerPreventsRetry(t *testing.T) {
	config := circuitbreaker.Config{
		MaxFailures:     2,
		ResetTimeout:    100 * time.Millisecond,
		HalfOpenTimeout: 500 * time.Millisecond,
		MaxHalfOpenReqs: 1,
	}
	cb := circuitbreaker.New(config)

	attempts := 0
	testErr := errors.New("failure")

	// Fail enough to open circuit
	for i := 0; i < 2; i++ {
		attempts++
		_ = cb.Execute(func() error {
			return testErr
		})
	}

	initialAttempts := attempts

	// Try to retry - should be blocked
	for i := 0; i < 10; i++ {
		err := cb.Execute(func() error {
			attempts++
			return nil
		})

		// Should get circuit open error
		if err != circuitbreaker.ErrCircuitOpen {
			t.Errorf("Expected ErrCircuitOpen, got %v", err)
		}
	}

	// Verify function was never called due to circuit being open
	if attempts != initialAttempts {
		t.Errorf("Expected attempts to stay at %d, got %d", initialAttempts, attempts)
	}
}

// TestRetryLogic_ExponentialBackoff simulates exponential backoff pattern
func TestRetryLogic_ExponentialBackoff(t *testing.T) {
	config := circuitbreaker.Config{
		MaxFailures:     10,
		ResetTimeout:    1 * time.Second,
		HalfOpenTimeout: 500 * time.Millisecond,
		MaxHalfOpenReqs: 3,
	}
	cb := circuitbreaker.New(config)

	attempts := 0
	maxAttempts := 5
	backoffDurations := []time.Duration{
		10 * time.Millisecond,
		20 * time.Millisecond,
		40 * time.Millisecond,
		80 * time.Millisecond,
	}

	var lastErr error

	for attempt := 0; attempt < maxAttempts; attempt++ {
		err := cb.Execute(func() error {
			attempts++
			if attempts < 3 {
				return errors.New("failure")
			}
			return nil
		})

		if err == nil {
			lastErr = err
			break
		}

		if attempt < len(backoffDurations) {
			time.Sleep(backoffDurations[attempt])
		}
		lastErr = err
	}

	if lastErr != nil {
		t.Errorf("Expected eventual success with backoff, got %v", lastErr)
	}

	if attempts < 3 {
		t.Errorf("Expected at least 3 attempts for success, got %d", attempts)
	}
}

// TestRetryLogic_WithCircuitBreakerRecovery tests retry during recovery
func TestRetryLogic_WithCircuitBreakerRecovery(t *testing.T) {
	config := circuitbreaker.Config{
		MaxFailures:     2,
		ResetTimeout:    100 * time.Millisecond,
		HalfOpenTimeout: 500 * time.Millisecond,
		MaxHalfOpenReqs: 2,
	}
	cb := circuitbreaker.New(config)

	// Open the circuit
	testErr := errors.New("failure")
	for i := 0; i < 2; i++ {
		_ = cb.Execute(func() error {
			return testErr
		})
	}

	if cb.GetState() != circuitbreaker.StateOpen {
		t.Error("Expected circuit open")
	}

	// Wait for reset timeout
	time.Sleep(150 * time.Millisecond)

	// Now retry in half-open state
	attempts := 0
	maxAttempts := 5

	for attempt := 0; attempt < maxAttempts; attempt++ {
		err := cb.Execute(func() error {
			attempts++
			return nil // Succeed during recovery
		})

		if err != nil && err != circuitbreaker.ErrTooManyRequests {
			t.Errorf("Unexpected error during recovery: %v", err)
		}

		if cb.GetState() == circuitbreaker.StateClosed {
			break
		}
	}

	if cb.GetState() != circuitbreaker.StateClosed {
		t.Errorf("Expected circuit closed after recovery, got %v", cb.GetState())
	}
}

// TestRetryLogic_DifferentErrorTypes verifies handling of different error types
func TestRetryLogic_DifferentErrorTypes(t *testing.T) {
	cb := circuitbreaker.New(circuitbreaker.DefaultConfig())

	errors := []error{
		errors.New("network error"),
		errors.New("timeout"),
		errors.New("auth failed"),
	}

	for _, testErr := range errors {
		err := cb.Execute(func() error {
			return testErr
		})

		if err != testErr {
			t.Errorf("Expected error %v, got %v", testErr, err)
		}
	}

	// Circuit should still be closed with DefaultConfig
	if cb.GetState() != circuitbreaker.StateClosed {
		t.Errorf("Expected circuit closed with 3 different errors and DefaultConfig")
	}
}

// TestRetryLogic_SuccessRateMonitoring tracks success during recovery
func TestRetryLogic_SuccessRateMonitoring(t *testing.T) {
	config := circuitbreaker.Config{
		MaxFailures:     3,
		ResetTimeout:    100 * time.Millisecond,
		HalfOpenTimeout: 500 * time.Millisecond,
		MaxHalfOpenReqs: 3,
	}
	cb := circuitbreaker.New(config)

	// Open circuit
	for i := 0; i < 3; i++ {
		_ = cb.Execute(func() error {
			return errors.New("fail")
		})
	}

	time.Sleep(150 * time.Millisecond)

	// Monitor success rate during recovery
	successCount := 0
	failureCount := 0

	for i := 0; i < 6; i++ {
		err := cb.Execute(func() error {
			if i%2 == 0 { // Even attempts succeed
				return nil
			}
			return errors.New("intermittent failure")
		})

		if err != nil && err != circuitbreaker.ErrTooManyRequests {
			failureCount++
		} else if err == nil {
			successCount++
		}
	}

	// Verify mixed success/failure was tracked
	if successCount == 0 {
		t.Error("Expected some successes during recovery")
	}
}
