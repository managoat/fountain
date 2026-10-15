package acp

import (
	"context"
	"encoding/json"
	"log/slog"
	"sync"
)

// ProtocolVersion is the ACP major version this agent speaks. It matches what
// the server's peer offers downward (Fountain.Runtimes.ACP.initialize_params/0),
// which is not a coincidence worth breaking: Fountain is a proxy, and a
// version it can receive but not re-emit is a translation problem it exists to
// not have.
const ProtocolVersion = 1

// AuthMethodID is the id an editor passes back to `authenticate`.
const AuthMethodID = "managoat-cli-login"

// LegacyAuthMethodID is the id before ADR 0082 renamed the project. An editor
// that remembered it is still answered (managoat/managoat#2776).
const LegacyAuthMethodID = "fountain-cli-login"

// Auth is what the agent needs to know about credentials, split by cost.
//
// Available is a local check — a file read, no network — because it runs
// inside `initialize`, and an editor that waits on a round trip to decide
// whether to show a login prompt feels broken before it has done anything.
// Verify is the network check, and only `authenticate` pays for it.
type Auth interface {
	Available() bool
	Verify(ctx context.Context) error
	// Describe names where the credentials would come from, for log lines
	// and error messages. A wrong-instance or wrong-profile misconfiguration
	// is otherwise invisible from inside an editor.
	Describe() string
}

// Agent handles the ACP methods an editor calls.
//
// v1 is a control surface, not a workspace: it declares no client filesystem
// or terminal capabilities and requests none. A Fountain agent edits a
// sprite's files on a machine that is not the developer's, and ADR 0015 is
// explicit that pretending otherwise "produces an agent that appears to be
// editing the open project and is not". Read-through and workspace sync are
// separate decisions with their own ADRs — they do not arrive through here.
type Agent struct {
	auth Auth
	api  API
	log  *slog.Logger

	// agentTarget is the Fountain agent (name or id) this process opens
	// sessions against. ACP's `session/new` carries a `cwd` and a list of MCP
	// servers but no notion of *which* agent, and the unit an editor is
	// reaching for here is a provisioned Fountain agent — an environment,
	// vault overrides, skills, MCP servers and inference credentials that
	// never touch the developer's machine. So the choice is made where the
	// editor already configures things: one agent-server entry per agent,
	// `managoat acp --agent <name-or-id>`. Carrying it in `session/new`'s
	// `_meta` instead would put the decision in a field most clients do not
	// surface, and a default in the credentials file would make two editors
	// on one machine fight over it.
	agentTarget string

	// version is what `agentInfo` reports. Injected rather than read from a
	// constant here so the protocol layer does not depend on the CLI package.
	version string

	sessions *sessions

	mu            sync.Mutex
	notifier      Notifier
	initialized   bool
	authenticated bool
	negotiated    int
}

// NewAgent returns an agent bound to a credential source, the Fountain API,
// the agent sessions open against, and the version it reports as `agentInfo`.
func NewAgent(auth Auth, api API, agentTarget, version string, log *slog.Logger) *Agent {
	return &Agent{
		auth:        auth,
		api:         api,
		agentTarget: agentTarget,
		version:     version,
		sessions:    newSessions(),
		log:         log,
	}
}

type initializeParams struct {
	ProtocolVersion    int             `json:"protocolVersion"`
	ClientCapabilities json.RawMessage `json:"clientCapabilities"`
}

type authenticateParams struct {
	MethodID string `json:"methodId"`
}

// Request dispatches one ACP method.
func (a *Agent) Request(ctx context.Context, method string, params json.RawMessage) (any, error) {
	switch method {
	case "initialize":
		return a.initialize(params)
	case "authenticate":
		return a.authenticate(ctx, params)
	case "session/new":
		return a.newSession(ctx, params)
	case "session/prompt":
		return a.prompt(ctx, params)
	case "session/load":
		return a.loadSession(ctx, params)
	case "session/set_config_option":
		return a.setConfigOption(params)
	default:
		return nil, Errorf(CodeMethodNotFound, "method not found: %s", method)
	}
}

