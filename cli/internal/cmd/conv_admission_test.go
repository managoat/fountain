package cmd

import (
	"encoding/json"
	"errors"
	"os"
	"strings"
	"testing"
	"time"
)

// A queued prompt can be refused through sandbox/done without reclaiming the
// sandbox. Stop following with an error and tell the user to resend the prompt.
func TestAdmissionRefusalStopsStreamWithRetryHint(t *testing.T) {
	for _, tc := range []struct {
		event  string
		reason string
	}{
		{"admission_refused", "sandbox_unavailable"},
		{"at_capacity", "sandbox_at_capacity"},
	} {
		for _, encoding := range []string{"json string", "nested map"} {
			t.Run(tc.event+"/"+encoding, func(t *testing.T) {
				meta := map[string]any{"event": tc.event, "reason": tc.reason}
				var data any = meta
				if encoding == "json string" {
					encoded, err := json.Marshal(meta)
					if err != nil {
						t.Fatal(err)
					}
					data = string(encoded)
				}
				payload, err := json.Marshal(map[string]any{
					"stage": "sandbox", "state": "done", "data": data,
				})
				if err != nil {
					t.Fatal(err)
				}
				f := &fakeStream{bodies: []string{
					"id: 1\nevent: stage\ndata: " + string(payload) + "\n\n" + stage(2, "turn", "done"),
				}}

				stderr, err := os.CreateTemp(t.TempDir(), "stderr")
				if err != nil {
					t.Fatal(err)
				}
				defer stderr.Close()
				original := os.Stderr
				os.Stderr = stderr
				t.Cleanup(func() { os.Stderr = original })

				err = followStream(f.open, time.Second, "conv-1", "")
				if !errors.Is(err, errPromptNotStarted) {
					t.Fatalf("expected refused admission to fail the command, got %v", err)
				}
				if f.opens() != 1 {
					t.Errorf("reconnected after refused admission: opened %d streams", f.opens())
				}
				output, err := os.ReadFile(stderr.Name())
				if err != nil {
					t.Fatal(err)
				}
				for _, want := range []string{"prompt was not started", tc.reason, "send it again shortly"} {
					if !strings.Contains(string(output), want) {
						t.Errorf("stderr = %q, want %q", output, want)
					}
				}
				if strings.Contains(string(output), "reclaimed") || strings.Contains(string(output), "turn done") {
					t.Errorf("refused admission reported a running or completed turn: %s", output)
				}
			})
		}
	}
}
