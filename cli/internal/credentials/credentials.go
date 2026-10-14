// Package credentials reads and writes ~/.fountain/credentials as an
// AWS-CLI-style multi-profile TOML file.
//
//	[default]
//	api_key = "ftn_..."
//	base_url = "https://fountain.dev"
//
//	[staging]
//	api_key = "ftn_..."
//	base_url = "https://staging.fountain.dev"
//
// The format is intentionally lenient — values may be unquoted, and
// comment lines (starting with `#`) and blank lines are ignored.
package credentials

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// pathOverride lets tests redirect the credentials file location.
// Production code never sets this.
var pathOverride string

// SetPathOverride redirects the credentials file path. Pass "" to clear.
func SetPathOverride(p string) { pathOverride = p }

// Path returns the resolved credentials file path.
func Path() string {
	if pathOverride != "" {
		return pathOverride
	}
	home, err := os.UserHomeDir()
	if err != nil {
		// No HOME — fall back to relative; the eventual write will fail visibly.
		return ".fountain/credentials"
	}
	return filepath.Join(home, ".fountain", "credentials")
}

// Opts carries the resolved profile flag from the command layer.
type Opts struct {
	Profile string
}

// ProfileName returns the active profile name.
// Precedence: opts.Profile > FOUNTAIN_PROFILE env var > "default".
func ProfileName(opts Opts) string {
	if opts.Profile != "" {
		return opts.Profile
	}
	if env := os.Getenv("FOUNTAIN_PROFILE"); env != "" {
		return env
	}
	return "default"
}

// ReadProfile returns the named profile's attributes.
// Returns an empty map when the file or profile is missing.
func ReadProfile(profile string) (map[string]string, error) {
	content, err := os.ReadFile(Path())
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return map[string]string{}, nil
		}
		return nil, fmt.Errorf("cannot read %s: %w", Path(), err)
	}
	all := ParseAll(string(content))
	if attrs, ok := all[profile]; ok {
		return attrs, nil
	}
	return map[string]string{}, nil
}

// WriteProfile upserts a profile section, preserving other profiles.
func WriteProfile(profile string, attrs map[string]string) error {
	path := Path()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}

	all := map[string]map[string]string{}
	if content, err := os.ReadFile(path); err == nil {
		all = ParseAll(string(content))
	} else if !errors.Is(err, fs.ErrNotExist) {
		return fmt.Errorf("cannot read %s: %w", path, err)
	}

	all[profile] = attrs
	return os.WriteFile(path, []byte(serialize(all)), 0o600)
}

// DeleteProfile removes a profile from the credentials file.
// No-op if the file or profile does not exist.
func DeleteProfile(profile string) error {
	path := Path()
	content, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return nil
		}
		return fmt.Errorf("cannot read %s: %w", path, err)
	}
	all := ParseAll(string(content))
	delete(all, profile)
	return os.WriteFile(path, []byte(serialize(all)), 0o600)
}

var sectionRE = regexp.MustCompile(`^\[([^\]]+)\]$`)

// ParseAll parses the credentials file content into a profile→attrs map.
// Exposed for tests; the parser is lenient (matches the Elixir original).
func ParseAll(content string) map[string]map[string]string {
	out := map[string]map[string]string{}
	var section string
	for _, raw := range strings.Split(content, "\n") {
		line := strings.TrimSpace(raw)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if m := sectionRE.FindStringSubmatch(line); m != nil {
			section = m[1]
			continue
		}
		if section == "" || !strings.Contains(line, "=") {
			continue
		}
		eq := strings.IndexByte(line, '=')
		key := strings.TrimSpace(line[:eq])
		val := stripQuotes(strings.TrimSpace(line[eq+1:]))
		if _, ok := out[section]; !ok {
			out[section] = map[string]string{}
		}
		out[section][key] = val
	}
	return out
}

func stripQuotes(s string) string {
	if len(s) >= 2 && s[0] == '"' && s[len(s)-1] == '"' {
		return s[1 : len(s)-1]
	}
	if len(s) >= 1 && s[0] == '"' {
		return s[1:]
	}
	return s
}

// serialize writes profiles back as the same TOML-ish shape, with
// "default" first and other profiles in sorted order.
func serialize(all map[string]map[string]string) string {
	if len(all) == 0 {
		return ""
	}
	names := make([]string, 0, len(all))
	for n := range all {
		names = append(names, n)
	}
	sort.Slice(names, func(i, j int) bool {
		ki := names[i]
		kj := names[j]
		if ki == "default" {
			ki = ""
		}
		if kj == "default" {
			kj = ""
		}
		return ki < kj
	})

	var sections []string
	for _, name := range names {
		attrs := all[name]
		keys := make([]string, 0, len(attrs))
		for k := range attrs {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		var b strings.Builder
		b.WriteString("[")
		b.WriteString(name)
		b.WriteString("]\n")
		for i, k := range keys {
			if i > 0 {
				b.WriteByte('\n')
			}
			b.WriteString(k)
			b.WriteString(` = "`)
			b.WriteString(attrs[k])
			b.WriteString(`"`)
		}
		sections = append(sections, b.String())
	}
	return strings.Join(sections, "\n\n") + "\n"
}
