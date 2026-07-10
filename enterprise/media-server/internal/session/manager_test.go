package session

import (
	"strings"
	"testing"
	"time"

	"github.com/chatwoot/chatwoot-media-server/internal/config"
)

func TestManagerReservesConcurrentSessionCapacityAtomically(t *testing.T) {
	manager := &Manager{
		sessions: make(map[string]*Session),
		config:   &config.Config{MaxConcurrentSessions: 1},
	}

	const attempts = 32
	start := make(chan struct{})
	release := make(chan struct{})
	results := make(chan error, attempts)
	done := make(chan struct{}, attempts)

	for range attempts {
		go func() {
			<-start
			err := manager.reserveSessionSlot()
			results <- err
			if err == nil {
				<-release
				manager.releaseSessionSlot()
				manager.createWG.Done()
			}
			done <- struct{}{}
		}()
	}
	close(start)

	successes := 0
	for range attempts {
		if <-results == nil {
			successes++
		}
	}
	if successes != 1 {
		t.Fatalf("successful concurrent reservations = %d, want 1", successes)
	}

	close(release)
	for range attempts {
		<-done
	}
	if err := manager.reserveSessionSlot(); err != nil {
		t.Fatalf("reservation after release failed: %v", err)
	}
	manager.releaseSessionSlot()
	manager.createWG.Done()
}

func TestManagerUnlimitedCapacityDoesNotLeakReservations(t *testing.T) {
	manager := &Manager{
		sessions: make(map[string]*Session),
		config:   &config.Config{MaxConcurrentSessions: 0},
	}

	if err := manager.reserveSessionSlot(); err != nil {
		t.Fatalf("unlimited reservation failed: %v", err)
	}
	manager.releaseSessionSlot()
	manager.createWG.Done()

	if manager.pendingSessions != 0 {
		t.Fatalf("pending sessions = %d, want 0 after release", manager.pendingSessions)
	}
}

func TestManagerCommitsPendingReservationAtomically(t *testing.T) {
	manager := &Manager{
		sessions: make(map[string]*Session),
		config:   &config.Config{MaxConcurrentSessions: 1},
	}
	if err := manager.reserveSessionSlot(); err != nil {
		t.Fatalf("reserve session: %v", err)
	}
	if err := manager.commitSessionSlot("session-1", &Session{}); err != nil {
		t.Fatalf("commit session: %v", err)
	}
	manager.createWG.Done()

	if manager.pendingSessions != 0 || len(manager.sessions) != 1 {
		t.Fatalf("pending=%d active=%d, want pending=0 active=1", manager.pendingSessions, len(manager.sessions))
	}
	if err := manager.reserveSessionSlot(); err == nil {
		manager.releaseSessionSlot()
		manager.createWG.Done()
		t.Fatal("expected active session to retain the only capacity slot")
	}
}

func TestManagerCountsTerminatingSessionsAgainstCapacity(t *testing.T) {
	manager := &Manager{
		sessions:            make(map[string]*Session),
		config:              &config.Config{MaxConcurrentSessions: 1},
		terminatingSessions: 1,
	}

	if err := manager.reserveSessionSlot(); err == nil {
		manager.releaseSessionSlot()
		manager.createWG.Done()
		t.Fatal("expected terminating session to retain the only capacity slot")
	}
}

func TestManagerShutdownWaitsForPendingCreationAndIsIdempotent(t *testing.T) {
	manager := NewManager(&config.Config{}, nil)
	if err := manager.reserveSessionSlot(); err != nil {
		t.Fatalf("reserve session: %v", err)
	}

	shutdownDone := make(chan struct{})
	go func() {
		manager.Shutdown()
		close(shutdownDone)
	}()
	secondShutdownDone := make(chan struct{})
	go func() {
		manager.Shutdown()
		close(secondShutdownDone)
	}()

	deadline := time.Now().Add(time.Second)
	for {
		manager.mu.RLock()
		closing := manager.closing
		manager.mu.RUnlock()
		if closing {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("manager did not enter shutdown state")
		}
		time.Sleep(time.Millisecond)
	}

	select {
	case <-shutdownDone:
		t.Fatal("shutdown returned before pending creation completed")
	default:
	}
	select {
	case <-secondShutdownDone:
		t.Fatal("concurrent shutdown returned before pending creation completed")
	default:
	}

	manager.releaseSessionSlot()
	manager.createWG.Done()
	select {
	case <-shutdownDone:
	case <-time.After(time.Second):
		t.Fatal("shutdown did not finish after pending creation completed")
	}
	select {
	case <-secondShutdownDone:
	case <-time.After(time.Second):
		t.Fatal("concurrent shutdown did not wait for shutdown completion")
	}

	manager.Shutdown()
	if err := manager.reserveSessionSlot(); err == nil || !strings.Contains(err.Error(), "shutting down") {
		t.Fatalf("reservation after shutdown error = %v, want shutting down", err)
	}
}
