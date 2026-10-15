package credentials

import (
	"os"
	"path/filepath"
	"testing"
)

// ADR 0082 moved the file from ~/.fountain to ~/.managoat.
func TestLegacyFileIsReadUntilTheNewOneExists(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	old := filepath.Join(home, ".fountain", "credentials")
	if err := os.MkdirAll(filepath.Dir(old), 0o700); err != nil {
		t.Fatal(err)
	}
	body := "[default]\napi_key = \"ftn_old\"\n\n[staging]\napi_key = \"ftn_stg\"\n"
	if err := os.WriteFile(old, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}

	def, err := ReadProfile("default")
	if err != nil || def["api_key"] != "ftn_old" {
		t.Fatalf("ReadProfile(default) = %v, %v; want the old file's key", def, err)
	}

	// The first write lands in the new file and carries the old profiles.
	if err := WriteProfile("default", map[string]string{"api_key": "ftn_new"}); err != nil {
		t.Fatal(err)
	}
	if want := filepath.Join(home, ".managoat", "credentials"); Path() != want {
		t.Fatalf("Path() = %s, want %s", Path(), want)
	}
	if _, err := os.Stat(Path()); err != nil {
		t.Fatalf("the write did not create the new file: %v", err)
	}
	stg, _ := ReadProfile("staging")
	if stg["api_key"] != "ftn_stg" {
		t.Errorf("staging after the move = %v, want the old file's profile", stg)
	}
	def, _ = ReadProfile("default")
	if def["api_key"] != "ftn_new" {
		t.Errorf("default after the write = %v", def)
	}
	if _, err := os.Stat(old); err != nil {
		t.Errorf("the old file should be left alone, but: %v", err)
	}
}

func TestNewFileWinsOverTheLegacyOne(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	for dir, key := range map[string]string{".fountain": "ftn_old", ".managoat": "ftn_new"} {
		p := filepath.Join(home, dir, "credentials")
		if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte("[default]\napi_key = \""+key+"\"\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}

	def, _ := ReadProfile("default")
	if def["api_key"] != "ftn_new" {
		t.Errorf("ReadProfile(default) = %v, want the new file's key", def)
	}
}
