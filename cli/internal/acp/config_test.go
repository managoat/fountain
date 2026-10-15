package acp

import (
	"errors"
	"reflect"
	"strings"
	"testing"
)

func setOption(t *testing.T, a *Agent, sessionID, id string, value any) (map[string]any, *Error) {
	t.Helper()
	return request(t, a, "session/set_config_option", map[string]any{
		"sessionId": sessionID,
		"configId":  id,
		"value":     value,
	})
}

func turnDone() []Event {
	return []Event{stageEvent("turn", "done", `{"stop_reason":"end_turn"}`)}
}

// The bug in #2663: the choice was acknowledged and dropped. It now rides on
// every following prompt, because the server applies a prompt's
// session_config to that turn only.
func TestSetConfigOptionIsSentWithEveryFollowingPrompt(t *testing.T) {
	api := &fakeAPI{events: turnDone()}
	a, _ := promptAgent(t, api)

	if _, rpcErr := request(t, a, "session/prompt", textPrompt("conv-1", "before")); rpcErr != nil {
		t.Fatalf("session/prompt failed: %v", rpcErr)
	}
	if _, rpcErr := setOption(t, a, "conv-1", "effort", "high"); rpcErr != nil {
		t.Fatalf("set_config_option failed: %v", rpcErr)
	}
	if _, rpcErr := setOption(t, a, "conv-1", "fast", true); rpcErr != nil {
		t.Fatalf("set_config_option failed: %v", rpcErr)
	}
	for _, text := range []string{"one", "two"} {
		if _, rpcErr := request(t, a, "session/prompt", textPrompt("conv-1", text)); rpcErr != nil {
			t.Fatalf("session/prompt failed: %v", rpcErr)
		}
	}
	if _, rpcErr := setOption(t, a, "conv-1", "effort", "low"); rpcErr != nil {
		t.Fatalf("set_config_option failed: %v", rpcErr)
	}
	if _, rpcErr := request(t, a, "session/prompt", textPrompt("conv-1", "three")); rpcErr != nil {
		t.Fatalf("session/prompt failed: %v", rpcErr)
	}

	want := []map[string]any{
		nil,
		{"effort": "high", "fast": true},
		{"effort": "high", "fast": true},
		{"effort": "low", "fast": true},
	}
	if len(api.prompts) != len(want) {
		t.Fatalf("sent %d prompts, want %d", len(api.prompts), len(want))
	}
	for i, p := range api.prompts {
		if !reflect.DeepEqual(p.sessionConfig, want[i]) {
			t.Errorf("prompt %d session_config = %#v, want %#v", i, p.sessionConfig, want[i])
		}
	}
}

// Options are per session: two sessions on one connection do not share them.
func TestSetConfigOptionIsPerSession(t *testing.T) {
	api := &fakeAPI{events: turnDone(), convID: "conv-a"}
	a, _ := promptAgent(t, api)
	api.convID = "conv-b"
	if _, rpcErr := request(t, a, "session/new", map[string]any{}); rpcErr != nil {
		t.Fatalf("session/new failed: %v", rpcErr)
	}

	if _, rpcErr := setOption(t, a, "conv-a", "effort", "high"); rpcErr != nil {
		t.Fatalf("set_config_option failed: %v", rpcErr)
	}
	if _, rpcErr := request(t, a, "session/prompt", textPrompt("conv-b", "hi")); rpcErr != nil {
		t.Fatalf("session/prompt failed: %v", rpcErr)
	}
	if got := api.prompts[0].sessionConfig; got != nil {
		t.Errorf("conv-b session_config = %#v, want none", got)
	}
}

// Before the first turn the server has no option list. The reply then leaves
// configOptions out: acpx narrows the controls it pushes to the last list it
// was shown, so an invented list would fail its next push (#760).
func TestSetConfigOptionBeforeTheServerHasAListAdvertisesNone(t *testing.T) {
	api := &fakeAPI{}
	a, _ := promptAgent(t, api)

	result, rpcErr := setOption(t, a, "conv-1", "thinking", "medium")
	if rpcErr != nil {
		t.Fatalf("set_config_option failed: %v", rpcErr)
	}
	if _, present := result["configOptions"]; present {
		t.Errorf("configOptions = %#v, want the key absent", result["configOptions"])
	}
}