type setConfigOptionParams struct {
	SessionID string          `json:"sessionId"`
	ConfigID  string          `json:"configId"`
	Value     json.RawMessage `json:"value"`
}

// setConfigOption accepts a client's request to change a session config option
// — but does not apply it, and does not pretend to. Every option a Fountain
// conversation has, its model above all, is a property of the *agent*: chosen
// server-side and copied onto each conversation when it launches. The server
// refuses session_config on a conversation and on a prompt (ADR 0062, addendum
// of 2026-10-15, agent only). Changing it here would silently edit the agent,
// which is why `session/set_model` is absent too (see modelState) and why
// `session/new` advertises no `configOptions`: there is nothing a client can
// set.
//
// The method exists rather than returning "method not found" because some ACP
// clients push session controls at spawn and treat any rejection as fatal.
// OpenClaw's acpx pushes the model its brain chose over
// `session/set_config_option` (and, derived from that model, a `thinking`
// level) and aborts the whole turn on a -32601 here — found standing up the
// gateway round trip (#759, #760).
//
// The reply carries no `configOptions` list, deliberately. acpx narrows the
// set of controls it will send to whatever list the last reply advertised
// (`applyConfigOptionsToState` → `resolveSupportedConfigOptionId`), so echoing
// the honest list — empty, or the fixed model alone — makes the *next* control
// (`thinking`) fail with "does not advertise config option" and the turn dies
// anyway. Saying nothing keeps acpx in its "not advertised, try it" mode, every
// push lands here, and the agent's configuration stays authoritative. The
// `_meta` block says so in as many words for a client that reads it.
func (a *Agent) setConfigOption(raw json.RawMessage) (any, error) {
	var params setConfigOptionParams
	if len(raw) > 0 {
		if err := json.Unmarshal(raw, &params); err != nil {
			return nil, Errorf(CodeInvalidParams, "session/set_config_option: %s", err)
		}
	}

	if _, ok := a.sessions.get(params.SessionID); !ok {
		return nil, Errorf(CodeInvalidParams, "unknown session %q", params.SessionID)
	}

	a.log.Info("ignoring client session config change",
		"sessionId", params.SessionID,
		"configId", params.ConfigID,
		"value", string(params.Value),
		"why", "session options are properties of the Managoat agent, not the conversation")

	return map[string]any{
		"_meta": map[string]any{
			"managoat": map[string]any{
				"applied":  false,
				"configId": params.ConfigID,
				"reason":   "session options are properties of the Managoat agent; change them on the agent",
			},
		},
	}, nil
}

// Notify handles client notifications.
//
// `session/cancel` is a notification, not a request: ACP expects the *pending*
// `session/prompt` to be what answers, with a `cancelled` stop reason. So this
// asks the server to stop the turn and returns; the prompt's own follow sees
// the interrupted stage and reports it.
func (a *Agent) Notify(ctx context.Context, method string, params json.RawMessage) {
	switch method {
	case "session/cancel":
		a.cancel(ctx, params)
	default:
		a.log.Debug("ignoring notification", "method", method)
	}
}

