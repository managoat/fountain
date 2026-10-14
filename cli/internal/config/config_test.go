package config

import (
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/managoat/fountain/cli/internal/credentials"
)

// withCredentials points the credentials package at a temp file with the
// given content and clears the env vars that outrank it.
func withCredentials(t *testing.T, content string) {
	t.Helper()
	t.Setenv("FOUNTAIN_API_KEY", "")
	t.Setenv("FOUNTAIN_BASE_URL", "")
	t.Setenv("FOUNTAIN_PROFILE", "")
	path := filepath.Join(t.TempDir(), "credentials")
	if content != "" {
		if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	credentials.SetPathOverride(path)
	t.Cleanup(func() { credentials.SetPathOverride("") })
}

func TestAPIKey(t *testing.T) {
	t.Run("env var outranks the credentials file", func(t *testing.T) {
		withCredentials(t, "[default]\napi_key = \"ftn_from_file\"\n")
		t.Setenv("FOUNTAIN_API_KEY", "ftn_from_env")
		got, err := APIKey(credentials.Opts{})
		if err != nil || got != "ftn_from_env" {
			t.Fatalf("APIKey = %q, %v", got, err)
		}
	})

	t.Run("falls back to the active profile", func(t *testing.T) {
		withCredentials(t, "[default]\napi_key = \"ftn_default\"\n\n[staging]\napi_key = \"ftn_staging\"\n")
		got, err := APIKey(credentials.Opts{})
		if err != nil || got != "ftn_default" {
			t.Fatalf("APIKey = %q, %v", got, err)
		}
		got, err = APIKey(credentials.Opts{Profile: "staging"})
		if err != nil || got != "ftn_staging" {
			t.Fatalf("APIKey(staging) = %q, %v", got, err)
		}
	})

	t.Run("FOUNTAIN_PROFILE selects the profile", func(t *testing.T) {
		withCredentials(t, "[default]\napi_key = \"ftn_default\"\n\n[staging]\napi_key = \"ftn_staging\"\n")
		t.Setenv("FOUNTAIN_PROFILE", "staging")
		got, err := APIKey(credentials.Opts{})
		if err != nil || got != "ftn_staging" {
			t.Fatalf("APIKey = %q, %v", got, err)
		}
	})

	t.Run("ErrNoAPIKey when nothing is configured", func(t *testing.T) {
		withCredentials(t, "")
		_, err := APIKey(credentials.Opts{})
		if !errors.Is(err, ErrNoAPIKey) {
			t.Fatalf("err = %v, want ErrNoAPIKey", err)
		}
	})

	t.Run("ErrNoAPIKey when the profile exists without an api_key", func(t *testing.T) {
		withCredentials(t, "[default]\nbase_url = \"https://x\"\n")
		_, err := APIKey(credentials.Opts{})
		if !errors.Is(err, ErrNoAPIKey) {
			t.Fatalf("err = %v, want ErrNoAPIKey", err)
		}
	})
}

func TestBaseURL(t *testing.T) {
	t.Run("env var wins and loses its trailing slash", func(t *testing.T) {
		withCredentials(t, "[default]\nbase_url = \"https://file.example\"\n")
		t.Setenv("FOUNTAIN_BASE_URL", "https://env.example/")
		if got := BaseURL(credentials.Opts{}); got != "https://env.example" {
			t.Fatalf("BaseURL = %q", got)
		}
	})

	t.Run("profile base_url is next", func(t *testing.T) {
		withCredentials(t, "[default]\nbase_url = \"https://file.example/\"\n")
		if got := BaseURL(credentials.Opts{}); got != "https://file.example" {
			t.Fatalf("BaseURL = %q", got)
		}
	})

	t.Run("compile-time default is last", func(t *testing.T) {
		withCredentials(t, "")
		if got := BaseURL(credentials.Opts{}); got != DefaultBaseURL {
			t.Fatalf("BaseURL = %q, want %q", got, DefaultBaseURL)
		}
	})
}
