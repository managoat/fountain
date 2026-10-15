// Package env reads the CLI's environment variables.
//
// The variables are MANAGOAT_*. Until ADR 0082 they were FOUNTAIN_*, and
// shells, CI jobs and sandboxes still export the old names, so for a
// deprecation window each one falls back to its FOUNTAIN_* name when the new
// one is unset, with a warning on stderr. A later release stops reading the
// old names (managoat/managoat#2776).
package env

import (
	"fmt"
	"io"
	"os"
	"strings"
	"sync"
)

// Warnings is where the deprecation warning goes. Tests replace it.
var Warnings io.Writer = os.Stderr

var warned sync.Map

// Legacy returns the FOUNTAIN_* name a MANAGOAT_* variable had, or "" for a
// name without the prefix.
func Legacy(name string) string {
	if rest, ok := strings.CutPrefix(name, "MANAGOAT_"); ok {
		return "FOUNTAIN_" + rest
	}
	return ""
}

// Get returns the value of name, a MANAGOAT_* variable, or of its FOUNTAIN_*
// name when name is unset or empty. Reading the old name warns once per
// process.
func Get(name string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	legacy := Legacy(name)
	if legacy == "" {
		return ""
	}
	v := os.Getenv(legacy)
	if v != "" {
		if _, done := warned.LoadOrStore(legacy, true); !done {
			fmt.Fprintf(Warnings, "managoat: %s is deprecated; set %s instead.\n", legacy, name)
		}
	}
	return v
}
