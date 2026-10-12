package cmd

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/managoat/fountain/cli/api"
	"github.com/managoat/fountain/cli/internal/manifest"
	"github.com/managoat/fountain/cli/internal/secrets"
)

func doc(kind, name string, spec map[string]any) *manifest.Doc {
	return &manifest.Doc{
		APIVersion: "fountain/v1",
		Kind:       kind,
		Metadata:   map[string]any{"name": name},
		Spec:       spec,
	}
}

func TestBuildApplyPayloadOrdersAndStrips(t *testing.T) {
	grouped := map[string][]*manifest.Doc{
		"Environment": {doc("Environment", "proj", map[string]any{
			"setup_script": "echo hi",
			"secrets":      map[string]any{"TOKEN": "t0"},
			"user_id":      "someone-else",
			"created_by":   "mallory",
			"id":           "forced-id",
		})},
		"Vault": {doc("Vault", "alice", nil)},
		"Agent": {doc("Agent", "researcher", map[string]any{
			"runtime":     "claude",
			"environment": "proj",
		})},
		"Teammate": {doc("Teammate", "Ada", map[string]any{"agent": "researcher"})},
		"Schedule": {doc("Schedule", "standup", map[string]any{"teammate": "Ada", "cron": "@daily"})},
	}

	// Payload order is the reconciliation order, whatever order the manifest
	// listed the documents in.
	got := buildApplyPayload(grouped)

	if len(got) != len(applyKindOrder) {
		t.Fatalf("want %d resources, got %d", len(applyKindOrder), len(got))
	}
	for i, want := range applyKindOrder {
		if got[i].Kind != want {
			t.Fatalf("resource %d: want kind %q, got %q", i, want, got[i].Kind)
		}
	}

	env := got[0]
	if env.Name != "proj" {
		t.Fatalf("want name proj, got %q", env.Name)
	}
	for _, k := range []string{"id", "user_id", "created_by"} {
		if _, ok := env.Spec[k]; ok {
			t.Errorf("ownership field %q must be stripped from spec", k)
		}
	}
	// Secrets stay inline — the server splits them out and encrypts.
	wantSecrets := map[string]any{"TOKEN": "t0"}
	if !reflect.DeepEqual(env.Spec["secrets"], wantSecrets) {
		t.Errorf("want inline secrets %v, got %v", wantSecrets, env.Spec["secrets"])
	}

	// The environment name reference is passed through for server-side resolution.
	if got[2].Spec["environment"] != "proj" {
		t.Errorf("agent environment reference must be preserved, got %v", got[2].Spec["environment"])
	}

	// A nil spec still yields a non-nil map so the JSON encodes as {}.
	if got[1].Spec == nil {
		t.Errorf("nil spec must be sent as an empty object")
	}
}

func TestGroupDocsBucketsEveryKind(t *testing.T) {
	docs := []*manifest.Doc{
		doc("Agent", "a", nil),
		doc("Cluster", "nope", nil),
		doc("Teammate", "Ada", nil),
		doc("Schedule", "standup", nil),
		doc("Environment", "e", nil),
		doc("Vault", "v", nil),
	}

	grouped, unknown := groupDocs(docs)

	for _, kind := range applyKindOrder {
		if len(grouped[kind]) != 1 {
			t.Errorf("%s: want 1 doc, got %d", kind, len(grouped[kind]))
		}
	}
	if len(unknown) != 1 || unknown[0].Kind != "Cluster" {
		t.Errorf("an unsupported kind must come back as unknown, got %v", unknown)
	}
}

func TestRenderApplyResultsFailureDetection(t *testing.T) {
	cases := []struct {
		name    string
		results []applyResult
		want    bool
	}{
		{"all ok", []applyResult{
			{Kind: "Environment", Name: "e", Action: "created"},
			{Kind: "Agent", Name: "a", Action: "updated"},
			{Kind: "Vault", Name: "v", Action: "unchanged"},
		}, false},
		{"resource error", []applyResult{
			{Kind: "Agent", Name: "a", Action: "error", Errors: map[string]any{"model": []any{"can't be blank"}}},
		}, true},
		{"secret error", []applyResult{
			{Kind: "Vault", Name: "v", Action: "created", Secrets: []applySecretResult{
				{Key: "GH", Action: "error"},
			}},
		}, true},
	}
	for _, tc := range cases {
		if got := renderApplyResults(tc.results); got != tc.want {
			t.Errorf("%s: anyFailed = %v, want %v", tc.name, got, tc.want)
		}
	}
}

