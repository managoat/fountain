package acp

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

type fakeAuth struct {
	available bool
	verifyErr error
	verifies  int
}

func (f *fakeAuth) Available() bool { return f.available }

func (f *fakeAuth) Verify(context.Context) error {
	f.verifies++
	return f.verifyErr
}

func (f *fakeAuth) Describe() string { return "https://example.test (profile default)" }

// newTestAgent builds an agent with no Fountain agent configured — enough for
// the handshake tests. The session tests build their own with an API.
func newTestAgent(auth Auth) *Agent {
	return NewAgent(auth, &fakeAPI{}, "", "test", discardLogger())
}

func request(t *testing.T, a *Agent, method string, params any) (map[string]any, *Error) {
	t.Helper()

	var raw json.RawMessage
	if params != nil {
		encoded, err := json.Marshal(params)
		if err != nil {
			t.Fatalf("marshal params: %v", err)
		}
		raw = encoded
	}

	result, err := a.Request(context.Background(), method, raw)
	if err != nil {
		var rpcErr *Error
		if !errors.As(err, &rpcErr) {
			t.Fatalf("%s returned a non-protocol error: %v", method, err)
		}
		return nil, rpcErr
	}

	if result == nil {
		return nil, nil
	}
	m, ok := result.(map[string]any)
	if !ok {
		t.Fatalf("%s result is %T, want a map", method, result)
	}
	return m, nil
}

func TestInitializeAnswersWithOurProtocolVersion(t *testing.T) {
	a := newTestAgent(&fakeAuth{available: true})

	result, rpcErr := request(t, a, "initialize", map[string]any{"protocolVersion": ProtocolVersion})
	if rpcErr != nil {
		t.Fatalf("initialize failed: %v", rpcErr)
	}
	if result["protocolVersion"] != ProtocolVersion {
		t.Errorf("protocolVersion = %v, want %d", result["protocolVersion"], ProtocolVersion)
	}
	if !a.Initialized() {
		t.Error("agent did not record that it was initialized")
	}
}

// A client newer than us must be answered with a version we can actually
// speak, not with its own echoed back.
func TestInitializeNegotiatesDownFromANewerClient(t *testing.T) {
	a := newTestAgent(&fakeAuth{})

	result, _ := request(t, a, "initialize", map[string]any{"protocolVersion": ProtocolVersion + 5})
	if result["protocolVersion"] != ProtocolVersion {
		t.Errorf("protocolVersion = %v, want %d", result["protocolVersion"], ProtocolVersion)
	}
}

// ADR 0015: v1 is a control surface, not a workspace. The sprite's files are
// on a different machine from the editor's, and an agent that claims fs or
// terminal capability appears to be editing the open project and is not.
func TestInitializeDeclaresNoWorkspaceCapabilities(t *testing.T) {
	a := newTestAgent(&fakeAuth{available: true})

	result, _ := request(t, a, "initialize", map[string]any{
		"protocolVersion": ProtocolVersion,
		"clientCapabilities": map[string]any{
			"fs":       map[string]any{"readTextFile": true, "writeTextFile": true},
			"terminal": true,
		},
	})

	encoded, err := json.Marshal(result)
	if err != nil {
		t.Fatalf("marshal result: %v", err)
	}
	for _, forbidden := range []string{"readTextFile", "writeTextFile", "terminal"} {
		if strings.Contains(string(encoded), forbidden) {
			t.Errorf("initialize result mentions %q — v1 requests no workspace capabilities: %s", forbidden, encoded)
		}
	}
}

