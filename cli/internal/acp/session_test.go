package acp

import (
	"context"
	"errors"
	"strings"
	"sync"
	"testing"
)

type fakeAPI struct {
	mu        sync.Mutex
	ref       AgentRef
	agentErr  error
	createErr error

	resolved []string
	created  []string
	channels []string
	fresh    []bool
	sandbox  []SessionOptions
	convID   string
	resumed  bool

	// prompt path
	head       string
	headErr    error
	promptErr  error
	followErr  error
	events     []Event
	prompts    []sentPrompt
	followFrom []string

	// cancel path
	interruptErr error
	interrupted  []string
	onInterrupt  func()
	// followBlock, when set, holds Follow open until it is closed — a stand-in
	// for a turn that sits there until something stops it. followStarted, when
	// set, is closed once Follow has been entered, so a test can send a cancel
	// at the moment a real one would arrive.
	followBlock   chan struct{}
	followStarted chan struct{}

	// load path
	conversation    ConversationRef
	conversationErr error
	replay          []Event
	replayErr       error

	// permission path (#708)
	answers   []permissionAnswer
	answerErr error
}

type permissionAnswer struct {
	convID    string
	requestID string
	optionID  string
}

type sentPrompt struct {
	convID          string
	text            string
	images          []Image
	clientRequestID *string
}

func (f *fakeAPI) Agent(_ context.Context, target string) (AgentRef, error) {
	f.resolved = append(f.resolved, target)
	if f.agentErr != nil {
		return AgentRef{}, f.agentErr
	}
	return f.ref, nil
}

func (f *fakeAPI) CreateConversation(_ context.Context, agentID string, opts SessionOptions) (string, bool, error) {
	f.created = append(f.created, agentID)
	f.channels = append(f.channels, opts.ChannelID)
	f.fresh = append(f.fresh, opts.Fresh)
	f.sandbox = append(f.sandbox, opts)
	if f.createErr != nil {
		return "", false, f.createErr
	}
	if f.convID == "" {
		return "conv-1", f.resumed, nil
	}
	return f.convID, f.resumed, nil
}

func (f *fakeAPI) StreamHead(context.Context, string) (string, error) {
	if f.headErr != nil {
		return "", f.headErr
	}
	return f.head, nil
}

func (f *fakeAPI) SendPrompt(_ context.Context, convID, text string, images []Image, clientRequestID *string) error {
	f.prompts = append(f.prompts, sentPrompt{convID: convID, text: text, images: images, clientRequestID: clientRequestID})
	return f.promptErr
}

func (f *fakeAPI) Interrupt(_ context.Context, convID string) error {
	f.mu.Lock()
	f.interrupted = append(f.interrupted, convID)
	onInterrupt := f.onInterrupt
	f.mu.Unlock()

	if onInterrupt != nil {
		onInterrupt()
	}
	return f.interruptErr
}

func (f *fakeAPI) AnswerPermission(_ context.Context, convID, requestID, optionID string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.answers = append(f.answers, permissionAnswer{
		convID:    convID,
		requestID: requestID,
		optionID:  optionID,
	})
	return f.answerErr
}

// answered returns the answers recorded so far, safely — the permission path
// runs on its own goroutine.
func (f *fakeAPI) answered() []permissionAnswer {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]permissionAnswer(nil), f.answers...)
}

func (f *fakeAPI) Follow(_ context.Context, _, lastEventID string, fn EventFunc) error {
	f.mu.Lock()
	f.followFrom = append(f.followFrom, lastEventID)
	block := f.followBlock
	started := f.followStarted
	f.mu.Unlock()

	if started != nil {
		close(started)
	}
	if block != nil {
		<-block
	}
	if f.followErr != nil {
		return f.followErr
	}
	for _, ev := range f.events {
		stop, err := fn(ev)
		if err != nil {
			return err
		}
		if stop {
			return nil
		}
	}
	return nil
}