func (a *Agent) initialize(raw json.RawMessage) (any, error) {
	var params initializeParams
	if len(raw) > 0 {
		if err := json.Unmarshal(raw, &params); err != nil {
			return nil, Errorf(CodeInvalidParams, "initialize: %s", err)
		}
	}

	// The protocol negotiates down: answer with the highest version both ends
	// speak. There is no floor to refuse below yet, because ProtocolVersion is
	// also the oldest version that exists — when a v2 ships, the refusal for a
	// client below our floor belongs here, not in the session methods, where
	// it would surface as a mid-conversation failure.
	negotiated := params.ProtocolVersion
	if negotiated <= 0 || negotiated > ProtocolVersion {
		negotiated = ProtocolVersion
	}

	// The client's params are logged whole and stored not at all. Whatever it
	// offers — fs/read_text_file, terminals — v1 uses none of it, and this
	// line is what makes that visible when an editor asks why its
	// capabilities were ignored.
	a.log.Info("initialize",
		"protocolVersion", negotiated,
		"params", string(raw),
		"credentials", a.auth.Describe())

	authenticated := a.auth.Available()

	a.mu.Lock()
	a.initialized = true
	a.negotiated = negotiated
	// Holding credentials is not proof they work — `authenticate` is what
	// verifies them. It is proof we should not ask the editor to log in.
	a.authenticated = authenticated
	a.mu.Unlock()

	return map[string]any{
		"protocolVersion":   negotiated,
		"agentInfo":         agentInfo(a.version),
		"agentCapabilities": agentCapabilities(),
		"authMethods":       authMethods(authenticated),
	}, nil
}

// agentInfo names the implementation. The spec says an agent SHOULD send it
// and that it becomes required in a future version — and a client that does
// not get it has nothing to call us but "unknown", which is what it then shows
// its user when anything goes wrong.
func agentInfo(version string) map[string]any {
	if version == "" {
		version = "dev"
	}
	return map[string]any{
		"name":    "managoat",
		"title":   "Managoat",
		"version": version,
	}
}

// agentCapabilities is deliberately the smallest honest set.
//
// loadSession is true because the replay exists (#703): the conversation's
// stored `session/update` notifications are re-emitted before the response.
// The capability is a promise about ordering as much as ability, which is why
// it was false until the drain was written.
//
// `image` is true because the prompt path carries images to the API, which has
// taken them since before this adapter existed. `embeddedContext` stays false:
// it means the editor may inline a local file's contents, and this agent works
// on a sandbox's filesystem, so accepting them would be accepting context
// about a machine the agent cannot see.
func agentCapabilities() map[string]any {
	return map[string]any{
		"loadSession": true,
		"promptCapabilities": map[string]any{
			"image":           true,
			"audio":           false,
			"embeddedContext": false,
		},
	}
}

// authMethods advertises the one way in, and only when it is needed. An
// editor shown a login prompt for a CLI that is already logged in has been
// told something false about its own state.
func authMethods(authenticated bool) []map[string]any {
	if authenticated {
		return []map[string]any{}
	}
	return []map[string]any{{
		"id":          AuthMethodID,
		"name":        "Managoat CLI login",
		"description": "Run `managoat auth login` in a terminal, then retry.",
	}}
}

func (a *Agent) authenticate(ctx context.Context, raw json.RawMessage) (any, error) {
	var params authenticateParams
	if len(raw) > 0 {
		if err := json.Unmarshal(raw, &params); err != nil {
			return nil, Errorf(CodeInvalidParams, "authenticate: %s", err)
		}
	}
	if params.MethodID != "" && params.MethodID != AuthMethodID && params.MethodID != LegacyAuthMethodID {
		return nil, Errorf(CodeInvalidParams, "unknown auth method %q", params.MethodID)
	}

	if !a.auth.Available() {
		return nil, Errorf(CodeAuthRequired,
			"no credentials for %s — run `managoat auth login`", a.auth.Describe())
	}

	if err := a.auth.Verify(ctx); err != nil {
		// The message is the whole value of this branch: it is read inside an
		// editor by someone who cannot see a 401.
		return nil, Errorf(CodeAuthRequired,
			"credentials for %s were rejected (%s) — run `managoat auth login`",
			a.auth.Describe(), err)
	}

	a.mu.Lock()
	a.authenticated = true
	a.mu.Unlock()

	a.log.Info("authenticated", "credentials", a.auth.Describe())
	return nil, nil
}

// Authenticated reports whether the session may call the session methods.
// The session methods do not exist yet; this is what they will gate on.
func (a *Agent) Authenticated() bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.authenticated
}

// Initialized reports whether `initialize` has completed.
func (a *Agent) Initialized() bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.initialized
}