// loadSession obliges the agent to replay the whole conversation before
// answering. Claiming it before that exists (#703) leaves an editor showing an
// empty transcript for a conversation that has one.
func TestInitializeDoesNotClaimCapabilitiesItCannotHonour(t *testing.T) {
	a := newTestAgent(&fakeAuth{available: true})

	result, _ := request(t, a, "initialize", map[string]any{"protocolVersion": ProtocolVersion})

	caps, ok := result["agentCapabilities"].(map[string]any)
	if !ok {
		t.Fatalf("agentCapabilities missing: %v", result)
	}
	// loadSession is a promise about ordering as much as ability: claiming it
	// obliges the agent to replay the whole conversation as session/update
	// notifications BEFORE answering. It went true with #703, which built the
	// replay — see load_test.go.
	if caps["loadSession"] != true {
		t.Errorf("loadSession = %v, want true", caps["loadSession"])
	}
	prompt := caps["promptCapabilities"].(map[string]any)
	if prompt["image"] != true {
		t.Errorf("promptCapabilities.image = %v, want true — the prompt path carries images", prompt["image"])
	}
	// embeddedContext means the editor may inline a local file's contents, and
	// the agent works on a sandbox's filesystem — accepting it would be
	// accepting context about a machine the agent cannot see.
	for _, k := range []string{"audio", "embeddedContext"} {
		if prompt[k] != false {
			t.Errorf("promptCapabilities.%s = %v, want false", k, prompt[k])
		}
	}
}

func TestInitializeOffersLoginWhenThereAreNoCredentials(t *testing.T) {
	a := newTestAgent(&fakeAuth{available: false})

	result, _ := request(t, a, "initialize", map[string]any{"protocolVersion": ProtocolVersion})

	methods, ok := result["authMethods"].([]map[string]any)
	if !ok || len(methods) != 1 {
		t.Fatalf("authMethods = %v, want one method", result["authMethods"])
	}
	if methods[0]["id"] != AuthMethodID {
		t.Errorf("auth method id = %v, want %q", methods[0]["id"], AuthMethodID)
	}
	if !strings.Contains(methods[0]["description"].(string), "managoat auth login") {
		t.Errorf("description = %v, want it to name the command that fixes it", methods[0]["description"])
	}
	if a.Authenticated() {
		t.Error("agent considers itself authenticated with no credentials")
	}
}

// An editor shown a login prompt for a CLI that is already logged in has been
// told something false about its own state.
func TestInitializeOffersNoLoginWhenCredentialsExist(t *testing.T) {
	a := newTestAgent(&fakeAuth{available: true})

	result, _ := request(t, a, "initialize", map[string]any{"protocolVersion": ProtocolVersion})

	if methods := result["authMethods"].([]map[string]any); len(methods) != 0 {
		t.Errorf("authMethods = %v, want none when credentials are present", methods)
	}
	if !a.Authenticated() {
		t.Error("agent should treat present credentials as good enough to proceed")
	}
}

// initialize runs on every editor spawn and must not wait on the network to
// decide whether to show a login prompt.
func TestInitializeDoesNotHitTheNetwork(t *testing.T) {
	auth := &fakeAuth{available: true}
	a := newTestAgent(auth)

	request(t, a, "initialize", map[string]any{"protocolVersion": ProtocolVersion})

	if auth.verifies != 0 {
		t.Errorf("initialize called Verify %d times, want 0", auth.verifies)
	}
}

func TestAuthenticateVerifiesTheCredentials(t *testing.T) {
	auth := &fakeAuth{available: true}
	a := newTestAgent(auth)

	if _, rpcErr := request(t, a, "authenticate", map[string]any{"methodId": AuthMethodID}); rpcErr != nil {
		t.Fatalf("authenticate failed: %v", rpcErr)
	}
	if auth.verifies != 1 {
		t.Errorf("Verify called %d times, want 1", auth.verifies)
	}
	if !a.Authenticated() {
		t.Error("agent did not record a successful authentication")
	}
}

// An editor configured before ADR 0082 may still send the old method id.
func TestAuthenticateAcceptsTheLegacyMethodID(t *testing.T) {
	auth := &fakeAuth{available: true}
	a := newTestAgent(auth)

	if _, rpcErr := request(t, a, "authenticate", map[string]any{"methodId": LegacyAuthMethodID}); rpcErr != nil {
		t.Fatalf("authenticate with %q failed: %v", LegacyAuthMethodID, rpcErr)
	}
	if !a.Authenticated() {
		t.Error("agent did not record a successful authentication")
	}
}

