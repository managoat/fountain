package cmd

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"github.com/spf13/cobra"
)

// Generates docs/cli/commands.md from the real Cobra tree and fails when the
// checked-in copy is stale. `go test ./internal/cmd/ -update-cli-docs` rewrites
// it.
//
// WHY A SECOND CLI PAGE. docs/cli.md is hand-written and organised by what a
// person is trying to do, and it stays that way. What it does not carry is
// every flag: it shows the useful invocations, and `--help` was the only place
// with the full list. That gap is what this file closes.
//
// The split is Fly.io's (fly.io/docs/flyctl/ is a task-grouped index over
// generated per-command pages): human organisation in one file, machine truth
// in the other, and neither pretending to be the other. The parity tests in
// docs_test.go already read both, because readCLIDoc globs docs/cli/*.md.
var updateCLIDocs = flag.Bool("update-cli-docs", false, "rewrite docs/cli/commands.md from the command tree")

const cliDocsPath = "../../../docs/cli/commands.md"

func TestGeneratedCLIReferenceIsCurrent(t *testing.T) {
	want := renderCLIReference()

	if *updateCLIDocs {
		if err := os.MkdirAll(filepath.Dir(cliDocsPath), 0o755); err != nil {
			t.Fatalf("creating docs/cli: %v", err)
		}
		if err := os.WriteFile(cliDocsPath, []byte(want), 0o644); err != nil {
			t.Fatalf("writing %s: %v", cliDocsPath, err)
		}
		t.Log("rewrote docs/cli/commands.md")
		return
	}

	got, err := os.ReadFile(cliDocsPath)
	if err != nil {
		t.Fatalf("%s is missing (%v). Run: go test ./internal/cmd/ -update-cli-docs", cliDocsPath, err)
	}

	if string(got) != want {
		t.Errorf(`docs/cli/commands.md is stale.

It is generated from the Cobra tree, so a command or flag changed without it.
Regenerate with:

    cd cli && go test ./internal/cmd/ -update-cli-docs

Do not hand-edit it. Prose about a command belongs in docs/cli.md.`)
	}
}

func renderCLIReference() string {
	var b strings.Builder

	b.WriteString(`# All commands

<!-- GENERATED FILE. Do not edit.

     Rendered from the Cobra command tree by
     cli/internal/cmd/docsgen_test.go. Regenerate with:

         cd cli && go test ./internal/cmd/ -update-cli-docs

     Prose about what a command is for, and which one to reach for, belongs in
     the hand-written index at docs/cli.md. This file is the flag-complete
     description and nothing else. -->

Every command and every flag, generated from the binary. For what to reach for
and why, start at the [CLI guide](../cli.md).

`)

	var leaves [][]string
	walkCommands(rootCmd, nil, func(path []string) {
		leaves = append(leaves, append([]string{}, path...))
	})
	sort.Slice(leaves, func(i, j int) bool {
		return strings.Join(leaves[i], " ") < strings.Join(leaves[j], " ")
	})

	for _, path := range leaves {
		cmd := findCommand(rootCmd, path)
		if cmd == nil {
			continue
		}
		full := "fountain " + strings.Join(path, " ")

		fmt.Fprintf(&b, "## `%s`\n\n", full)

		if s := strings.TrimSpace(cmd.Short); s != "" {
			fmt.Fprintf(&b, "%s\n\n", s)
		}
		if l := strings.TrimSpace(cmd.Long); l != "" && l != strings.TrimSpace(cmd.Short) {
			fmt.Fprintf(&b, "%s\n\n", l)
		}

		// UseLine() already carries the full path ("fountain conv show <id>"),
		// so it is used as-is. Rewriting it to prepend the root name produced
		// "fountain fountain acp", which TestNoDocumentedCommandIsInvented
		// caught immediately: the parity tests read this file too.
		fmt.Fprintf(&b, "```\n%s\n```\n\n", strings.TrimSpace(cmd.UseLine()))

		if f := strings.TrimRight(cmd.NonInheritedFlags().FlagUsages(), "\n"); f != "" {
			fmt.Fprintf(&b, "Options:\n\n```\n%s\n```\n\n", f)
		}
	}

	inherited := strings.TrimRight(rootCmd.PersistentFlags().FlagUsages(), "\n")
	if inherited != "" {
		fmt.Fprintf(&b, "## Global flags\n\nAccepted by every command.\n\n```\n%s\n```\n", inherited)
	}

	return b.String()
}

func findCommand(c *cobra.Command, path []string) *cobra.Command {
	cur := c
	for _, name := range path {
		var next *cobra.Command
		for _, sub := range cur.Commands() {
			if sub.Name() == name {
				next = sub
				break
			}
		}
		if next == nil {
			return nil
		}
		cur = next
	}
	return cur
}