// Once a turn has run, the reply is the option state ACP asks for: the
// adapter's list, with the values this session set as current values.
func TestSetConfigOptionRepliesWithTheUpdatedOptionState(t *testing.T) {
	api := &fakeAPI{configOptions: []map[string]any{
		{"id": "effort", "type": "select", "currentValue": "medium", "options": []any{
			map[string]any{"value": "low"}, map[string]any{"value": "medium"}, map[string]any{"value": "high"},
		}},
		{"id": "fast", "type": "boolean", "currentValue": false},
		// A server from before managoat_acp 0.6.0 still listed the mode.
		{"id": "mode", "type": "select", "currentValue": "default"},
	}}
	a, _ := promptAgent(t, api)

	result, rpcErr := setOption(t, a, "conv-1", "effort", "high")
	if rpcErr != nil {
		t.Fatalf("set_config_option failed: %v", rpcErr)
	}

	options, ok := result["configOptions"].([]map[string]any)
	if !ok {
		t.Fatalf("configOptions = %#v, want a list", result["configOptions"])
	}
	got := map[string]any{}
	for _, o := range options {
		got[o["id"].(string)] = o["currentValue"]
	}
	want := map[string]any{"effort": "high", "fast": false}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("current values = %#v, want %#v (mode left out)", got, want)
	}
	if api.configOptions[0]["currentValue"] != "medium" {
		t.Error("the reply modified the API's list instead of a copy")
	}
}

// A failed lookup must not fail the request: the choice is recorded anyway.
func TestSetConfigOptionSurvivesAFailedOptionLookup(t *testing.T) {
	api := &fakeAPI{events: turnDone(), configOptionsErr: errors.New("http 500")}
	a, _ := promptAgent(t, api)

	result, rpcErr := setOption(t, a, "conv-1", "effort", "high")
	if rpcErr != nil {
		t.Fatalf("set_config_option failed: %v", rpcErr)
	}
	if _, present := result["configOptions"]; present {
		t.Errorf("configOptions = %#v, want the key absent", result["configOptions"])
	}
	request(t, a, "session/prompt", textPrompt("conv-1", "go"))
	if got := api.prompts[0].sessionConfig; !reflect.DeepEqual(got, map[string]any{"effort": "high"}) {
		t.Errorf("session_config = %#v, want effort high", got)
	}
}

// A client that pushes a model — as OpenClaw's acpx does at every spawn — must
// not get an error: acpx aborts the turn on one (#759). The server refuses
// model in session_config, so it is acknowledged, not applied, and not sent.
func TestSetConfigOptionAcceptsAModelPushWithoutApplyingIt(t *testing.T) {
	api := &fakeAPI{events: turnDone()}
	a, _ := promptAgent(t, api)

	result, rpcErr := setOption(t, a, "conv-1", "model", "anthropic/claude-something-else")
	if rpcErr != nil {
		t.Fatalf("set_config_option returned an error: %v", rpcErr)
	}
	if _, present := result["configOptions"]; present {
		t.Errorf("configOptions = %#v, want the key absent before the server has a list", result["configOptions"])
	}
	meta, _ := result["_meta"].(map[string]any)
	fountainMeta, _ := meta["fountain"].(map[string]any)
	if got := fountainMeta["applied"]; got != false {
		t.Errorf("_meta.fountain.applied = %v, want false", got)
	}

	request(t, a, "session/prompt", textPrompt("conv-1", "go"))
	if got := api.prompts[0].sessionConfig; got != nil {
		t.Errorf("session_config = %#v, want none (model is not forwarded)", got)
	}
}

// The permission mode follows the agent's policy; the server refuses it, and
// so does the bridge, in words, before a prompt carries it.
func TestSetConfigOptionRefusesThePermissionModes(t *testing.T) {
	for _, id := range []string{"mode", "collaboration_mode"} {
		t.Run(id, func(t *testing.T) {
			api := &fakeAPI{events: turnDone()}
			a, _ := promptAgent(t, api)

			_, rpcErr := setOption(t, a, "conv-1", id, "bypassPermissions")
			if rpcErr == nil || rpcErr.Code != CodeInvalidParams {
				t.Fatalf("got %v, want CodeInvalidParams", rpcErr)
			}
			if !strings.Contains(rpcErr.Message, "permission") {
				t.Errorf("message = %q, want it to say why", rpcErr.Message)
			}
			request(t, a, "session/prompt", textPrompt("conv-1", "go"))
			if got := api.prompts[0].sessionConfig; got != nil {
				t.Errorf("session_config = %#v, want none", got)
			}
		})
	}
}

