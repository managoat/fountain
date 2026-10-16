package cmd

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"sync"
	"testing"

	"github.com/spf13/cobra"
)

// The agent, environment and vault write commands, run against a stand-in
// server that records each request. The bodies are checked against the
// request shapes in apps/fountain/lib/fountain_web/schemas.ex.

type recordedRequest struct {
	Method string
	Path   string
	Body   map[string]any
}

const (
	agentUUID = "0198c9a2-1111-7222-8333-444455556666"
	envUUID   = "0198c9a2-2222-7222-8333-444455556666"
	vaultUUID = "0198c9a2-3333-7222-8333-444455556666"
)

// fakeAPI answers the list endpoints with one named record each, echoes a
// record for writes, and returns 204 for deletes.
func fakeAPI(t *testing.T) *[]recordedRequest {
	t.Helper()
	var mu sync.Mutex
	var reqs []recordedRequest
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		var body map[string]any
		if len(raw) > 0 {
			if err := json.Unmarshal(raw, &body); err != nil {
				t.Errorf("request body is not a JSON object: %s", raw)
			}
		}
		mu.Lock()
		reqs = append(reqs, recordedRequest{r.Method, r.URL.Path, body})
		mu.Unlock()

		w.Header().Set("Content-Type", "application/json")
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/api/agents":
			_, _ = w.Write([]byte(`{"data":[{"id":"` + agentUUID + `","name":"ada"}]}`))
		case r.Method == http.MethodGet && r.URL.Path == "/api/environments":
			_, _ = w.Write([]byte(`{"data":[{"id":"` + envUUID + `","name":"base"}]}`))
		case r.Method == http.MethodGet && r.URL.Path == "/api/vaults":
			_, _ = w.Write([]byte(`{"data":[{"id":"` + vaultUUID + `","name":"creds"}]}`))
		case r.Method == http.MethodDelete:
			w.WriteHeader(http.StatusNoContent)
		default:
			_, _ = w.Write([]byte(`{"data":{"id":"x","name":"x"}}`))
		}
	}))
	t.Cleanup(srv.Close)
	t.Setenv("MANAGOAT_BASE_URL", srv.URL)
	t.Setenv("MANAGOAT_API_KEY", "test-token")
	silenceStdout(t)
	return &reqs
}

func silenceStdout(t *testing.T) {
	t.Helper()
	f, err := os.CreateTemp(t.TempDir(), "stdout")
	if err != nil {
		t.Fatal(err)
	}
	original := os.Stdout
	os.Stdout = f
	t.Cleanup(func() {
		os.Stdout = original
		f.Close()
	})
}

// testCmd builds a throwaway command carrying the given flags, parsed from args.
func testCmd(t *testing.T, addFlags func(*cobra.Command), args ...string) *cobra.Command {
	t.Helper()
	c := &cobra.Command{Use: "test"}
	addFlags(c)
	if err := c.ParseFlags(args); err != nil {
		t.Fatal(err)
	}
	return c
}

// lastWrite returns the one non-GET request; name lookups are GETs.
func lastWrite(t *testing.T, reqs []recordedRequest) recordedRequest {
	t.Helper()
	var writes []recordedRequest
	for _, r := range reqs {
		if r.Method != http.MethodGet {
			writes = append(writes, r)
		}
	}
	if len(writes) != 1 {
		t.Fatalf("want exactly one write, got %+v", reqs)
	}
	return writes[0]
}

func assertRequest(t *testing.T, got recordedRequest, method, path string, body map[string]any) {
	t.Helper()
	if got.Method != method || got.Path != path {
		t.Errorf("request = %s %s, want %s %s", got.Method, got.Path, method, path)
	}
	if !reflect.DeepEqual(got.Body, body) {
		t.Errorf("body = %#v, want %#v", got.Body, body)
	}
}