func TestFormatResultErrors(t *testing.T) {
	got := formatResultErrors(map[string]any{
		"model":   []any{"can't be blank"},
		"runtime": []any{"is invalid"},
	})
	want := "model: [can't be blank]; runtime: [is invalid]"
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
	if formatResultErrors(nil) != "apply failed" {
		t.Errorf("nil errors should fall back to generic message")
	}
}

func TestApplyVarsPreserveLiteralValues(t *testing.T) {
	cmd := newApplyCmd()
	err := cmd.ParseFlags([]string{
		"--var", "PAIRS=a=1,b=2",
		"--var", "HOSTS=web1,web2",
		"--var", `QUOTED="a,b"`,
		"--var", "EMPTY=",
	})
	if err != nil {
		t.Fatal(err)
	}
	flags, err := cmd.Flags().GetStringArray("var")
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("b", "original")
	want := buildApplyVars(nil)
	for key, value := range map[string]string{
		"PAIRS":  "a=1,b=2",
		"HOSTS":  "web1,web2",
		"QUOTED": `"a,b"`,
		"EMPTY":  "",
	} {
		want[key] = value
	}
	if got := buildApplyVars(flags); !reflect.DeepEqual(got, want) {
		t.Fatal("apply variables changed beyond the supplied literal KEY=VALUE pairs")
	}
}

func TestRunApplyMissingEndpointDoesNotReconcileResources(t *testing.T) {
	requests := []string{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests = append(requests, r.Method+" "+r.URL.Path)
		http.NotFound(w, r)
	}))
	defer srv.Close()
	t.Setenv("FOUNTAIN_BASE_URL", srv.URL)
	t.Setenv("FOUNTAIN_API_KEY", "test-token")

	path := filepath.Join(t.TempDir(), "resources.yml")
	if err := os.WriteFile(path, []byte(`apiVersion: fountain/v1
kind: Environment
metadata:
  name: project
spec:
  secrets:
    TOKEN: test-secret
---
apiVersion: fountain/v1
kind: Vault
metadata:
  name: personal
---
apiVersion: fountain/v1
kind: Agent
metadata:
  name: researcher
spec:
  environment: project
`), 0600); err != nil {
		t.Fatal(err)
	}
	err := runApply(newApplyCmd(), []string{path})
	if err == nil {
		t.Fatal("missing bulk endpoint must fail")
	}
	for _, want := range []string{"v0.3.0 or later", "POST /api/apply", "upgrade the server", "FOUNTAIN_BASE_URL"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error %q must include %q", err, want)
		}
	}
	if !reflect.DeepEqual(requests, []string{"POST /api/apply"}) {
		t.Fatalf("must not fall back to individual requests, got %v", requests)
	}
}

type applyTestResolver struct{}

func (applyTestResolver) Prefix() string { return "test-secret://" }
func (applyTestResolver) Read(ref string) (string, error) {
	if ref != "test-secret://project/TOKEN" {
		return "", errors.New("unexpected secret reference")
	}
	return "resolved-token", nil
}
func (applyTestResolver) FormatError(err error) string { return err.Error() }

