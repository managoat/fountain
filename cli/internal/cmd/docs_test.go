package cmd

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"github.com/spf13/cobra"
)

// docs/cli.md described a kubectl-style CLI that never existed: `get`,
// `describe`, a top-level `delete`, `-o json|yaml|table`, `auth status`,
// `auth login --endpoint`, and a credentials file in the wrong format. None of
// it was caught, because nothing compared the page to the binary.
//
// This walks the real command tree and fails if a command is undocumented, so
// the page cannot drift again without someone noticing.
func TestEveryCommandIsDocumented(t *testing.T) {
	doc := readCLIDoc(t)

	var missing []string
	walkCommands(rootCmd, nil, func(path []string) {
		full := "fountain " + strings.Join(path, " ")
		if !strings.Contains(doc, full) {
			missing = append(missing, full)
		}
	})

	if len(missing) > 0 {
		t.Errorf("docs/cli.md does not mention:\n  %s", strings.Join(missing, "\n  "))
	}
}

// The reverse direction: a documented command that does not exist is worse than
// an undocumented one, because someone will type it.
func TestNoDocumentedCommandIsInvented(t *testing.T) {
	doc := readCLIDoc(t)

	real := map[string]bool{}
	walkCommands(rootCmd, nil, func(path []string) {
		real["fountain "+strings.Join(path, " ")] = true
	})
	// Group commands are legitimate to mention on their own.
	for _, g := range []string{"agent", "auth", "conv", "env", "keys", "vault", "webhooks"} {
		real["fountain "+g] = true
	}

	seen := map[string]bool{}
	inFence := false

	for _, line := range strings.Split(doc, "\n") {
		trimmed := strings.TrimSpace(line)

		// Only example commands count. Prose mentions `fountain <command>` and
		// markdown links contain punctuation that is not part of any command.
		if strings.HasPrefix(trimmed, "```") {
			inFence = !inFence
			continue
		}
		if !inFence {
			continue
		}

		idx := strings.Index(trimmed, "fountain ")
		if idx == -1 || strings.HasPrefix(trimmed, "#") {
			continue
		}
		fields := strings.Fields(trimmed[idx:])
		if len(fields) < 2 {
			continue
		}

		// Longest match first: `fountain vault set-secret` before
		// `fountain vault`.
		var candidates []string
		if len(fields) >= 4 && isCommandWord(fields[2]) && isCommandWord(fields[3]) {
			candidates = append(candidates, strings.Join(fields[:4], " "))
		}
		if len(fields) >= 3 && isCommandWord(fields[2]) {
			candidates = append(candidates, strings.Join(fields[:3], " "))
		}
		candidates = append(candidates, strings.Join(fields[:2], " "))

		matched := false
		for _, c := range candidates {
			if real[c] {
				matched = true
				break
			}
		}
		if !matched && !seen[candidates[len(candidates)-1]] {
			seen[candidates[len(candidates)-1]] = true
			t.Errorf("docs/cli.md documents a command that does not exist: %q (line: %s)",
				candidates[len(candidates)-1], trimmed)
		}
	}
}

// isCommandWord filters out placeholders and flags so `fountain conv show <id>`
// does not look like a three-word command.
func isCommandWord(s string) bool {
	if s == "" || strings.HasPrefix(s, "-") || strings.HasPrefix(s, "<") || strings.HasPrefix(s, "[") {
		return false
	}
	for _, r := range s {
		if !(r == '-' || (r >= 'a' && r <= 'z')) {
			return false
		}
	}
	return true
}

func walkCommands(c *cobra.Command, path []string, fn func([]string)) {
	for _, sub := range c.Commands() {
		if sub.Name() == "help" || sub.Name() == "completion" || sub.Hidden {
			continue
		}
		next := append(append([]string{}, path...), sub.Name())
		if len(sub.Commands()) == 0 {
			fn(next)
		} else {
			walkCommands(sub, next, fn)
		}
	}
}

// The CLI reference is docs/cli.md today. It is allowed to become a directory
// of per-command pages without this test having to change again: both
// docs/cli.md and every .md under docs/cli/ are concatenated, so a split moves
// prose between files the scanners already read.
//
// The old version hardcoded docs/cli.md and nothing else, which made the page
// unsplittable — the reference could not be reorganised without the parity
// tests going red for a reason unrelated to the CLI.
func readCLIDoc(t *testing.T) string {
	t.Helper()
	// cli/internal/cmd -> repo root
	root := filepath.Join("..", "..", "..", "docs")

	var parts []string
	if b, err := os.ReadFile(filepath.Join(root, "cli.md")); err == nil {
		parts = append(parts, string(b))
	}

	matches, err := filepath.Glob(filepath.Join(root, "cli", "*.md"))
	if err != nil {
		t.Fatalf("globbing docs/cli/: %v", err)
	}
	sort.Strings(matches)
	for _, m := range matches {
		b, err := os.ReadFile(m)
		if err != nil {
			t.Fatalf("reading %s: %v", m, err)
		}
		parts = append(parts, string(b))
	}

	if len(parts) == 0 {
		t.Skip("no CLI reference found at docs/cli.md or docs/cli/*.md; skipping")
	}
	return strings.Join(parts, "\n")
}
