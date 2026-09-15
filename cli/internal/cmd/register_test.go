package cmd

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// The verification wait, against the exact JSON the server sends and a clock
// that does not tick. Every sleep is recorded instead of taken, so the whole
// ten-minute schedule runs in microseconds — and the durations themselves are
// asserted, because the schedule is the part that has to respect the server's
// rate limit rather than the part that has to look nice.

type fakeClock struct{ slept []time.Duration }

func (f *fakeClock) sleep(d time.Duration) { f.slept = append(f.slept, d) }

func (f *fakeClock) total() time.Duration {
	var t time.Duration
	for _, d := range f.slept {
		t += d
	}
	return t
}

// unverifiedThenKey answers 403 email_unverified for the first `refusals`
// calls to /api/auth/token, then 201 with a key — the shape of a human
// clicking the link partway through the wait.
func unverifiedThenKey(t *testing.T, refusals int, key string) (*httptest.Server, *int) {
	t.Helper()
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/auth/token" {
			t.Errorf("unexpected request: %s %s", r.Method, r.URL.Path)
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		if calls < refusals {
			calls++
			w.WriteHeader(http.StatusForbidden)
			// Byte-for-byte AuthTokenController's refusal (#533).
			_, _ = w.Write([]byte(`{"error":"Verify your email address before requesting an API key","reason":"email_unverified"}`))
			return
		}
		calls++
		w.WriteHeader(http.StatusCreated)
		_, _ = w.Write([]byte(`{"api_key":"` + key + `","key_id":"k1","prefix":"ftn_test"}`))
	}))
	t.Cleanup(srv.Close)
	return srv, &calls
}

func depsFor(srv *httptest.Server, clock *fakeClock) registerDeps {
	return registerDeps{
		baseURL:  srv.URL,
		client:   srv.Client(),
		sleep:    clock.sleep,
		out:      io.Discard,
		errOut:   io.Discard,
		schedule: pollSchedule,
	}
}

func TestWaitForVerificationReturnsTheKeyOnce(t *testing.T) {
	srv, calls := unverifiedThenKey(t, 3, "ftn_verified")
	clock := &fakeClock{}

	key, err := depsFor(srv, clock).waitForVerification("a@example.com", "pw")
	if err != nil {
		t.Fatalf("waitForVerification: %v", err)
	}
	if key != "ftn_verified" {
		t.Fatalf("key = %q", key)
	}
	if *calls != 4 {
		t.Fatalf("token attempts = %d, want 4 (three refusals then the key)", *calls)
	}
	if len(clock.slept) != 3 {
		t.Fatalf("slept %d times, want 3 (once after each refusal)", len(clock.slept))
	}
}

// An auto-verifying deployment (EMAIL_DELIVERY=none, ADR 0011) verifies at
// registration, so the very first attempt succeeds and the CLI must not sit
// through an interval first.
func TestWaitForVerificationDoesNotSleepWhenAlreadyVerified(t *testing.T) {
	srv, calls := unverifiedThenKey(t, 0, "ftn_auto")
	clock := &fakeClock{}

	key, err := depsFor(srv, clock).waitForVerification("a@example.com", "pw")
	if err != nil {
		t.Fatalf("waitForVerification: %v", err)
	}
	if key != "ftn_auto" {
		t.Fatalf("key = %q", key)
	}
	if *calls != 1 {
		t.Fatalf("token attempts = %d, want 1", *calls)
	}
	if len(clock.slept) != 0 {
		t.Fatalf("slept %v, want no sleep at all", clock.slept)
	}
}

// The schedule exists to fit POST /api/auth/token's budget of 10 per hour per
// IP. If someone lowers the intervals to make the wait feel snappier, this is
// what tells them what they just broke.
func TestPollScheduleFitsTheServersRateLimit(t *testing.T) {
	const budget = 10

	attempts := len(pollSchedule) + 1
	if attempts > budget {
		t.Fatalf("the wait makes %d calls to /api/auth/token; the limit is %d per hour", attempts, budget)
	}
	if attempts == budget {
		t.Fatalf("the wait uses the entire %d-per-hour budget, leaving nothing for the next command", budget)
	}

	var total time.Duration
	for _, d := range pollSchedule {
		total += d
	}
	if total < 8*time.Minute || total > 12*time.Minute {
		t.Fatalf("the wait covers %s; the documented window is about ten minutes", total)
	}
}

func TestWaitForVerificationGivesUpAfterTheSchedule(t *testing.T) {
	srv, calls := unverifiedThenKey(t, 1000, "never")
	clock := &fakeClock{}

	_, err := depsFor(srv, clock).waitForVerification("a@example.com", "pw")
	if err == nil {
		t.Fatal("expected the wait to give up")
	}
	if !strings.Contains(err.Error(), "fountain auth login") {
		t.Fatalf("the message should say how to finish later, got: %v", err)
	}
	if *calls != len(pollSchedule)+1 {
		t.Fatalf("token attempts = %d, want %d", *calls, len(pollSchedule)+1)
	}
	if clock.total() < 8*time.Minute {
		t.Fatalf("gave up after only %s of waiting", clock.total())
	}
}