func (f *fakeAPI) Conversation(context.Context, string) (ConversationRef, error) {
	if f.conversationErr != nil {
		return ConversationRef{}, f.conversationErr
	}
	return f.conversation, nil
}

func (f *fakeAPI) Replay(_ context.Context, _ string, fn EventFunc) error {
	if f.replayErr != nil {
		return f.replayErr
	}
	for _, ev := range f.replay {
		stop, err := fn(ev)
		if err != nil {
			return err
		}
		if stop {
			return nil
		}
	}
	return nil
}

func acpAgentRef() AgentRef {
	return AgentRef{ID: "agent-1", Name: "researcher", Runtime: "claude", ACP: true}
}

// sessionAgent returns an initialized, authenticated agent — the state a real
// one is in by the time `session/new` arrives.
func sessionAgent(t *testing.T, api *fakeAPI, target string) *Agent {
	t.Helper()

	a := NewAgent(&fakeAuth{available: true}, api, target, "test", discardLogger())
	if _, rpcErr := request(t, a, "initialize", map[string]any{"protocolVersion": ProtocolVersion}); rpcErr != nil {
		t.Fatalf("initialize failed: %v", rpcErr)
	}
	return a
}

func TestNewSessionCreatesAConversationForTheConfiguredAgent(t *testing.T) {
	api := &fakeAPI{ref: acpAgentRef(), convID: "conv-42"}
	a := sessionAgent(t, api, "researcher")

	result, rpcErr := request(t, a, "session/new", map[string]any{"cwd": "/home/dev/proj"})
	if rpcErr != nil {
		t.Fatalf("session/new failed: %v", rpcErr)
	}

	if result["sessionId"] != "conv-42" {
		t.Errorf("sessionId = %v, want the conversation id", result["sessionId"])
	}
	if len(api.resolved) != 1 || api.resolved[0] != "researcher" {
		t.Errorf("resolved = %v, want [researcher]", api.resolved)
	}
	if len(api.created) != 1 || api.created[0] != "agent-1" {
		t.Errorf("created for = %v, want [agent-1]", api.created)
	}
}

// The session id IS the conversation id, deliberately: an editor that stored
// it yesterday must be able to hand it back to a process started today, and a
// minted id would need a map that dies with the process.
func TestSessionIsAddressableByTheConversationID(t *testing.T) {
	api := &fakeAPI{ref: acpAgentRef(), convID: "conv-42"}
	a := sessionAgent(t, api, "researcher")

	request(t, a, "session/new", map[string]any{})

	sess, ok := a.sessions.get("conv-42")
	if !ok {
		t.Fatal("session not registered under the conversation id")
	}
	if sess.Agent.Name != "researcher" {
		t.Errorf("session agent = %v, want researcher", sess.Agent.Name)
	}
}

// #702: an agent on the legacy path emits its runtime's own dialect, which
// this adapter deliberately cannot parse. Starting the conversation anyway
// would bill a sandbox to render nothing.
func TestNewSessionRefusesARuntimeThatDoesNotSpeakACP(t *testing.T) {
	api := &fakeAPI{ref: AgentRef{ID: "agent-2", Name: "gem", Runtime: "gemini", ACP: false}}
	a := sessionAgent(t, api, "gem")

	_, rpcErr := request(t, a, "session/new", map[string]any{})
	if rpcErr == nil {
		t.Fatal("session/new accepted an agent whose runtime does not speak ACP")
	}
	if !strings.Contains(rpcErr.Message, "gemini") {
		t.Errorf("message = %q, want it to name the runtime", rpcErr.Message)
	}
	if len(api.created) != 0 {
		t.Errorf("a conversation was created for a runtime we cannot render: %v", api.created)
	}
}

