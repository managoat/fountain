package runner

import (
	"testing"
	"time"
)

func TestBackoffStaysCappedForever(t *testing.T) {
	want := []time.Duration{time.Second, time.Second, 2 * time.Second, 4 * time.Second, 8 * time.Second, 16 * time.Second, 30 * time.Second, 30 * time.Second}
	for attempt, w := range want {
		if got := backoff(attempt); got != w {
			t.Errorf("backoff(%d) = %s, want %s", attempt, got, w)
		}
	}
	for _, attempt := range []int{35, 64, 65, 1000} {
		if got := backoff(attempt); got != 30*time.Second {
			t.Errorf("backoff(%d) = %s, want 30s", attempt, got)
		}
	}
}
