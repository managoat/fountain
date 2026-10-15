package acp

import (
	"strings"
	"testing"
)

// Buzz refused an agent with "unknown reported no models. Check that the CLI
// is installed and signed in" — a true sentence about a different problem. Two
// fields were missing: `agentInfo` (so the client had nothing to call us but
// "unknown") and a session model list (so it concluded there was nothing to
// run). Both are things the spec says an agent SHOULD send and we did not.
func TestInitializeIdentifiesTheAgent(t *testing.T) {
	a := NewAgent(&fakeAuth{available: true}, &fakeAPI{}, "", "v0.9.0", discardLogger())

	result, rpcErr := request(t, a, "initialize", map[string]any{"protocolVersion": ProtocolVersion})
	if rpcErr != nil {
		t.Fatalf("initialize failed: %v", rpcErr)
	}

	info, ok := result["agentInfo"].(map[string]any)
	if !ok {
		t.Fatalf("no agentInfo in the initialize response: %v", result)
	}
	if info["name"] != "managoat" {
		t.Errorf("agentInfo.name = %v, want managoat", info["name"])
	}
	if info["version"] != "v0.9.0" {
		t.Errorf("agentInfo.version = %v, want the build's version", info["version"])
	}
}

// A source build has no stamped version. Reporting an empty string is worse
// than reporting "dev": a client showing "Fountain " with a blank version has
// been told something confusing rather than something honest.
func TestAgentInfoVersionFallsBackToDev(t *testing.T) {
	a := NewAgent(&fakeAuth{available: true}, &fakeAPI{}, "", "", discardLogger())

	result, _ := request(t, a, "initialize", map[string]any{"protocolVersion": ProtocolVersion})

	info := result["agentInfo"].(map[string]any)
	if info["version"] != "dev" {
		t.Errorf("agentInfo.version = %v, want dev for an unstamped build", info["version"])
	}
}

func TestNewSessionReportsTheAgentsModel(t *testing.T) {
	api := &fakeAPI{
		ref:    AgentRef{ID: "a1", Name: "philosoraptor", Runtime: "claude", Model: "anthropic/claude-sonnet-4-6"},
		convID: "conv-1",
	}
	a := sessionAgent(t, api, "philosoraptor")

	result, rpcErr := request(t, a, "session/new", map[string]any{})
	if rpcErr != nil {
		t.Fatalf("session/new failed: %v", rpcErr)
	}

	models, ok := result["models"].(map[string]any)
	if !ok {
		t.Fatalf("session/new reported no models: %v", result)
	}
	if models["currentModelId"] != "anthropic/claude-sonnet-4-6" {
		t.Errorf("currentModelId = %v, want the agent's model", models["currentModelId"])
	}

	available, ok := models["availableModels"].([]map[string]any)
	if !ok || len(available) != 1 {
		t.Fatalf("availableModels = %v, want exactly the agent's model", models["availableModels"])
	}
	if available[0]["modelId"] != "anthropic/claude-sonnet-4-6" {
		t.Errorf("availableModels[0].modelId = %v", available[0]["modelId"])
	}
	// The description is where a user learns why there is only one and where
	// to change it — the picker itself cannot.
	if !strings.Contains(available[0]["description"].(string), "philosoraptor") {
		t.Errorf("description = %v, want it to name the agent", available[0]["description"])
	}
}

// An agent with no model set runs the runtime's default. An empty list would
// read as "this agent cannot run anything", which is how we got here.
func TestASessionAlwaysReportsAtLeastOneModel(t *testing.T) {
	api := &fakeAPI{
		ref:    AgentRef{ID: "a1", Name: "no-model", Runtime: "claude"},
		convID: "conv-1",
	}
	a := sessionAgent(t, api, "no-model")

	result, _ := request(t, a, "session/new", map[string]any{})

	models := result["models"].(map[string]any)
	if models["currentModelId"] != "default" {
		t.Errorf("currentModelId = %v, want a stand-in rather than empty", models["currentModelId"])
	}
	if len(models["availableModels"].([]map[string]any)) != 1 {
		t.Error("an agent with no model configured reported an empty model list")
	}
}

// A reopened session has to look the same to the client as a fresh one, or the
// model picker disappears on reload.
func TestLoadedSessionReportsItsModelToo(t *testing.T) {
	api := &fakeAPI{
		conversation: ConversationRef{
			ID: "conv-9", Runtime: "claude", Status: "idle",
			Agent: "philosoraptor", Model: "anthropic/claude-sonnet-4-6",
		},
	}
	a, _ := loadAgent(t, api)

	result, rpcErr := request(t, a, "session/load", map[string]any{"sessionId": "conv-9"})
	if rpcErr != nil {
		t.Fatalf("session/load failed: %v", rpcErr)
	}

	models, ok := result["models"].(map[string]any)
	if !ok {
		t.Fatalf("session/load reported no models: %v", result)
	}
	if models["currentModelId"] != "anthropic/claude-sonnet-4-6" {
		t.Errorf("currentModelId = %v, want the conversation's agent's model", models["currentModelId"])
	}
}

// Switching models would mean editing the Fountain agent, which every other
// conversation on it shares. Saying so beats accepting a change we would not
// make.
func TestSetModelIsNotOffered(t *testing.T) {
	api := &fakeAPI{ref: acpAgentRef(), convID: "conv-1"}
	a := sessionAgent(t, api, "researcher")
	request(t, a, "session/new", map[string]any{})

	_, rpcErr := request(t, a, "session/set_model", map[string]any{
		"sessionId": "conv-1", "modelId": "anthropic/claude-opus-4-7",
	})
	if rpcErr == nil || rpcErr.Code != CodeMethodNotFound {
		t.Fatalf("want method-not-found for session/set_model, got %v", rpcErr)
	}
}