// The message is the whole value of this branch: it is read inside an editor
// by someone who cannot see a 401.
func TestAuthenticateRejectionNamesTheFixAndTheInstance(t *testing.T) {
	auth := &fakeAuth{available: true, verifyErr: errors.New("http 401")}
	a := newTestAgent(auth)

	_, rpcErr := request(t, a, "authenticate", map[string]any{"methodId": AuthMethodID})
	if rpcErr == nil {
		t.Fatal("authenticate accepted credentials the server rejected")
	}
	if rpcErr.Code != CodeAuthRequired {
		t.Errorf("code = %d, want %d", rpcErr.Code, CodeAuthRequired)
	}
	if !strings.Contains(rpcErr.Message, "managoat auth login") {
		t.Errorf("message = %q, want it to name the command that fixes it", rpcErr.Message)
	}
	if !strings.Contains(rpcErr.Message, "example.test") {
		t.Errorf("message = %q, want it to name the instance it tried", rpcErr.Message)
	}
	if a.Authenticated() {
		t.Error("a rejected authentication left the agent authenticated")
	}
}

func TestAuthenticateWithNoCredentialsSaysSo(t *testing.T) {
	auth := &fakeAuth{available: false}
	a := newTestAgent(auth)

	_, rpcErr := request(t, a, "authenticate", map[string]any{"methodId": AuthMethodID})
	if rpcErr == nil || rpcErr.Code != CodeAuthRequired {
		t.Fatalf("want an auth-required error, got %v", rpcErr)
	}
	if auth.verifies != 0 {
		t.Errorf("Verify called %d times with no credentials to verify, want 0", auth.verifies)
	}
}

func TestAuthenticateRejectsAnUnknownMethod(t *testing.T) {
	a := newTestAgent(&fakeAuth{available: true})

	_, rpcErr := request(t, a, "authenticate", map[string]any{"methodId": "oauth"})
	if rpcErr == nil || rpcErr.Code != CodeInvalidParams {
		t.Fatalf("want invalid params for an unknown auth method, got %v", rpcErr)
	}
}

// The remaining session methods are the next issues. Until they exist, saying
// so is better than a silent success an editor would sit and wait on.
func TestSessionMethodsAreNotFoundYet(t *testing.T) {
	a := newTestAgent(&fakeAuth{available: true})

	// session/cancel is a notification, not a request — an editor never sends
	// it with an id, and answering one would be the bug.
	for _, method := range []string{"session/cancel"} {
		_, rpcErr := request(t, a, method, map[string]any{})
		if rpcErr == nil || rpcErr.Code != CodeMethodNotFound {
			t.Errorf("%s: want method-not-found, got %v", method, rpcErr)
		}
	}
}

func TestMalformedParamsAreInvalidParamsNotACrash(t *testing.T) {
	a := newTestAgent(&fakeAuth{available: true})

	_, err := a.Request(context.Background(), "initialize", json.RawMessage(`{"protocolVersion":`))
	var rpcErr *Error
	if !errors.As(err, &rpcErr) || rpcErr.Code != CodeInvalidParams {
		t.Fatalf("want invalid params, got %v", err)
	}
}

// Some clients send initialize with no params at all.
func TestInitializeWithNoParamsStillAnswers(t *testing.T) {
	a := newTestAgent(&fakeAuth{available: true})

	result, rpcErr := request(t, a, "initialize", nil)
	if rpcErr != nil {
		t.Fatalf("initialize with no params failed: %v", rpcErr)
	}
	if result["protocolVersion"] != ProtocolVersion {
		t.Errorf("protocolVersion = %v, want %d", result["protocolVersion"], ProtocolVersion)
	}
}