func TestNewSessionWithNoAgentConfiguredSaysHowToConfigureOne(t *testing.T) {
	api := &fakeAPI{ref: acpAgentRef()}
	a := sessionAgent(t, api, "")

	_, rpcErr := request(t, a, "session/new", map[string]any{})
	if rpcErr == nil {
		t.Fatal("session/new succeeded with no agent configured")
	}
	if !strings.Contains(rpcErr.Message, "--agent") {
		t.Errorf("message = %q, want it to name the flag that fixes it", rpcErr.Message)
	}
	if len(api.resolved) != 0 {
		t.Errorf("resolved an agent that was never configured: %v", api.resolved)
	}
}

func TestNewSessionReportsAnUnresolvableAgent(t *testing.T) {
	api := &fakeAPI{agentErr: errors.New(`no agent named "typo"`)}
	a := sessionAgent(t, api, "typo")

	_, rpcErr := request(t, a, "session/new", map[string]any{})
	if rpcErr == nil {
		t.Fatal("session/new succeeded with an agent that does not exist")
	}
	if !strings.Contains(rpcErr.Message, "typo") {
		t.Errorf("message = %q, want it to name the agent it looked for", rpcErr.Message)
	}
	// The instance matters: the usual cause is an editor pointed at the wrong
	// one, where every agent name is legitimately absent.
	if !strings.Contains(rpcErr.Message, "example.test") {
		t.Errorf("message = %q, want it to name the instance it asked", rpcErr.Message)
	}
}

func TestNewSessionReportsAFailedConversationStart(t *testing.T) {
	api := &fakeAPI{ref: acpAgentRef(), createErr: errors.New("http 402: insufficient_credits")}
	a := sessionAgent(t, api, "researcher")

	_, rpcErr := request(t, a, "session/new", map[string]any{})
	if rpcErr == nil {
		t.Fatal("session/new reported success for a conversation that was never created")
	}
	if !strings.Contains(rpcErr.Message, "insufficient_credits") {
		t.Errorf("message = %q, want it to carry the server's reason", rpcErr.Message)
	}
}

// A client that skips the handshake gets told which step it missed, rather
// than an error from three layers down.
func TestNewSessionBeforeInitializeIsRefused(t *testing.T) {
	a := NewAgent(&fakeAuth{available: true}, &fakeAPI{ref: acpAgentRef()}, "researcher", "test", discardLogger())

	_, rpcErr := request(t, a, "session/new", map[string]any{})
	if rpcErr == nil || rpcErr.Code != CodeInvalidRequest {
		t.Fatalf("want an invalid-request error, got %v", rpcErr)
	}
	if !strings.Contains(rpcErr.Message, "initialize") {
		t.Errorf("message = %q, want it to name the missing step", rpcErr.Message)
	}
}

func TestNewSessionWithoutCredentialsIsRefused(t *testing.T) {
	api := &fakeAPI{ref: acpAgentRef()}
	a := NewAgent(&fakeAuth{available: false}, api, "researcher", "test", discardLogger())
	request(t, a, "initialize", map[string]any{"protocolVersion": ProtocolVersion})

	_, rpcErr := request(t, a, "session/new", map[string]any{})
	if rpcErr == nil || rpcErr.Code != CodeAuthRequired {
		t.Fatalf("want an auth-required error, got %v", rpcErr)
	}
	if len(api.created) != 0 {
		t.Errorf("created a conversation for an unauthenticated client: %v", api.created)
	}
}

// The editor's cwd and its MCP servers describe the developer's machine. The
// agent runs in a sandbox, so acting on either would be acting on the wrong
// computer — they are logged and ignored, and the session still opens.
func TestClientSideSessionParametersAreIgnoredNotFatal(t *testing.T) {
	api := &fakeAPI{ref: acpAgentRef(), convID: "conv-7"}
	a := sessionAgent(t, api, "researcher")

	result, rpcErr := request(t, a, "session/new", map[string]any{
		"cwd": "/home/dev/proj",
		"mcpServers": []map[string]any{
			{"name": "local-fs", "command": "/usr/local/bin/mcp-fs"},
		},
	})
	if rpcErr != nil {
		t.Fatalf("session/new failed: %v", rpcErr)
	}
	if result["sessionId"] != "conv-7" {
		t.Errorf("sessionId = %v, want conv-7", result["sessionId"])
	}
}

