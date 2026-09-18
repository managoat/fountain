package acp

import (
	"context"
	"encoding/json"
	"sync"
)

// API is the slice of the Fountain HTTP API this adapter needs. It is an
// interface so the protocol logic can be tested without a server, and so
// nothing in this package holds an HTTP client, a token or a base URL — those
// stay in the CLI layer that already resolves them for every other command.
type API interface {
	// Agent resolves a name or id to the agent it names.
	Agent(ctx context.Context, target string) (AgentRef, error)
	// CreateConversation starts a conversation for an agent and returns its id.
	// opts carries what the client's `session/new` said out of band: the
	// channel key and rotation flag, and the per-session sandbox override.
	// With a non-empty channelID the server resumes the latest live conversation
	// already bound to that channel for the same agent and vault instead of
	// opening a new one (#774); resumed reports which happened. fresh asks the
	// server to skip that resume and open a new conversation that becomes the
	// channel's binding — the client's owner rotated the channel.
	CreateConversation(ctx context.Context, agentID string, opts SessionOptions) (id string, resumed bool, err error)
	// StreamHead returns the conversation's current last event id, so a follow
	// can skip the history. Called BEFORE a prompt is sent — see prompt.go.
	StreamHead(ctx context.Context, convID string) (string, error)
	// SendPrompt queues a turn. It returns as soon as the server accepts it;
	// the turn's outcome arrives on the stream. A nil clientRequestID omits
	// the optional correlation field; a supplied value is validated by the server.
	SendPrompt(ctx context.Context, convID, prompt string, images []Image, clientRequestID *string) error
	// Follow consumes the conversation's event stream from lastEventID until
	// fn reports stop, reconnecting across the disconnects the server produces
	// by design.
	Follow(ctx context.Context, convID, lastEventID string, fn EventFunc) error
	// Interrupt stops the running turn. A conversation with no turn running is
	// not an error — see cancel.
	Interrupt(ctx context.Context, convID string) error
	// AnswerPermission answers a held `session/request_permission` with one of
	// the options the agent offered (#940). A request another client, the
	// timeout or the turn's end already resolved returns an error satisfying
	// IsAlreadyResolved — losing that race is the contract, not a failure.
	AnswerPermission(ctx context.Context, convID, requestID, optionID string) error
	// Conversation looks up a conversation the adapter did not open, which is
	// what `session/load` is: an editor handing back an id from last week.
	Conversation(ctx context.Context, convID string) (ConversationRef, error)
	// Replay drains the conversation's stored ACP events from the beginning,
	// oldest first, and closes. Unlike Follow it does not wait for more.
	Replay(ctx context.Context, convID string, fn EventFunc) error
}

// ConversationRef is what the adapter needs to know about a conversation it is
// being asked to reopen.
type ConversationRef struct {
	ID      string
	Runtime string
	Status  string
	// Agent and Model describe what this conversation runs, for the model
	// state a reopened session reports.
	Agent string
	Model string
	// ACP reports whether this conversation's output was stored as protocol.
	// A legacy-runtime conversation has a transcript, but not one this adapter
	// can replay — see #702.
	ACP bool
}

// AgentRef is what the adapter needs to know about a Fountain agent.
type AgentRef struct {
	ID      string
	Name    string
	Runtime string
	// Model is the agent's canonical provider/model id, e.g.
	// "anthropic/claude-sonnet-4-6". Reported to the client as the session's
	// current model — see modelState.
	Model string
	// ACP reports whether the runtime speaks the protocol. The server derives
	// it (GET /api/agents/:id) precisely so this file does not carry a list of
	// runtime names that goes stale the day a held-back runtime is converted.
	ACP bool
}

// Session is one editor-visible conversation.
type Session struct {
	// ID is the Fountain conversation id, used verbatim as the ACP session id.
	//
	// This aliasing is deliberate. ACP session ids are opaque to the client,
	// and minting our own would mean holding a session→conversation map that
	// dies with the process — so an editor reopening tomorrow could hand back
	// a session id nothing could resolve, and `session/load` (#703) would have
	// to persist a map to disk to work at all. The conversation id is already
	// durable, already addressable, and already the thing the web UI shows.
	//
	// What must NOT leak upward is the third id: `runtime_session_id` belongs
	// to the runtime inside the sandbox, means nothing outside the sandbox
	// that holds it, and does not survive a reclaim (#649).
	ID    string
	Agent AgentRef
}

// sessions is the in-memory registry of sessions opened on this connection.
type sessions struct {
	mu sync.Mutex
	m  map[string]Session
}

func newSessions() *sessions { return &sessions{m: map[string]Session{}} }

func (s *sessions) put(sess Session) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.m[sess.ID] = sess
}

func (s *sessions) get(id string) (Session, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	sess, ok := s.m[id]
	return sess, ok
}

// SessionOptions is what one `session/new` asks for beyond the agent: the
// channel it serves (and whether to skip the resume this once), and where the
// conversation runs. An empty field means "not asked" — the API layer then
// falls back to its process-wide flags, or omits the key so the server
// applies the agent's default.
type SessionOptions struct {
	ChannelID string
	Fresh     bool
	// SandboxMode is `ephemeral` or `persistent` (ADR 0023); SandboxID attaches
	// the session to a machine the caller already has.
	SandboxMode string
	SandboxID   string
}