func TestAgentCreatePostsFlagsAndResolvesEnvironment(t *testing.T) {
	reqs := fakeAPI(t)
	cmd := testCmd(t, addAgentFlags,
		"--runtime", "claude", "--model", "anthropic/claude-sonnet-4-5", "--environment", "base")

	if err := agentCreate(cmd, "ada"); err != nil {
		t.Fatal(err)
	}
	assertRequest(t, lastWrite(t, *reqs), "POST", "/api/agents", map[string]any{
		"name":           "ada",
		"runtime":        "claude",
		"model":          "anthropic/claude-sonnet-4-5",
		"environment_id": envUUID,
	})
}

func TestAgentUpdateSendsOnlyNamedFieldsAndClearsWithEmpty(t *testing.T) {
	reqs := fakeAPI(t)
	dir := t.TempDir()
	system := filepath.Join(dir, "system.md")
	if err := os.WriteFile(system, []byte("Be terse.\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	cmd := testCmd(t, func(c *cobra.Command) {
		c.Flags().String("name", "", "")
		addAgentFlags(c)
	}, "--environment", "", "--system-file", system, "--name", "ada2")

	if err := agentUpdate(cmd, "ada"); err != nil {
		t.Fatal(err)
	}
	assertRequest(t, lastWrite(t, *reqs), "PATCH", "/api/agents/"+agentUUID, map[string]any{
		"name":           "ada2",
		"environment_id": nil,
		"system":         "Be terse.\n",
	})
}

func TestAgentDeleteResolvesName(t *testing.T) {
	reqs := fakeAPI(t)
	if err := agentDelete("ada"); err != nil {
		t.Fatal(err)
	}
	assertRequest(t, lastWrite(t, *reqs), "DELETE", "/api/agents/"+agentUUID, nil)
}

func TestEnvCreatePostsFlags(t *testing.T) {
	reqs := fakeAPI(t)
	cmd := testCmd(t, addEnvFlags,
		"--setup-script", "apt-get install -y jq", "--setup-timeout", "300",
		"--env-var", "LOG_LEVEL=debug", "--env-var", "EMPTY=",
		"--networking", "limited", "--allow-host", "github.com", "--allow-host", "pypi.org")

	if err := envCreate(cmd, "base"); err != nil {
		t.Fatal(err)
	}
	assertRequest(t, lastWrite(t, *reqs), "POST", "/api/environments", map[string]any{
		"name":                  "base",
		"setup_script":          "apt-get install -y jq",
		"setup_timeout_seconds": float64(300),
		"env_vars":              map[string]any{"LOG_LEVEL": "debug", "EMPTY": ""},
		"networking_type":       "limited",
		"networking_config":     map[string]any{"allowed_hosts": []any{"github.com", "pypi.org"}},
	})
}

func TestEnvUpdatePatchesByName(t *testing.T) {
	reqs := fakeAPI(t)
	cmd := testCmd(t, func(c *cobra.Command) {
		c.Flags().String("name", "", "")
		addEnvFlags(c)
	}, "--networking", "unrestricted")

	if err := envUpdate(cmd, "base"); err != nil {
		t.Fatal(err)
	}
	assertRequest(t, lastWrite(t, *reqs), "PATCH", "/api/environments/"+envUUID,
		map[string]any{"networking_type": "unrestricted"})
}

func TestEnvBuildOptInAndExplicitDisable(t *testing.T) {
	reqs := fakeAPI(t)
	cmd := testCmd(t, addEnvFlags, "--cache-enabled", "--build-script", "mix compile")
	if err := envUpdate(cmd, "base"); err != nil {
		t.Fatal(err)
	}
	assertRequest(t, lastWrite(t, *reqs), "PATCH", "/api/environments/"+envUUID,
		map[string]any{"cache_enabled": true, "build_script": "mix compile"})
	*reqs = nil
	cmd = testCmd(t, addEnvFlags, "--cache-enabled=false")
	if err := envUpdate(cmd, "base"); err != nil {
		t.Fatal(err)
	}
	assertRequest(t, lastWrite(t, *reqs), "PATCH", "/api/environments/"+envUUID,
		map[string]any{"cache_enabled": false})
}

