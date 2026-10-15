package acp

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"unicode/utf8"
)

// The limits the server puts on a prompt's `session_config`
// (Fountain.Agents.SessionConfig). Checked here as well so a bad option is a
// `session/set_config_option` error the editor shows next to the control the
// user touched, not a refused `session/prompt` on every turn after it.
const (
	maxConfigOptions     = 16
	maxConfigValueLength = 200
)

var configIDPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$`)

// harnessModeIDs are the option ids that set the runtime's permission mode.
// The server refuses them in every `session_config` and leaves them out of
// the options it offers (ADR 0062, addendum of 2026-10-14): the permission
// mode follows the conversation's permission policy, which a launch may
// narrow and never widen, and a prompt must not widen it either.
var harnessModeIDs = map[string]bool{"mode": true, "collaboration_mode": true}

type setConfigOptionParams struct {
	SessionID string          `json:"sessionId"`
	ConfigID  string          `json:"configId"`
	Value     json.RawMessage `json:"value"`
}

// setConfigOption records a client's choice for a session config option and
// sends it as `session_config` on every following `session/prompt` until the
// client changes it (ADR 0062). The server applies a prompt's options to that
// turn only, so the choice has to ride on each prompt to stay in force; that
// also means it never edits the agent or the conversation, which every other
// conversation and client would see.
//
// Three ids are not forwarded:
//
//   - `model` is accepted and not applied. The server refuses it in
//     session_config: a conversation's model is its agent's, or one the API
//     fixed at launch (ADR 0061). It is accepted rather than refused because
//     OpenClaw's acpx pushes the model its brain chose at every spawn and
//     aborts the turn on any error (#759, #760). The reply's
//     `_meta.fountain.applied: false` says so.
//   - `mode` and `collaboration_mode` are refused with an error naming why,
//     as the server refuses them.
//
// The reply carries the option state ACP asks for, `configOptions`, when the
// server has it: the options the adapter advertised before the conversation's
// latest prompt, with the values this client set as their current values.
// Before the first turn the server has no list, and the reply leaves the key
// out rather than inventing one. acpx narrows the controls it will push to
// the list the last reply advertised, so a made-up list (empty, or only the
// ids pushed so far) would fail its next push and the turn with it (#760).
func (a *Agent) setConfigOption(ctx context.Context, raw json.RawMessage) (any, error) {
	var params setConfigOptionParams
	if len(raw) > 0 {
		if err := json.Unmarshal(raw, &params); err != nil {
			return nil, Errorf(CodeInvalidParams, "session/set_config_option: %s", err)
		}
	}

	sess, ok := a.sessions.get(params.SessionID)
	if !ok {
		return nil, Errorf(CodeInvalidParams, "unknown session %q", params.SessionID)
	}

	id := params.ConfigID
	switch {
	case id == "model":
		a.log.Info("ignoring a client model change",
			"sessionId", sess.ID,
			"value", string(params.Value),
			"why", "a conversation runs its agent's model, or one fixed at launch")
		result := a.configOptionState(ctx, sess.ID)
		result["_meta"] = map[string]any{
			"fountain": map[string]any{
				"applied":  false,
				"configId": id,
				"reason":   "a conversation runs its Fountain agent's model, or one the API set at launch; change it there",
			},
		}
		return result, nil

	case harnessModeIDs[id]:
		return nil, Errorf(CodeInvalidParams,
			"session/set_config_option: cannot set %s: the runtime's permission mode follows the "+
				"Fountain agent's permission policy, which a session may narrow (fountain acp "+
				"--permission) and never widen", id)

	case !configIDPattern.MatchString(id):
		return nil, Errorf(CodeInvalidParams,
			"session/set_config_option: invalid option id %q", id)
	}

	value, err := configValue(params.Value)
	if err != nil {
		return nil, Errorf(CodeInvalidParams, "session/set_config_option: option %s %s", id, err)
	}

	if err := a.sessions.setConfig(sess.ID, id, value); err != nil {
		return nil, err
	}

	a.log.Info("session config option set; it goes with each following prompt",
		"sessionId", sess.ID, "configId", id, "value", value)

	return a.configOptionState(ctx, sess.ID), nil
}

// configValue reads an option value as the server takes it: a string of 1 to
// 200 characters, or a boolean. ACP sends a select's value as its id, a
// string, and a boolean option's either as a bare boolean or as
// `{"type": "boolean", "value": true}`.
func configValue(raw json.RawMessage) (any, error) {
	var v any
	if err := json.Unmarshal(raw, &v); err != nil || len(raw) == 0 {
		return nil, errors.New("has no value")
	}

	if obj, ok := v.(map[string]any); ok {
		if b, isBool := obj["value"].(bool); isBool && obj["type"] == "boolean" {
			return b, nil
		}
		v = obj["value"]
	}

	switch val := v.(type) {
	case bool:
		return val, nil
	case string:
		if n := utf8.RuneCountInString(val); n < 1 || n > maxConfigValueLength || strings.ContainsRune(val, 0) {
			return nil, fmt.Errorf(
				"must be a string of 1 to %d characters or a boolean", maxConfigValueLength)
		}
		return val, nil
	default:
		return nil, fmt.Errorf(
			"must be a string of 1 to %d characters or a boolean", maxConfigValueLength)
	}
}

// configOptionState is a `session/set_config_option` reply: the server's
// option list with this session's choices as current values, or no list when
// the server has none yet (see setConfigOption). A failed lookup is logged
// and treated as no list: the choice is recorded either way, and failing the
// request would make acpx abort the turn.
func (a *Agent) configOptionState(ctx context.Context, sessionID string) map[string]any {
	result := map[string]any{}

	options, known, err := a.api.ConfigOptions(ctx, sessionID)
	if err != nil {
		a.log.Warn("could not read the conversation's config options; replying without them",
			"sessionId", sessionID, "err", err)
		return result
	}
	if !known {
		return result
	}

	chosen := a.sessions.sessionConfig(sessionID)
	list := make([]map[string]any, 0, len(options))
	for _, opt := range options {
		optID, _ := opt["id"].(string)
		if harnessModeIDs[optID] {
			// A server from before managoat_acp 0.6.0 still listed them.
			continue
		}
		out := make(map[string]any, len(opt))
		for k, v := range opt {
			out[k] = v
		}
		if v, ok := chosen[optID]; ok {
			out["currentValue"] = v
		}
		list = append(list, out)
	}
	result["configOptions"] = list
	return result
}