type newSessionParams struct {
	Cwd        string            `json:"cwd"`
	MCPServers []json.RawMessage `json:"mcpServers"`
	// Meta is the out-of-band bag ACP lets a client attach. `channelId` is
	// what a chat harness (buzz-acp) sends to name the channel this session
	// serves — the one thing the server can key a resume on, since the same
	// harness forgets its sessions on every restart. `freshSession` rides
	// with it on the first session/new after the harness's owner rotated the
	// channel (`!rotate`): the resume must be skipped this once, or rotation
	// is a no-op behind a channel-keyed server. `sandboxMode` and `sandboxId`
	// say where this one session's conversation runs (ADR 0023), overriding
	// the process's --sandbox-mode / --sandbox for the session. Anything else
	// in _meta is ignored here.
	Meta struct {
		ChannelID    string `json:"channelId"`
		FreshSession bool   `json:"freshSession"`
		SandboxMode  string `json:"sandboxMode"`
		SandboxID    string `json:"sandboxId"`
	} `json:"_meta"`
}

func (a *Agent) newSession(ctx context.Context, raw json.RawMessage) (any, error) {
	var params newSessionParams
	if len(raw) > 0 {
		if err := json.Unmarshal(raw, &params); err != nil {
			return nil, Errorf(CodeInvalidParams, "session/new: %s", err)
		}
	}

	if err := a.requireReady(); err != nil {
		return nil, err
	}

	// `cwd` is the editor's project directory, on the developer's machine. The
	// agent works in a sandbox that cloned its own checkout, so this path
	// names nothing we can act on — logged, so an editor's expectation is
	// visible in the record, and otherwise ignored. Same for the editor's MCP
	// servers: they are processes on the developer's machine, and a Fountain
	// agent carries its own MCP configuration to the sandbox (#673).
	if params.Cwd != "" || len(params.MCPServers) > 0 {
		a.log.Info("ignoring client-side session parameters",
			"cwd", params.Cwd,
			"mcpServers", len(params.MCPServers),
			"why", "the agent runs in a sandbox, not on this machine")
	}

	if a.agentTarget == "" {
		return nil, Errorf(CodeInvalidParams,
			"no Fountain agent configured — spawn this as `fountain acp --agent <name-or-id>`")
	}

	ref, err := a.api.Agent(ctx, a.agentTarget)
	if err != nil {
		return nil, Errorf(CodeInternalError,
			"could not resolve agent %q on %s: %s", a.agentTarget, a.auth.Describe(), err)
	}

	// The refusal is the honest half of #702. An agent on the legacy path
	// emits its runtime's own dialect, which this adapter deliberately cannot
	// parse — forwarding nothing would leave an editor rendering an empty
	// conversation while a sandbox ran and billed.
	if !ref.ACP {
		return nil, Errorf(CodeInvalidParams,
			"agent %q runs the %s runtime, which does not speak ACP — use it from the web UI or the CLI, "+
				"or point this at an agent whose runtime does",
			ref.Name, ref.Runtime)
	}

	// A channel-bound session lands on the conversation already bound to that
	// channel when there is one. From the client's side this is still a new
	// session with a fresh id (it did not know the old one — that is the
	// point); from Fountain's side it is the same conversation, sandbox and
	// runtime session, which is what makes a chat harness's restart invisible
	// to the people in the channel (#774). Unless the harness says the owner
	// rotated the channel — then a new conversation is opened and becomes
	// the binding.
	convID, resumed, err := a.api.CreateConversation(ctx, ref.ID, SessionOptions{
		ChannelID:   params.Meta.ChannelID,
		Fresh:       params.Meta.FreshSession,
		SandboxMode: params.Meta.SandboxMode,
		SandboxID:   params.Meta.SandboxID,
	})
	if err != nil {
		return nil, Errorf(CodeInternalError, "could not start a conversation for %q: %s", ref.Name, err)
	}

	sess := Session{ID: convID, Agent: ref}
	a.sessions.put(sess)
	a.log.Info("session opened",
		"sessionId", sess.ID, "agent", ref.Name, "runtime", ref.Runtime, "model", ref.Model,
		"channelId", params.Meta.ChannelID, "fresh", params.Meta.FreshSession, "resumed", resumed)

	return map[string]any{
		"sessionId": sess.ID,
		"models":    modelState(ref),
	}, nil
}

// modelState reports the session's model.
//
// A Fountain agent's model is part of the agent, chosen once and shared by
// every conversation it runs — so the list has exactly one entry and it is
// also the current one. That is not a placeholder: switching models here would
// mean editing the agent, which would silently change what every other
// conversation on it runs, and `session/set_model` is not implemented for that
// reason.
//
// Reporting it at all matters because clients use this list to decide the
// agent is usable: Buzz refuses an agent that reports no models, with a
// message about the CLI not being signed in — a true statement about a
// different problem.
func modelState(ref AgentRef) map[string]any {
	model := ref.Model
	if model == "" {
		// An agent with no model set runs the runtime's own default. Saying so
		// beats reporting an empty list, which reads as "no models available".
		model = "default"
	}

	return map[string]any{
		"currentModelId": model,
		"availableModels": []map[string]any{{
			"modelId":     model,
			"name":        model,
			"description": "Configured on the Fountain agent \"" + ref.Name + "\". Change it on the agent, not here.",
		}},
	}
}

// requireReady is the gate the session methods share: a client that has not
// handshaked, or has no working credentials, gets a protocol error naming
// which of the two it is rather than an authorization failure from three
// layers down.
func (a *Agent) requireReady() error {
	if !a.Initialized() {
		return Errorf(CodeInvalidRequest, "initialize must come first")
	}
	if !a.Authenticated() {
		return Errorf(CodeAuthRequired,
			"not authenticated for %s — run `fountain auth login`", a.auth.Describe())
	}
	return nil
}
