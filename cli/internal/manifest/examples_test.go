package manifest

import (
	"os"
	"path/filepath"
	"testing"
)

// TestExamplesParse walks the repo's examples/ tree and asserts every YAML
// document in it is a well-formed resource: a known kind, a metadata.name,
// and a map spec. Read() silently drops docs missing apiVersion/kind, which
// is right for a user's mixed specs tree and wrong for our own examples —
// so this walks the files directly and checks every document.
func TestExamplesParse(t *testing.T) {
	root := filepath.Join("..", "..", "..", "examples")
	if _, err := os.Stat(root); err != nil {
		t.Fatalf("examples/ not found relative to cli/internal/manifest: %v", err)
	}

	files, err := listYAMLFiles(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(files) == 0 {
		t.Fatal("no .yml/.yaml files under examples/")
	}

	knownKinds := map[string]bool{
		"Environment": true,
		"Vault":       true,
		"Agent":       true,
		"Teammate":    true,
		"Schedule":    true,
	}
	total := 0
	checked := 0
	for _, f := range files {
		if notOurs[filepath.ToSlash(f)] {
			continue
		}
		checked++
		docs, err := readFile(f)
		if err != nil {
			t.Errorf("%s: %v", f, err)
			continue
		}
		if len(docs) == 0 {
			t.Errorf("%s: no documents", f)
		}
		for i, d := range docs {
			total++
			if !d.IsResource() {
				t.Errorf("%s doc %d: missing apiVersion or kind (would be silently skipped by apply)", f, i)
				continue
			}
			if !knownKinds[d.Kind] {
				t.Errorf("%s doc %d: unknown kind %q", f, i, d.Kind)
			}
			if d.Name() == "" {
				t.Errorf("%s doc %d (%s): missing metadata.name", f, i, d.Kind)
			}
			if d.Spec == nil {
				t.Errorf("%s doc %d (%s/%s): missing map spec", f, i, d.Kind, d.Name())
			}
			// Secrets, when present, must be the map form: the server keeps a
			// map and silently drops anything else, and the CLI's ${VAR} and
			// secret-manager resolution only walk the map form.
			if raw, ok := d.Spec["secrets"]; ok {
				if _, isMap := raw.(map[string]any); !isMap {
					t.Errorf("%s doc %d (%s/%s): spec.secrets must be a map of KEY: value", f, i, d.Kind, d.Name())
				}
			}
		}
	}
	if total == 0 {
		t.Fatal("no resource documents under examples/")
	}
	// A skip-list entry naming a file that is no longer there is the same hazard
	// in miniature: it reads as "checked and excused" when nothing was excused,
	// and it is how the list grows to cover files that do not exist while a real
	// manifest quietly goes unchecked. The list may only name files the walk
	// actually found.
	if matched := len(files) - checked; matched < len(notOurs) {
		t.Errorf("the skip list names %d files but only %d of them are under examples/; delete the %d stale entr%s", len(notOurs), matched, len(notOurs)-matched, map[bool]string{true: "y", false: "ies"}[len(notOurs)-matched == 1])
	}
}

// notOurs are files under examples/ that are YAML but are not Fountain
// manifests, so `fountain apply` never reads them and the assertions above do
// not apply. They are third-party configuration that an example needs in order
// to be runnable at all.
//
// An explicit list rather than a filename convention (`*fountain.yml`), and
// deliberately so: a convention would silently stop checking a real manifest
// somebody named differently, which is the same shape of hole as the one that
// hid this test's failure for a day (#1542). Anything new under examples/ is
// checked until a person adds it here with a reason.
// Empty since ADR 0057 (#2252): its only two entries were the LiteLLM
// example's own proxy config and compose file (#1479), and that example went
// with the OpenAI-compatible API it demonstrated. The check below that fails
// on a stale entry is what caught them, which is the behaviour this list is
// documented to have.
var notOurs = map[string]bool{}
