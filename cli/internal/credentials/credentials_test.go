package credentials

import (
	"os"
	"path/filepath"
	"testing"
)

func setup(t *testing.T) string {
	t.Helper()
	tmp := t.TempDir()
	path := filepath.Join(tmp, "credentials")
	SetPathOverride(path)
	t.Cleanup(func() { SetPathOverride("") })
	return path
}

// ── ParseAll ────────────────────────────────────────────────────────────

func TestParseAll_SingleProfile(t *testing.T) {
	toml := `[default]
api_key = "ftn_abc123"
base_url = "https://fountain.dev"
`
	got := ParseAll(toml)
	if got["default"]["api_key"] != "ftn_abc123" {
		t.Fatalf("api_key: %q", got["default"]["api_key"])
	}
	if got["default"]["base_url"] != "https://fountain.dev" {
		t.Fatalf("base_url: %q", got["default"]["base_url"])
	}
}

func TestParseAll_MultipleProfiles(t *testing.T) {
	toml := `[default]
api_key = "ftn_def456"
base_url = "https://fountain.dev"

[staging]
api_key = "ftn_abc123"
base_url = "https://staging.fountain.dev"
`
	got := ParseAll(toml)
	if got["default"]["api_key"] != "ftn_def456" {
		t.Fatalf("default.api_key")
	}
	if got["staging"]["api_key"] != "ftn_abc123" {
		t.Fatalf("staging.api_key")
	}
	if got["staging"]["base_url"] != "https://staging.fountain.dev" {
		t.Fatalf("staging.base_url")
	}
}

func TestParseAll_Empty(t *testing.T) {
	if got := ParseAll(""); len(got) != 0 {
		t.Fatalf("expected empty, got %v", got)
	}
}

func TestParseAll_IgnoresBlanksAndComments(t *testing.T) {
	toml := `# This is a comment
[default]
# Another comment
api_key = "ftn_abc"
`
	got := ParseAll(toml)
	if got["default"]["api_key"] != "ftn_abc" {
		t.Fatalf("got %v", got)
	}
}

func TestParseAll_UnquotedValue(t *testing.T) {
	toml := `[default]
api_key = ftn_noquotes
`
	got := ParseAll(toml)
	if got["default"]["api_key"] != "ftn_noquotes" {
		t.Fatalf("got %q", got["default"]["api_key"])
	}
}

// ── ReadProfile ─────────────────────────────────────────────────────────

func TestReadProfile_NoFile(t *testing.T) {
	setup(t)
	got, err := ReadProfile("default")
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 0 {
		t.Fatalf("expected empty, got %v", got)
	}
}

func TestReadProfile_MissingProfile(t *testing.T) {
	setup(t)
	if err := WriteProfile("default", map[string]string{"api_key": "ftn_x"}); err != nil {
		t.Fatal(err)
	}
	got, err := ReadProfile("nonexistent")
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 0 {
		t.Fatalf("expected empty, got %v", got)
	}
}

func TestReadProfile_RoundTrip(t *testing.T) {
	setup(t)
	in := map[string]string{"api_key": "ftn_abc", "base_url": "https://fountain.dev"}
	if err := WriteProfile("default", in); err != nil {
		t.Fatal(err)
	}
	got, err := ReadProfile("default")
	if err != nil {
		t.Fatal(err)
	}
	if got["api_key"] != "ftn_abc" || got["base_url"] != "https://fountain.dev" {
		t.Fatalf("got %v", got)
	}
}

// ── WriteProfile ────────────────────────────────────────────────────────

func TestWriteProfile_CreatesParentDirs(t *testing.T) {
	path := setup(t)
	if err := WriteProfile("default", map[string]string{"api_key": "ftn_x"}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("expected file at %s: %v", path, err)
	}
}

func TestWriteProfile_StagingDoesNotAlterDefault(t *testing.T) {
	setup(t)
	_ = WriteProfile("default", map[string]string{"api_key": "ftn_default"})
	_ = WriteProfile("staging", map[string]string{"api_key": "ftn_staging", "base_url": "https://staging.fountain.dev"})

	def, _ := ReadProfile("default")
	if def["api_key"] != "ftn_default" || len(def) != 1 {
		t.Fatalf("default mutated: %v", def)
	}
	stg, _ := ReadProfile("staging")
	if stg["api_key"] != "ftn_staging" || stg["base_url"] != "https://staging.fountain.dev" {
		t.Fatalf("staging: %v", stg)
	}
}

func TestWriteProfile_UpsertDoesNotAlterDefault(t *testing.T) {
	setup(t)
	_ = WriteProfile("default", map[string]string{"api_key": "ftn_default"})
	_ = WriteProfile("staging", map[string]string{"api_key": "ftn_staging_v1"})
	_ = WriteProfile("staging", map[string]string{"api_key": "ftn_staging_v2"})

	def, _ := ReadProfile("default")
	if def["api_key"] != "ftn_default" {
		t.Fatalf("default mutated: %v", def)
	}
	stg, _ := ReadProfile("staging")
	if stg["api_key"] != "ftn_staging_v2" {
		t.Fatalf("staging not upserted: %v", stg)
	}
}

// ── DeleteProfile ───────────────────────────────────────────────────────

func TestDeleteProfile_NoFile(t *testing.T) {
	setup(t)
	if err := DeleteProfile("default"); err != nil {
		t.Fatal(err)
	}
}

func TestDeleteProfile_RemovesNamedSection(t *testing.T) {
	setup(t)
	_ = WriteProfile("default", map[string]string{"api_key": "ftn_default"})
	_ = WriteProfile("staging", map[string]string{"api_key": "ftn_staging"})

	if err := DeleteProfile("staging"); err != nil {
		t.Fatal(err)
	}
	def, _ := ReadProfile("default")
	if def["api_key"] != "ftn_default" {
		t.Fatalf("default mutated: %v", def)
	}
	stg, _ := ReadProfile("staging")
	if len(stg) != 0 {
		t.Fatalf("staging not removed: %v", stg)
	}
}

func TestDeleteProfile_NoOpOnUnknown(t *testing.T) {
	setup(t)
	_ = WriteProfile("default", map[string]string{"api_key": "ftn_default"})
	if err := DeleteProfile("nonexistent"); err != nil {
		t.Fatal(err)
	}
	def, _ := ReadProfile("default")
	if def["api_key"] != "ftn_default" {
		t.Fatalf("default mutated: %v", def)
	}
}

// ── ProfileName ─────────────────────────────────────────────────────────

func TestProfileName_FromOpts(t *testing.T) {
	t.Setenv("FOUNTAIN_PROFILE", "")
	if got := ProfileName(Opts{Profile: "staging"}); got != "staging" {
		t.Fatalf("got %q", got)
	}
}

func TestProfileName_FromEnv(t *testing.T) {
	t.Setenv("FOUNTAIN_PROFILE", "env_profile")
	if got := ProfileName(Opts{}); got != "env_profile" {
		t.Fatalf("got %q", got)
	}
}

func TestProfileName_DefaultFallback(t *testing.T) {
	t.Setenv("FOUNTAIN_PROFILE", "")
	if got := ProfileName(Opts{}); got != "default" {
		t.Fatalf("got %q", got)
	}
}

func TestProfileName_OptsBeatsEnv(t *testing.T) {
	t.Setenv("FOUNTAIN_PROFILE", "env_profile")
	if got := ProfileName(Opts{Profile: "opt_profile"}); got != "opt_profile" {
		t.Fatalf("got %q", got)
	}
}