func TestEnvDeleteAndSecrets(t *testing.T) {
	for _, tt := range []struct {
		name   string
		run    func() error
		method string
		path   string
		body   map[string]any
	}{
		{"delete", func() error { return envDelete("base") }, "DELETE", "/api/environments/" + envUUID, nil},
		{"set-secret", func() error { return envSetSecret("base", "TOKEN", "s3cret") },
			"POST", "/api/environments/" + envUUID + "/secrets", map[string]any{"key": "TOKEN", "value": "s3cret"}},
		{"delete-secret", func() error { return envDeleteSecret("base", "TOKEN") },
			"DELETE", "/api/environments/" + envUUID + "/secrets/TOKEN", nil},
	} {
		t.Run(tt.name, func(t *testing.T) {
			reqs := fakeAPI(t)
			if err := tt.run(); err != nil {
				t.Fatal(err)
			}
			assertRequest(t, lastWrite(t, *reqs), tt.method, tt.path, tt.body)
		})
	}
}

func vaultSetSecretFlags(c *cobra.Command) {
	c.Flags().String("expires-at", "", "")
}

func vaultSetExpiryFlags(c *cobra.Command) {
	c.Flags().Bool("clear", false, "")
}

func TestVaultSetSecretWithoutExpiryLeavesItOut(t *testing.T) {
	reqs := fakeAPI(t)
	if err := vaultSetSecret(testCmd(t, vaultSetSecretFlags), "creds", "TOKEN", "v"); err != nil {
		t.Fatal(err)
	}
	assertRequest(t, lastWrite(t, *reqs), "POST", "/api/vaults/"+vaultUUID+"/secrets",
		map[string]any{"key": "TOKEN", "value": "v"})
}

func TestVaultSetSecretWithExpiry(t *testing.T) {
	reqs := fakeAPI(t)
	cmd := testCmd(t, vaultSetSecretFlags, "--expires-at", "2027-01-15")
	if err := vaultSetSecret(cmd, "creds", "TOKEN", "v"); err != nil {
		t.Fatal(err)
	}
	assertRequest(t, lastWrite(t, *reqs), "POST", "/api/vaults/"+vaultUUID+"/secrets",
		map[string]any{"key": "TOKEN", "value": "v", "expires_at": "2027-01-15T00:00:00Z"})
}

func TestVaultSetExpiryPatchesOnlyTheExpiry(t *testing.T) {
	reqs := fakeAPI(t)
	cmd := testCmd(t, vaultSetExpiryFlags)
	if err := vaultSetExpiry(cmd, []string{"creds", "TOKEN", "2027-01-15T09:30:00+02:00"}); err != nil {
		t.Fatal(err)
	}
	assertRequest(t, lastWrite(t, *reqs), "PATCH", "/api/vaults/"+vaultUUID+"/secrets/TOKEN",
		map[string]any{"expires_at": "2027-01-15T07:30:00Z"})
}

func TestVaultSetExpiryClearSendsNull(t *testing.T) {
	reqs := fakeAPI(t)
	cmd := testCmd(t, vaultSetExpiryFlags, "--clear")
	if err := vaultSetExpiry(cmd, []string{"creds", "TOKEN"}); err != nil {
		t.Fatal(err)
	}
	assertRequest(t, lastWrite(t, *reqs), "PATCH", "/api/vaults/"+vaultUUID+"/secrets/TOKEN",
		map[string]any{"expires_at": nil})
}

func TestParseExpiry(t *testing.T) {
	for in, want := range map[string]string{
		"2027-01-15":                "2027-01-15T00:00:00Z",
		"2027-01-15T00:00:00Z":      "2027-01-15T00:00:00Z",
		"2027-01-15T01:00:00-05:00": "2027-01-15T06:00:00Z",
	} {
		got, err := parseExpiry(in)
		if err != nil || got != want {
			t.Errorf("parseExpiry(%q) = %q, %v; want %q", in, got, err, want)
		}
	}
	for _, in := range []string{"", "tomorrow", "2027-13-01", "15/01/2027"} {
		if _, err := parseExpiry(in); err == nil {
			t.Errorf("parseExpiry(%q) accepted a malformed time", in)
		}
	}
}
