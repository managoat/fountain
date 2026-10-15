package cmd

import (
	"os"
	"strings"
	"time"

	"github.com/spf13/pflag"
)

// Helpers that turn the flags of a create or update command into a JSON body.
// Each one writes its field only when the flag was set on the command line, so
// a PATCH carries the fields the person named and the server keeps the rest.

// setString copies a string flag into body[key]. With nullable, an empty value
// sends null, which is how an update clears an optional field.
func setString(f *pflag.FlagSet, body map[string]any, flag, key string, nullable bool) {
	if f.Lookup(flag) == nil || !f.Changed(flag) {
		return
	}
	v, _ := f.GetString(flag)
	if v == "" && nullable {
		body[key] = nil
		return
	}
	body[key] = v
}

// setTextOrFile reads body[key] from --<flag> or from the file named by
// --<flag>-file. Naming both is an error.
func setTextOrFile(f *pflag.FlagSet, body map[string]any, flag, key string) {
	fileFlag := flag + "-file"
	if f.Changed(flag) && f.Changed(fileFlag) {
		Fatalf("pass --%s or --%s, not both", flag, fileFlag)
	}
	setString(f, body, flag, key, false)
	if f.Changed(fileFlag) {
		path, _ := f.GetString(fileFlag)
		b, err := os.ReadFile(path)
		if err != nil {
			Fatal(err.Error())
		}
		body[key] = string(b)
	}
}

// parseKeyValues turns repeated KEY=VALUE flags into a map.
func parseKeyValues(flag string, pairs []string) map[string]string {
	out := make(map[string]string, len(pairs))
	for _, kv := range pairs {
		eq := strings.IndexByte(kv, '=')
		if eq <= 0 {
			Fatalf("--%s must be KEY=VALUE, got: %q", flag, kv)
		}
		out[kv[:eq]] = kv[eq+1:]
	}
	return out
}

// parseExpiry accepts an RFC 3339 timestamp or a bare date (midnight UTC) and
// returns the RFC 3339 form the API takes.
func parseExpiry(s string) (string, error) {
	if t, err := time.Parse(time.RFC3339, s); err == nil {
		return t.UTC().Format(time.RFC3339), nil
	}
	t, err := time.Parse(time.DateOnly, s)
	if err != nil {
		return "", err
	}
	return t.UTC().Format(time.RFC3339), nil
}