// The server's shape rules, checked where the editor can show the error.
func TestSetConfigOptionChecksTheServersShape(t *testing.T) {
	for _, tc := range []struct {
		name  string
		id    string
		value any
		ok    bool
		want  any
	}{
		{name: "select value", id: "reasoning_effort", value: "high", ok: true, want: "high"},
		{name: "bare boolean", id: "fast-mode", value: true, ok: true, want: true},
		{name: "boolean object", id: "fast", value: map[string]any{"type": "boolean", "value": false}, ok: true, want: false},
		{name: "empty string", id: "effort", value: ""},
		{name: "too long", id: "effort", value: strings.Repeat("x", maxConfigValueLength+1)},
		{name: "number", id: "effort", value: 3},
		{name: "null", id: "effort", value: nil},
		{name: "bad id", id: "-effort", value: "high"},
		{name: "empty id", id: "", value: "high"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			api := &fakeAPI{events: turnDone()}
			a, _ := promptAgent(t, api)

			_, rpcErr := setOption(t, a, "conv-1", tc.id, tc.value)
			if !tc.ok {
				if rpcErr == nil || rpcErr.Code != CodeInvalidParams {
					t.Fatalf("got %v, want CodeInvalidParams", rpcErr)
				}
				return
			}
			if rpcErr != nil {
				t.Fatalf("set_config_option failed: %v", rpcErr)
			}
			request(t, a, "session/prompt", textPrompt("conv-1", "go"))
			if got := api.prompts[0].sessionConfig[tc.id]; !reflect.DeepEqual(got, tc.want) {
				t.Errorf("session_config[%s] = %#v, want %#v", tc.id, got, tc.want)
			}
		})
	}
}

func TestSetConfigOptionCapsTheNumberOfOptions(t *testing.T) {
	api := &fakeAPI{}
	a, _ := promptAgent(t, api)

	for i := range maxConfigOptions {
		if _, rpcErr := setOption(t, a, "conv-1", "opt"+string(rune('a'+i)), "v"); rpcErr != nil {
			t.Fatalf("option %d refused: %v", i, rpcErr)
		}
	}
	if _, rpcErr := setOption(t, a, "conv-1", "one-too-many", "v"); rpcErr == nil {
		t.Fatal("expected the option beyond the limit to be refused")
	}
	// Changing one already set is not a new option.
	if _, rpcErr := setOption(t, a, "conv-1", "opta", "w"); rpcErr != nil {
		t.Fatalf("changing a set option was refused: %v", rpcErr)
	}
}

func TestSetConfigOptionOnAnUnknownSessionIsRefused(t *testing.T) {
	api := &fakeAPI{ref: acpAgentRef(), convID: "conv-9"}
	a := sessionAgent(t, api, "researcher")

	_, rpcErr := setOption(t, a, "nope", "effort", "high")
	if rpcErr == nil {
		t.Fatal("expected an error for an unknown session")
	}
	if rpcErr.Code != CodeInvalidParams {
		t.Errorf("code = %d, want CodeInvalidParams (%d)", rpcErr.Code, CodeInvalidParams)
	}
}

// The sprite's adapter lists the permission modes in its own updates. An
// editor offered one would only have the bridge refuse it, so they are not
// forwarded.
func TestConfigOptionUpdatesLoseThePermissionModes(t *testing.T) {
	line := `{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sprite","update":{` +
		`"sessionUpdate":"config_option_update","configOptions":[` +
		`{"id":"mode","currentValue":"default"},{"id":"effort","currentValue":"high"}]}}}`
	api := &fakeAPI{events: []Event{
		{Kind: "output", Stream: "acp", Data: line},
		stageEvent("turn", "done", `{"stop_reason":"end_turn"}`),
	}}
	a, notifier := promptAgent(t, api)

	if _, rpcErr := request(t, a, "session/prompt", textPrompt("conv-1", "go")); rpcErr != nil {
		t.Fatalf("session/prompt failed: %v", rpcErr)
	}
	if len(notifier.params) != 1 {
		t.Fatalf("notifications = %d, want 1", len(notifier.params))
	}
	update := notifier.params[0]["update"].(map[string]any)
	options := update["configOptions"].([]any)
	if len(options) != 1 || options[0].(map[string]any)["id"] != "effort" {
		t.Errorf("configOptions = %#v, want effort alone", options)
	}
}