// #774: a chat harness (buzz-acp) forgets its sessions on every restart and
// opens `session/new` again for each channel. It names the channel in
// `_meta.channelId`; that key goes to the server, which hands back the
// conversation already bound to it — same sandbox, same runtime session — as
// this session's id.
func TestNewSessionForwardsTheChannelKeyAndAcceptsAResumedConversation(t *testing.T) {
	api := &fakeAPI{ref: acpAgentRef(), convID: "conv-old", resumed: true}
	a := sessionAgent(t, api, "researcher")

	result, rpcErr := request(t, a, "session/new", map[string]any{
		"cwd":   "/home/dev/proj",
		"_meta": map[string]any{"channelId": "chan-002b49f3", "sessionTitle": "Fizz"},
	})
	if rpcErr != nil {
		t.Fatalf("session/new failed: %v", rpcErr)
	}
	if result["sessionId"] != "conv-old" {
		t.Errorf("sessionId = %v, want the resumed conversation", result["sessionId"])
	}
	if len(api.channels) != 1 || api.channels[0] != "chan-002b49f3" {
		t.Errorf("channel forwarded = %v, want [chan-002b49f3]", api.channels)
	}
	if _, ok := a.sessions.get("conv-old"); !ok {
		t.Error("the resumed conversation is not registered as this session")
	}
}

// The first session/new after the harness's owner rotated the channel
// (`!rotate`) carries `_meta.freshSession: true`. That must reach the server as
// a request to skip the resume — otherwise the channel-bound resume hands the
// same conversation straight back and rotation is a no-op.
func TestNewSessionForwardsFreshSessionAfterARotate(t *testing.T) {
	api := &fakeAPI{ref: acpAgentRef(), convID: "conv-new"}
	a := sessionAgent(t, api, "researcher")

	if _, rpcErr := request(t, a, "session/new", map[string]any{
		"_meta": map[string]any{"channelId": "chan-002b49f3", "freshSession": true},
	}); rpcErr != nil {
		t.Fatalf("session/new failed: %v", rpcErr)
	}
	if len(api.fresh) != 1 || !api.fresh[0] {
		t.Errorf("fresh forwarded = %v, want [true]", api.fresh)
	}

	// Absent → false: an ordinary (or restarted) session/new still resumes.
	if _, rpcErr := request(t, a, "session/new", map[string]any{
		"_meta": map[string]any{"channelId": "chan-002b49f3"},
	}); rpcErr != nil {
		t.Fatalf("session/new failed: %v", rpcErr)
	}
	if len(api.fresh) != 2 || api.fresh[1] {
		t.Errorf("fresh forwarded = %v, want [true false]", api.fresh)
	}
}

// No _meta.channelId → no channel key: an editor's session/new must not
// accidentally bind to "" and start resuming across unrelated projects.
func TestNewSessionWithoutAChannelKeySendsNone(t *testing.T) {
	api := &fakeAPI{ref: acpAgentRef(), convID: "conv-1"}
	a := sessionAgent(t, api, "researcher")

	if _, rpcErr := request(t, a, "session/new", map[string]any{"cwd": "/p"}); rpcErr != nil {
		t.Fatalf("session/new failed: %v", rpcErr)
	}
	if len(api.channels) != 1 || api.channels[0] != "" {
		t.Errorf("channel forwarded = %v, want [\"\"]", api.channels)
	}
}

func TestTwoSessionsAreTrackedIndependently(t *testing.T) {
	api := &fakeAPI{ref: acpAgentRef(), convID: "conv-a"}
	a := sessionAgent(t, api, "researcher")

	request(t, a, "session/new", map[string]any{})
	api.convID = "conv-b"
	request(t, a, "session/new", map[string]any{})

	for _, id := range []string{"conv-a", "conv-b"} {
		if _, ok := a.sessions.get(id); !ok {
			t.Errorf("session %s was not registered", id)
		}
	}
}

