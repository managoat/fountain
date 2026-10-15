package acp

import (
	"errors"
	"strings"
	"testing"
)

// loadAgent returns an agent that has handshaked but opened nothing — the
// state a freshly spawned process is in when an editor hands back a session id
// from yesterday.
func loadAgent(t *testing.T, api *fakeAPI) (*Agent, *fakeNotifier) {
	t.Helper()

	a := NewAgent(&fakeAuth{available: true}, api, "researcher", "test", discardLogger())
	if _, rpcErr := request(t, a, "initialize", map[string]any{"protocolVersion": ProtocolVersion}); rpcErr != nil {
		t.Fatalf("initialize failed: %v", rpcErr)
	}
	n := &fakeNotifier{}
	a.SetNotifier(n)
	return a, n
}

func acpConversation() ConversationRef {
	return ConversationRef{ID: "conv-9", Runtime: "claude", Status: "idle"}
}

// The whole pitch: the work outlived the editor. A process that never saw this
// conversation can still put it back on screen.
func TestLoadReplaysTheTranscriptOfAConversationThisProcessNeverOpened(t *testing.T) {
	api := &fakeAPI{
		conversation: acpConversation(),
		replay: []Event{
			{Kind: "output", Stream: "acp", Data: acpLine("sprite-session", "first")},
			{Kind: "output", Stream: "acp", Data: acpLine("sprite-session", "second")},
		},
	}
	a, notifier := loadAgent(t, api)

	if _, rpcErr := request(t, a, "session/load", map[string]any{"sessionId": "conv-9"}); rpcErr != nil {
		t.Fatalf("session/load failed: %v", rpcErr)
	}

	if len(notifier.methods) != 2 {
		t.Fatalf("replayed %d updates, want 2", len(notifier.methods))
	}
	for _, m := range notifier.methods {
		if m != "session/update" {
			t.Errorf("replayed a %s, want session/update", m)
		}
	}
}

// ACP requires the replay to precede the response. We have already been on the
// receiving end of the opposite (#657: gemini answered `session/load` and
// replayed afterwards, so the client double-rendered a turn).
func TestLoadReplaysBeforeItAnswers(t *testing.T) {
	api := &fakeAPI{
		conversation: acpConversation(),
		replay: []Event{
			{Kind: "output", Stream: "acp", Data: acpLine("sprite-session", "first")},
		},
	}
	a, notifier := loadAgent(t, api)

	// Recorded at the moment the handler returns: everything the editor is
	// owed must already have been written.
	request(t, a, "session/load", map[string]any{"sessionId": "conv-9"})

	if notifier.rawCalls != 1 {
		t.Errorf("the response was produced with %d updates sent, want 1 — a client "+
			"that renders on the response would show an empty transcript", notifier.rawCalls)
	}
}

// A loaded session is a session: the next prompt continues the same
// conversation rather than opening a new one.
func TestLoadedSessionIsPromptable(t *testing.T) {
	api := &fakeAPI{
		conversation: acpConversation(),
		events:       []Event{stageEvent("turn", "done", `{"stop_reason":"end_turn"}`)},
	}
	a, _ := loadAgent(t, api)

	request(t, a, "session/load", map[string]any{"sessionId": "conv-9"})

	result, rpcErr := request(t, a, "session/prompt", textPrompt("conv-9", "carry on"))
	if rpcErr != nil {
		t.Fatalf("prompting a loaded session failed: %v", rpcErr)
	}
	if result["stopReason"] != "end_turn" {
		t.Errorf("stopReason = %v, want end_turn", result["stopReason"])
	}
	if len(api.prompts) != 1 || api.prompts[0].convID != "conv-9" {
		t.Errorf("prompts = %+v, want one for conv-9", api.prompts)
	}
	if len(api.created) != 0 {
		t.Errorf("loading a session created a conversation: %v", api.created)
	}
}

func TestLoadReportsAConversationThatIsNotThere(t *testing.T) {
	api := &fakeAPI{conversationErr: errors.New("http 404")}
	a, _ := loadAgent(t, api)

	_, rpcErr := request(t, a, "session/load", map[string]any{"sessionId": "conv-gone"})
	if rpcErr == nil {
		t.Fatal("loaded a session that does not exist")
	}
	for _, want := range []string{"conv-gone", "example.test"} {
		if !strings.Contains(rpcErr.Message, want) {
			t.Errorf("message = %q, want it to mention %q", rpcErr.Message, want)
		}
	}
}

func TestLoadWithoutASessionIDIsRefused(t *testing.T) {
	api := &fakeAPI{conversation: acpConversation()}
	a, _ := loadAgent(t, api)

	_, rpcErr := request(t, a, "session/load", map[string]any{})
	if rpcErr == nil || rpcErr.Code != CodeInvalidParams {
		t.Fatalf("want invalid params, got %v", rpcErr)
	}
}

// A failed replay must not leave the editor believing it has the transcript.
func TestLoadReportsAFailedReplay(t *testing.T) {
	api := &fakeAPI{conversation: acpConversation(), replayErr: errors.New("stream HTTP 500")}
	a, _ := loadAgent(t, api)

	_, rpcErr := request(t, a, "session/load", map[string]any{"sessionId": "conv-9"})
	if rpcErr == nil {
		t.Fatal("a failed replay answered as though the transcript had been sent")
	}
}

// The replayed updates go out under our session id, like live ones — the
// sprite's own id means nothing to the editor (#649).
func TestReplayedUpdatesCarryOurSessionID(t *testing.T) {
	api := &fakeAPI{
		conversation: acpConversation(),
		replay:       []Event{{Kind: "output", Stream: "acp", Data: acpLine("sprite-session", "hi")}},
	}
	a, notifier := loadAgent(t, api)

	request(t, a, "session/load", map[string]any{"sessionId": "conv-9"})

	if got := notifier.params[0]["sessionId"]; got != "conv-9" {
		t.Errorf("sessionId = %v, want conv-9", got)
	}
}

// Loading is a read: it must not require the --agent that opening a new
// session does, because the conversation already knows which agent it belongs
// to.
func TestLoadNeedsNoConfiguredAgent(t *testing.T) {
	api := &fakeAPI{conversation: acpConversation()}
	a := NewAgent(&fakeAuth{available: true}, api, "", "test", discardLogger())
	request(t, a, "initialize", map[string]any{"protocolVersion": ProtocolVersion})
	a.SetNotifier(&fakeNotifier{})

	if _, rpcErr := request(t, a, "session/load", map[string]any{"sessionId": "conv-9"}); rpcErr != nil {
		t.Fatalf("session/load required an agent it did not need: %v", rpcErr)
	}
}

func TestLoadBeforeInitializeIsRefused(t *testing.T) {
	api := &fakeAPI{conversation: acpConversation()}
	a := NewAgent(&fakeAuth{available: true}, api, "researcher", "test", discardLogger())

	_, rpcErr := request(t, a, "session/load", map[string]any{"sessionId": "conv-9"})
	if rpcErr == nil || rpcErr.Code != CodeInvalidRequest {
		t.Fatalf("want an invalid-request error, got %v", rpcErr)
	}
}
