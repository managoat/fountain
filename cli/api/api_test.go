package api

import (
	"strings"
	"testing"
)

// The server writes actionable messages; the CLI used to print the raw Go
// map ("http 503: map[error:fleet_full message:...]").
func TestHTTPErrorError(t *testing.T) {
	cases := []struct {
		name string
		err  HTTPError
		want string
	}{
		{
			name: "message is preferred over the error slug",
			err: HTTPError{Status: 503, Body: map[string]any{
				"error":   "fleet_full",
				"message": "Every sandbox slot is in use right now. Try again in a minute.",
			}},
			want: "http 503: Every sandbox slot is in use right now. Try again in a minute.",
		},
		{
			name: "error slug when there is no message",
			err:  HTTPError{Status: 410, Body: map[string]any{"error": "conversation_terminated"}},
			want: "http 410: conversation_terminated",
		},
		{
			name: "validation errors are flattened, not map-dumped",
			err: HTTPError{Status: 422, Body: map[string]any{
				"errors": map[string]any{"name": []any{"can't be blank"}},
			}},
			want: "http 422: name: can't be blank",
		},
		{
			name: "nested validation errors keep their path",
			err: HTTPError{Status: 422, Body: map[string]any{
				"errors": map[string]any{
					"secrets": map[string]any{"value": []any{"is required"}},
				},
			}},
			want: "http 422: secrets.value: is required",
		},
		{
			name: "a bare status still renders",
			err:  HTTPError{Status: 500},
			want: "http 500",
		},
		{
			name: "a non-map body falls back to the old rendering",
			err:  HTTPError{Status: 502, Body: "bad gateway"},
			want: "http 502: bad gateway",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := tc.err.Error(); got != tc.want {
				t.Errorf("got %q, want %q", got, tc.want)
			}
		})
	}
}

func TestHTTPErrorUnknownMapFallsBack(t *testing.T) {
	// A map with none of the known keys must not render as just "http 418".
	e := HTTPError{Status: 418, Body: map[string]any{"weird": "shape"}}
	if got := e.Error(); !strings.Contains(got, "weird") {
		t.Errorf("unknown body shape lost information: %q", got)
	}
}
