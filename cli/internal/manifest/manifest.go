// Package manifest reads YAML resource definitions for `managoat apply`.
package manifest

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"
)

// Doc is one parsed resource document.
//
// `Spec` is intentionally a `map[string]any` so callers can keep arbitrary
// fields and roundtrip them to the API as JSON. Only `apiVersion`, `kind`,
// and `metadata.name` are part of the contract here.
type Doc struct {
	APIVersion string         `yaml:"apiVersion"`
	Kind       string         `yaml:"kind"`
	Metadata   map[string]any `yaml:"metadata"`
	Spec       map[string]any `yaml:"spec"`
	// Raw is the full doc as a generic map (preserves anything we don't model).
	Raw map[string]any `yaml:"-"`
}

// Name returns metadata.name or "" if missing.
func (d *Doc) Name() string {
	if d.Metadata == nil {
		return ""
	}
	n, _ := d.Metadata["name"].(string)
	return n
}

// IsResource reports whether the doc carries both apiVersion and kind.
// Files in a specs tree may include unrelated YAML (CI config, etc.); we
// only treat docs with both fields as something to reconcile.
func (d *Doc) IsResource() bool {
	return d.APIVersion != "" && d.Kind != ""
}

// Read parses path. If path is a directory, all *.yml and *.yaml files
// are walked recursively (sorted alphabetically) and concatenated. Docs
// without both apiVersion and kind are silently skipped.
func Read(path string) ([]*Doc, error) {
	info, err := os.Stat(path)
	if err != nil {
		return nil, err
	}
	if info.IsDir() {
		files, err := listYAMLFiles(path)
		if err != nil {
			return nil, err
		}
		if len(files) == 0 {
			return nil, fmt.Errorf("no .yml/.yaml files found under %s", path)
		}
		var all []*Doc
		for _, f := range files {
			docs, err := readFile(f)
			if err != nil {
				return nil, err
			}
			all = append(all, docs...)
		}
		return filterResources(all), nil
	}
	docs, err := readFile(path)
	if err != nil {
		return nil, err
	}
	return filterResources(docs), nil
}

func listYAMLFiles(dir string) ([]string, error) {
	var out []string
	err := filepath.WalkDir(dir, func(p string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			return nil
		}
		ext := strings.ToLower(filepath.Ext(p))
		if ext == ".yml" || ext == ".yaml" {
			out = append(out, p)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	sort.Strings(out)
	return out, nil
}

func readFile(path string) ([]*Doc, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var docs []*Doc
	dec := yaml.NewDecoder(strings.NewReader(string(raw)))
	for {
		var node map[string]any
		if err := dec.Decode(&node); err != nil {
			if err.Error() == "EOF" {
				break
			}
			return nil, fmt.Errorf("yaml parse error in %s: %w", path, err)
		}
		if len(node) == 0 {
			continue
		}
		// Re-encode then decode into Doc to populate the typed fields,
		// while keeping the raw map for downstream serialization.
		buf, err := yaml.Marshal(node)
		if err != nil {
			return nil, err
		}
		var d Doc
		if err := yaml.Unmarshal(buf, &d); err != nil {
			return nil, err
		}
		d.Raw = normalizeMap(node)
		docs = append(docs, &d)
	}
	return docs, nil
}

func filterResources(docs []*Doc) []*Doc {
	out := make([]*Doc, 0, len(docs))
	for _, d := range docs {
		if d.IsResource() {
			out = append(out, d)
		}
	}
	return out
}

// normalizeMap converts yaml's map[interface{}]interface{} subtrees to
// map[string]any, recursively. yaml.v3 already produces map[string]any
// for top-level keys but nested maps under MapSlice or unusual shapes
// can still come back keyed by interface{}; this guard keeps downstream
// JSON encoding safe.
func normalizeMap(in map[string]any) map[string]any {
	out := make(map[string]any, len(in))
	for k, v := range in {
		out[k] = normalize(v)
	}
	return out
}

func normalize(v any) any {
	switch x := v.(type) {
	case map[string]any:
		return normalizeMap(x)
	case map[any]any:
		out := make(map[string]any, len(x))
		for k, val := range x {
			out[fmt.Sprintf("%v", k)] = normalize(val)
		}
		return out
	case []any:
		out := make([]any, len(x))
		for i, item := range x {
			out[i] = normalize(item)
		}
		return out
	default:
		return v
	}
}
