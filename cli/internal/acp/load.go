package acp

import (
	"context"
	"encoding/json"
)

type loadSessionParams struct {
	SessionID string `json:"sessionId"`
}

// loadSession reopens a conversation this process did not start.
//
// This is the reason ADR 0015 gives for reaching past a local agent at all:
// the work outlives the editor. Close the laptop mid-turn, reopen tomorrow,
// and the transcript is still there — because it was never in the editor, or
// in this process. It is also why the ACP session id is the conversation id
// (#699): an editor hands back an id from last week, and a minted one would
// resolve to a map that died with the process that made it.
//
// ACP requires the whole conversation to be replayed as `session/update`
// notifications **before** this responds. Two details make that true rather
// than nearly true:
//
//   - The replay is a drain, not a follow: it reads what is stored and stops.
//     Waiting for live events would hold the response open for as long as the
//     conversation stays interesting.
//   - The notifications are written before the response because the handler
//     writes them before it returns, and the connection serialises writes. We
//     answered a `session/load` early once already, on the other side of this
//     protocol — gemini's floating replay cost us #657/#661. Being the agent
//     rather than the client is no reason to repeat it.
func (a *Agent) loadSession(ctx context.Context, raw json.RawMessage) (any, error) {
	var params loadSessionParams
	if len(raw) > 0 {
		if err := json.Unmarshal(raw, &params); err != nil {
			return nil, Errorf(CodeInvalidParams, "session/load: %s", err)
		}
	}

	if err := a.requireReady(); err != nil {
		return nil, err
	}
	if params.SessionID == "" {
		return nil, Errorf(CodeInvalidParams, "session/load: no sessionId")
	}

	conv, err := a.api.Conversation(ctx, params.SessionID)
	if err != nil {
		return nil, Errorf(CodeInvalidParams,
			"could not open session %q on %s: %s", params.SessionID, a.auth.Describe(), err)
	}

	// Every runtime speaks ACP, so there is no runtime to refuse (#2430). A
	// conversation recorded before ACP has its transcript on `stdout` and
	// replays as an empty session here; that transcript is web-only.
	sess := Session{
		ID:    conv.ID,
		Agent: AgentRef{Name: conv.Agent, Runtime: conv.Runtime, Model: conv.Model},
	}
	a.sessions.put(sess)

	replayed := 0
	err = a.api.Replay(ctx, conv.ID, func(ev Event) (bool, error) {
		if ev.Kind == "output" && ev.Stream == "acp" {
			a.forwardUpdate(sess, ev.Data)
			replayed++
		}
		return false, nil
	})
	if err != nil {
		return nil, Errorf(CodeInternalError,
			"could not replay session %q: %s", conv.ID, err)
	}

	// A conversation whose sandbox was reclaimed replays in full while the
	// agent inside remembers none of it (#649). The transcript above is real;
	// the continuity is not, and this adapter has no honest way to say so in
	// the protocol — inventing an agent message to explain it would be worse
	// than the log line.
	a.log.Info("session loaded",
		"sessionId", conv.ID,
		"runtime", conv.Runtime,
		"status", conv.Status,
		"updates_replayed", replayed)

	return map[string]any{"models": modelState(sess.Agent)}, nil
}
