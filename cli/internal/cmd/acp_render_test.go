package cmd

import (
	"strings"
	"testing"
)

// #723: since ACP became the only path for the coding-agent runtimes, a
// conversation's output *is* the protocol — and the CLI rendered it as
// stream-json, which produced the empty string for every line. `fountain run`
// printed a turn starting and finishing with nothing in between, and
// `fountain conv stream` printed nothing at all.
func acpEvent(update string) map[string]any {
	return map[string]any{
		"kind":   "output",
		"stream": "acp",
		"stage":  "turn",
		"data":   `{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":` + update + `}}` + "\n",
	}
}

func TestAgentTextIsRendered(t *testing.T) {
	out := formatOutput(acpEvent(`{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hello from the agent"}}`))

	if !strings.Contains(out, "hello from the agent") {
		t.Errorf("agent text missing from %q", out)
	}
}

// The regression in one assertion: the whole reason the command looked broken.
func TestAnACPTurnIsNotSilent(t *testing.T) {
	if got := formatOutput(acpEvent(`{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"x"}}`)); got == "" {
		t.Fatal("an ACP conversation rendered as the empty string")
	}
}

func TestToolCallsAreShown(t *testing.T) {
	out := formatOutput(acpEvent(`{"sessionUpdate":"tool_call","toolCallId":"t1","title":"Edit lib/foo.ex","kind":"edit","status":"pending"}`))

	if !strings.Contains(out, "Edit lib/foo.ex") {
		t.Errorf("tool title missing from %q", out)
	}
}

// A tool call with no title still has to render something a human can read,
// or the turn shows an empty pair of brackets.
func TestAToolCallWithoutATitleFallsBackToItsKind(t *testing.T) {
	out := formatOutput(acpEvent(`{"sessionUpdate":"tool_call","toolCallId":"t1","kind":"execute","status":"pending"}`))

	if !strings.Contains(out, "execute") {
		t.Errorf("want the kind as a fallback, got %q", out)
	}
}

// In-flight updates carry progress, not outcome. A line per `in_progress`
// would bury the agent's own words.
func TestOnlyTerminalToolStatusesPrint(t *testing.T) {
	inFlight := formatOutput(acpEvent(`{"sessionUpdate":"tool_call_update","toolCallId":"t1","status":"in_progress"}`))
	if inFlight != "" {
		t.Errorf("in-flight tool update printed %q", inFlight)
	}

	done := formatOutput(acpEvent(`{"sessionUpdate":"tool_call_update","toolCallId":"t1","status":"completed"}`))
	if !strings.Contains(done, "completed") {
		t.Errorf("completed tool update missing from %q", done)
	}

	failed := formatOutput(acpEvent(`{"sessionUpdate":"tool_call_update","toolCallId":"t1","status":"failed"}`))
	if !strings.Contains(failed, "failed") {
		t.Errorf("failed tool update missing from %q", failed)
	}
}

// Thinking is dimmed rather than dropped: on a long tool-heavy turn it is
// often the only output, and a silent terminal reads as a hung agent.
func TestThoughtsAreDimmedNotDropped(t *testing.T) {
	out := formatOutput(acpEvent(`{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"considering"}}`))

	if !strings.Contains(out, "considering") {
		t.Errorf("thought missing from %q", out)
	}
	if !strings.Contains(out, "\x1b[2m") {
		t.Errorf("thought was not dimmed: %q", out)
	}
}

// Variants a terminal has nothing useful to do with must not print noise —
// a usage_update per turn is not something anyone asked to read.
func TestBookkeepingUpdatesPrintNothing(t *testing.T) {
	for _, kind := range []string{"usage_update", "available_commands_update", "plan"} {
		if got := formatOutput(acpEvent(`{"sessionUpdate":"` + kind + `"}`)); got != "" {
			t.Errorf("%s printed %q, want nothing", kind, got)
		}
	}
}

// A line that is not JSON-RPC is somebody else's diagnostic on a pipe that
// should carry only protocol. Skipped, never crashed on.
func TestGarbageOnTheACPStreamIsSkipped(t *testing.T) {
	out := formatOutput(map[string]any{
		"kind": "output", "stream": "acp", "stage": "turn",
		"data": "npm warn deprecated foo@1.0.0\n",
	})

	if out != "" {
		t.Errorf("non-protocol line rendered as %q", out)
	}
}

// Diagnostics remain visible even though vendor transcripts are retired.
func TestDiagnosticsAreUnchanged(t *testing.T) {
	stderr := formatOutput(map[string]any{"kind": "output", "stream": "stderr", "data": "boom"})
	if stderr != "\x1b[31mboom\x1b[0m" {
		t.Errorf("stderr rendering changed: %q", stderr)
	}

	setup := formatOutput(map[string]any{
		"kind": "output", "stream": "stdout", "stage": "setup", "data": "installing",
	})
	if setup != "installing\n" {
		t.Errorf("setup output rendering changed: %q", setup)
	}
}

func TestHistoricalVendorOutputIsNotInterpreted(t *testing.T) {
	for _, stage := range []string{"", "turn"} {
		for _, raw := range []string{
			`{"type":"assistant","message":{"content":[{"type":"text","text":"legacy"}]}}`,
			`{"type":"result","result":"legacy result"}`,
			`{"type":"system","subtype":"code_change_published","url":"https://example.com/pr/42"}`,
		} {
			if got := formatOutput(map[string]any{"stream": "stdout", "stage": stage, "data": raw}); got != "" {
				t.Errorf("historical stdout rendered with stage %q: %q", stage, got)
			}
		}
	}
}