// The one rule the CLI owes the limiter: never come back sooner than it asked.
func TestWaitForVerificationHonoursRetryAfter(t *testing.T) {
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		calls++
		if calls == 1 {
			w.Header().Set("Retry-After", "45")
			w.WriteHeader(http.StatusTooManyRequests)
			_, _ = w.Write([]byte(`{"error":"rate_limited","retry_after_seconds":45}`))
			return
		}
		w.WriteHeader(http.StatusCreated)
		_, _ = w.Write([]byte(`{"api_key":"ftn_after_wait"}`))
	}))
	defer srv.Close()

	clock := &fakeClock{}
	key, err := depsFor(srv, clock).waitForVerification("a@example.com", "pw")
	if err != nil {
		t.Fatalf("waitForVerification: %v", err)
	}
	if key != "ftn_after_wait" {
		t.Fatalf("key = %q", key)
	}
	if len(clock.slept) != 1 || clock.slept[0] != 45*time.Second {
		t.Fatalf("slept %v, want exactly the 45s the server asked for", clock.slept)
	}
}

// A 403 that is not `email_unverified` is a refusal to serve this account, not
// something waiting will fix.
func TestWaitForVerificationStopsOnANonVerificationRefusal(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusForbidden)
		_, _ = w.Write([]byte(`{"error":"suspended","reason":"account_suspended"}`))
	}))
	defer srv.Close()

	clock := &fakeClock{}
	_, err := depsFor(srv, clock).waitForVerification("a@example.com", "pw")
	if err == nil {
		t.Fatal("expected the wait to stop")
	}
	if len(clock.slept) != 0 {
		t.Fatalf("slept %v; a refusal that is not about verification must not be waited out", clock.slept)
	}
}

// ── the printed request ────────────────────────────────────────────────

// The CLI substitutes exactly what the server could not: the raw key it holds
// and the agent it resolved. Everything else in the text is the server's.
func TestFirstRequestRenderSubstitutesKeyAndAgent(t *testing.T) {
	for _, example := range []struct{ input, want string }{
		{`runRequest({ agent_id: "$FOUNTAIN_AGENT_ID", prompt: "hi" })`, `agent_id: "agent-uuid"`},
		{`run("hi", { agent: "$FOUNTAIN_AGENT_NAME" })`, `agent: "starter"`},
	} {
		req := firstRequest{
			Curl:       `curl -H "Authorization: Bearer $FOUNTAIN_API_KEY" -d '{"agent_id": "$FOUNTAIN_AGENT_ID"}'`,
			TypeScript: example.input,
		}
		curl, ts := req.render("ftn_secret", namedAgent{ID: "agent-uuid", Name: "starter"})
		if !strings.Contains(curl, "Bearer ftn_secret") || !strings.Contains(curl, `"agent-uuid"`) {
			t.Fatalf("curl not substituted: %s", curl)
		}
		if !strings.Contains(ts, example.want) {
			t.Fatalf("typescript not substituted: %s", ts)
		}
		for _, token := range []string{apiKeyPlaceholder, agentIDPlaceholder, agentNamePlaceholder} {
			if strings.Contains(curl+ts, token) {
				t.Fatalf("%s survived into what the developer pastes", token)
			}
		}
	}
}

// The catalog is the one source for the text (ADR 0038). This pins the shape
// the CLI reads out of it against what CatalogController renders.
func TestFetchFirstRequestReadsTheCatalogShape(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/catalog" {
			http.NotFound(w, r)
			return
		}
		if got := r.Header.Get("Authorization"); got != "Bearer ftn_k" {
			t.Errorf("Authorization = %q", got)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"data":{"first_request":{
			"curl":"curl -X POST https://x.test/api/conversations",
			"typescript":"import { Fountain }",
			"prompt":"Which operating system are you on?",
			"placeholders":["$FOUNTAIN_API_KEY","$FOUNTAIN_AGENT_ID"]}}}`))
	}))
	defer srv.Close()

	req, err := fetchFirstRequest(srv.URL, "ftn_k")
	if err != nil {
		t.Fatalf("fetchFirstRequest: %v", err)
	}
	if !strings.Contains(req.Curl, "/api/conversations") {
		t.Fatalf("curl = %q", req.Curl)
	}
	if req.Prompt != "Which operating system are you on?" {
		t.Fatalf("prompt = %q", req.Prompt)
	}
	if len(req.Placeholders) != 2 {
		t.Fatalf("placeholders = %v", req.Placeholders)
	}
}

// Same rule as the verified landing: prefer the starter planted at
// verification, but work for an account that renamed or deleted it.
func TestFetchDefaultAgentPrefersTheStarter(t *testing.T) {
	agentsJSON := func(names ...string) string {
		type a struct {
			ID   string `json:"id"`
			Name string `json:"name"`
		}
		list := make([]a, 0, len(names))
		for i, n := range names {
			list = append(list, a{ID: string(rune('a'+i)) + "-id", Name: n})
		}
		body, _ := json.Marshal(map[string]any{"data": list})
		return string(body)
	}

	for _, tc := range []struct {
		names []string
		want  string
	}{
		{[]string{"aardvark", "starter", "zebra"}, "starter"},
		{[]string{"aardvark", "zebra"}, "aardvark"},
	} {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(agentsJSON(tc.names...)))
		}))

		agent, err := fetchDefaultAgent(srv.URL, "ftn_k")
		srv.Close()
		if err != nil {
			t.Fatalf("fetchDefaultAgent(%v): %v", tc.names, err)
		}
		if agent.Name != tc.want {
			t.Fatalf("fetchDefaultAgent(%v) = %q, want %q", tc.names, agent.Name, tc.want)
		}
	}
}

func TestFetchDefaultAgentSaysSoWhenThereIsNone(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"data":[]}`))
	}))
	defer srv.Close()

	if _, err := fetchDefaultAgent(srv.URL, "ftn_k"); err == nil {
		t.Fatal("expected an error naming the missing agent")
	}
}