func TestRunApplyBulkRequestExpandsSecrets(t *testing.T) {
	oldResolvers := secrets.Default
	secrets.Default = []secrets.Resolver{applyTestResolver{}}
	t.Cleanup(func() { secrets.Default = oldResolvers })

	var received []applyResource
	requests := []string{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests = append(requests, r.Method+" "+r.URL.Path)
		var payload struct {
			Resources []applyResource `json:"resources"`
		}
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			t.Error(err)
		}
		received = payload.Resources
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"data":{"results":[
			{"kind":"Environment","name":"project","action":"created","secrets":[{"key":"TOKEN","action":"upserted"}]},
			{"kind":"Vault","name":"personal","action":"unchanged","secrets":[{"key":"REGION","action":"upserted"}]},
			{"kind":"Agent","name":"researcher","action":"updated"}
		]}}`))
	}))
	defer srv.Close()
	t.Setenv("FOUNTAIN_BASE_URL", srv.URL)
	t.Setenv("FOUNTAIN_API_KEY", "test-token")
	t.Setenv("PROJECT", "project")

	path := filepath.Join(t.TempDir(), "resources.yml")
	if err := os.WriteFile(path, []byte(`apiVersion: fountain/v1
kind: Agent
metadata:
  name: researcher
spec:
  environment: project
---
apiVersion: fountain/v1
kind: Environment
metadata:
  name: project
spec:
  secrets:
    TOKEN: test-secret://${PROJECT}/TOKEN
---
apiVersion: fountain/v1
kind: Vault
metadata:
  name: personal
spec:
  secrets:
    REGION: ${REGION}
`), 0600); err != nil {
		t.Fatal(err)
	}
	cmd := newApplyCmd()
	cmd.SetArgs([]string{"-f", path, "--var", "REGION=eu-west-1"})
	if err := cmd.Execute(); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(requests, []string{"POST /api/apply"}) {
		t.Fatalf("want one bulk request, got %v", requests)
	}
	want := []applyResource{
		{Kind: "Environment", Name: "project", Spec: map[string]any{"secrets": map[string]any{"TOKEN": "resolved-token"}}},
		{Kind: "Vault", Name: "personal", Spec: map[string]any{"secrets": map[string]any{"REGION": "eu-west-1"}}},
		{Kind: "Agent", Name: "researcher", Spec: map[string]any{"environment": "project"}},
	}
	if !reflect.DeepEqual(received, want) {
		t.Fatalf("bulk payload = %#v, want %#v", received, want)
	}
}

func TestPostApplyPreservesPerItemFailures(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"data":{"results":[
			{"kind":"Environment","name":"project","action":"created","secrets":[{"key":"TOKEN","action":"error","errors":{"value":["is invalid"]}}]},
			{"kind":"Agent","name":"researcher","action":"error","errors":{"model":["is invalid"]}},
			{"kind":"Vault","name":"personal","action":"unchanged"}
		]}}`))
	}))
	defer srv.Close()
	t.Setenv("FOUNTAIN_BASE_URL", srv.URL)
	t.Setenv("FOUNTAIN_API_KEY", "test-token")

	results, err := postApply(activeClient(), []applyResource{})
	if err != nil {
		t.Fatal(err)
	}
	if len(results) != 3 || len(results[0].Secrets) != 1 {
		t.Fatalf("missing per-item results: %#v", results)
	}
	if formatResultErrors(results[0].Secrets[0].Errors) != "value: [is invalid]" ||
		formatResultErrors(results[1].Errors) != "model: [is invalid]" {
		t.Fatalf("missing per-item errors: %#v", results)
	}
	if !renderApplyResults(results) {
		t.Fatal("HTTP 200 must not hide resource or secret failures")
	}
}

func TestRunApplyPreservesOtherServerErrors(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusForbidden)
		_, _ = w.Write([]byte(`{"error":"forbidden"}`))
	}))
	defer srv.Close()
	t.Setenv("FOUNTAIN_BASE_URL", srv.URL)
	t.Setenv("FOUNTAIN_API_KEY", "test-token")
	path := filepath.Join(t.TempDir(), "resources.yml")
	if err := os.WriteFile(path, []byte("apiVersion: fountain/v1\nkind: Vault\nmetadata:\n  name: personal\n"), 0600); err != nil {
		t.Fatal(err)
	}
	err := runApply(newApplyCmd(), []string{path})
	var httpErr *api.HTTPError
	if !errors.As(err, &httpErr) || httpErr.Status != http.StatusForbidden {
		t.Fatalf("want original forbidden error, got %v", err)
	}
	if strings.Contains(err.Error(), "upgrade") {
		t.Fatalf("permission error must not ask for server upgrade: %v", err)
	}
}
