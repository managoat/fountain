package env

import (
	"bytes"
	"strings"
	"testing"
)

func capture(t *testing.T) *bytes.Buffer {
	t.Helper()
	var buf bytes.Buffer
	prev := Warnings
	Warnings = &buf
	warned.Clear()
	t.Cleanup(func() { Warnings = prev; warned.Clear() })
	return &buf
}

func TestNewNameWins(t *testing.T) {
	out := capture(t)
	t.Setenv("MANAGOAT_API_KEY", "new")
	t.Setenv("FOUNTAIN_API_KEY", "old")

	if got := Get("MANAGOAT_API_KEY"); got != "new" {
		t.Fatalf("Get = %q, want new", got)
	}
	if out.Len() != 0 {
		t.Errorf("warned although the new name is set: %q", out.String())
	}
}

func TestOldNameIsReadWithOneWarning(t *testing.T) {
	out := capture(t)
	t.Setenv("MANAGOAT_API_KEY", "")
	t.Setenv("FOUNTAIN_API_KEY", "old")

	for range 3 {
		if got := Get("MANAGOAT_API_KEY"); got != "old" {
			t.Fatalf("Get = %q, want old", got)
		}
	}
	want := "managoat: FOUNTAIN_API_KEY is deprecated; set MANAGOAT_API_KEY instead.\n"
	if out.String() != want {
		t.Errorf("warnings = %q, want one %q", out.String(), want)
	}
}

func TestUnsetIsEmpty(t *testing.T) {
	out := capture(t)
	t.Setenv("MANAGOAT_PROFILE", "")
	t.Setenv("FOUNTAIN_PROFILE", "")

	if got := Get("MANAGOAT_PROFILE"); got != "" {
		t.Fatalf("Get = %q, want empty", got)
	}
	if strings.TrimSpace(out.String()) != "" {
		t.Errorf("warned for an unset variable: %q", out.String())
	}
}

func TestLegacy(t *testing.T) {
	if got := Legacy("MANAGOAT_BASE_URL"); got != "FOUNTAIN_BASE_URL" {
		t.Errorf("Legacy = %q", got)
	}
	if got := Legacy("HOME"); got != "" {
		t.Errorf("Legacy(HOME) = %q, want empty", got)
	}
}