func TestSetConfigOptionIsAcceptedRatherThanRejected(t *testing.T) {
	api := &fakeAPI{ref: acpAgentRef(), convID: "conv-9"}
	a := sessionAgent(t, api, "researcher")

	if _, rpcErr := request(t, a, "session/new", map[string]any{}); rpcErr != nil {
		t.Fatalf("session/new failed: %v", rpcErr)
	}

	// A client that pushes a model at session start — as OpenClaw's acpx does —
	// must not get "method not found". Rejecting it makes acpx abort the whole
	// turn; the method is implemented so the request is accepted.
	result, rpcErr := request(t, a, "session/set_config_option", map[string]any{
		"sessionId": "conv-9",
		"configId":  "model",
		"value":     "anthropic/claude-something-else",
	})
	if rpcErr != nil {
		t.Fatalf("set_config_option returned an error: %v", rpcErr)
	}

	// The push is accepted but not applied: the agent's model is authoritative.
	// The reply says so in _meta and — deliberately — advertises no
	// configOptions list: acpx narrows the controls it will send to whatever
	// list the last reply carried, so an honest empty (or model-only) list makes
	// its next control fail with "does not advertise config option 'thinking'"
	// and the turn dies anyway (#760).
	if _, present := result["configOptions"]; present {
		t.Errorf("configOptions = %#v, want the key absent (a list, even an honest one, makes acpx abort the next control)", result["configOptions"])
	}
	meta, _ := result["_meta"].(map[string]any)
	fountainMeta, _ := meta["fountain"].(map[string]any)
	if got := fountainMeta["applied"]; got != false {
		t.Errorf("_meta.fountain.applied = %v, want false", got)
	}
	sess, _ := a.sessions.get("conv-9")
	if sess.Agent.Model != "" {
		t.Errorf("agent model = %q after the push, want unchanged (empty in this fixture)", sess.Agent.Model)
	}
}

func TestSetConfigOptionOnAnUnknownSessionIsRefused(t *testing.T) {
	api := &fakeAPI{ref: acpAgentRef(), convID: "conv-9"}
	a := sessionAgent(t, api, "researcher")

	_, rpcErr := request(t, a, "session/set_config_option", map[string]any{
		"sessionId": "nope",
		"configId":  "model",
		"value":     "x",
	})
	if rpcErr == nil {
		t.Fatal("expected an error for an unknown session")
	}
	if rpcErr.Code != CodeInvalidParams {
		t.Errorf("code = %d, want CodeInvalidParams (%d)", rpcErr.Code, CodeInvalidParams)
	}
}

// ADR 0023: a client may say per session where its conversation runs. Both
// keys ride to the API layer as they were sent; absent means "not asked".
func TestNewSessionForwardsTheSandboxOverrides(t *testing.T) {
	api := &fakeAPI{ref: acpAgentRef(), convID: "conv-home"}
	a := sessionAgent(t, api, "researcher")

	if _, rpcErr := request(t, a, "session/new", map[string]any{
		"cwd":   "/home/dev/proj",
		"_meta": map[string]any{"sandboxMode": "persistent", "sandboxId": "sb-1"},
	}); rpcErr != nil {
		t.Fatalf("session/new failed: %v", rpcErr)
	}
	if len(api.sandbox) != 1 || api.sandbox[0].SandboxMode != "persistent" || api.sandbox[0].SandboxID != "sb-1" {
		t.Errorf("sandbox options forwarded = %+v, want persistent / sb-1", api.sandbox)
	}

	if _, rpcErr := request(t, a, "session/new", map[string]any{"cwd": "/home/dev/proj"}); rpcErr != nil {
		t.Fatalf("session/new failed: %v", rpcErr)
	}
	if len(api.sandbox) != 2 || api.sandbox[1].SandboxMode != "" || api.sandbox[1].SandboxID != "" {
		t.Errorf("sandbox options forwarded = %+v, want empty for a session that asked nothing", api.sandbox[1:])
	}
}
