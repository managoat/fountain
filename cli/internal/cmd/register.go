package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/managoat/fountain/cli/config"
	"github.com/managoat/fountain/cli/credentials"
)

// ── fountain auth register ──────────────────────────────────────────────
//
// The second door of ADR 0038: the same path as the verified landing, for a
// developer who lives in a terminal. It creates the account, waits for the
// verification the emailed link performs, saves the key, and prints the same
// first request the landing shows.
//
// It does the steps rather than describing them. What it deliberately does
// NOT do is anything the server already does: anti-enumeration and rate
// limiting live on /api/auth/register and /api/auth/token and this adds
// nothing to either.

// pollSchedule is the wait between verification checks, and it is shaped by
// the server's budget rather than by taste.
//
// POST /api/auth/token is rate-limited to **10 per hour per IP**
// (AuthTokenController). A poll loop is an unusual client for that endpoint —
// it is sized for a human typing a password wrong — so a naive "every five
// seconds for ten minutes" would exhaust the hour's budget in under a minute
// and then sit through a 429 telling it to come back in fifty-nine.
//
// So: nine attempts, front-loaded, adding up to ten minutes, leaving one
// request in the budget for whatever the developer does next. The first is
// immediate and costs one attempt on a deployment that mails a link — nobody
// clicks that fast — but it is what makes an auto-verifying deployment
// (EMAIL_DELIVERY=none, ADR 0011) succeed without sleeping at all.
var pollSchedule = []time.Duration{
	10 * time.Second,
	20 * time.Second,
	40 * time.Second,
	60 * time.Second,
	90 * time.Second,
	120 * time.Second,
	130 * time.Second,
	130 * time.Second,
}

// registerDeps is what the flow reaches outside itself for, so a test can run
// the whole loop against a stub server in microseconds instead of ten
// minutes. Production wiring is registerLive().
type registerDeps struct {
	baseURL string
	client  *http.Client
	// sleep is the wait between attempts. A test passes one that records the
	// durations and returns immediately.
	sleep func(time.Duration)
	// out and errOut are where the human-facing text goes.
	out    io.Writer
	errOut io.Writer
	// schedule may be shortened by a test; nil means pollSchedule.
	schedule []time.Duration
}

func registerLive() registerDeps {
	return registerDeps{
		baseURL:  config.BaseURL(activeOpts()),
		client:   &http.Client{Timeout: 30 * time.Second},
		sleep:    time.Sleep,
		out:      os.Stdout,
		errOut:   os.Stderr,
		schedule: pollSchedule,
	}
}

func (d registerDeps) steps() []time.Duration {
	if d.schedule == nil {
		return pollSchedule
	}
	return d.schedule
}

// authRegister is `fountain auth register`.
func authRegister(email, password, accessCode string) error {
	d := registerLive()

	var err error
	if email == "" {
		if email, err = promptLine("Email: "); err != nil {
			return err
		}
	}
	if password == "" {
		if password, err = promptPassword("Password: "); err != nil {
			return err
		}
	}
	email, password = strings.TrimSpace(email), strings.TrimSpace(password)
	if email == "" || password == "" {
		Fatal("email and password are both required")
	}

	if err := d.createAccount(email, password, strings.TrimSpace(accessCode)); err != nil {
		return err
	}

	key, err := d.waitForVerification(email, password)
	if err != nil {
		return err
	}

	profile := credentials.ProfileName(activeOpts())
	if err := credentials.WriteProfile(profile, map[string]string{
		"api_key":  key,
		"base_url": d.baseURL,
	}); err != nil {
		return err
	}

	fmt.Fprintf(d.out, "\nVerified. Logged in as %s (profile: %s).\n", email, profile)
	printFirstRequest(d.out, d.baseURL, key)
	return nil
}

// createAccount posts to /api/auth/register and reports what the server said.
// A 403 here is a policy refusal — registration closed, a domain that is not
// allowed — and its message is the server's to write, not the CLI's to guess.
// The one refusal the CLI can act on is a missing access code, so that one
// names the flag.
//
// access_code goes on the wire only when given: an instance without a code
// ignores the field, but there is no reason to send it one.
func (d registerDeps) createAccount(email, password, accessCode string) error {
	fields := map[string]string{"email": email, "password": password}
	if accessCode != "" {
		fields["access_code"] = accessCode
	}
	body, err := json.Marshal(fields)
	if err != nil {
		return err
	}

	resp, raw, err := d.post("/api/auth/register", body)
	if err != nil {
		Fatalf("could not reach %s: %v", d.baseURL, err)
	}

	switch {
	case resp.StatusCode == http.StatusCreated:
		var out struct {
			Message string `json:"message"`
		}
		_ = json.Unmarshal(raw, &out)
		if out.Message != "" {
			fmt.Fprintln(d.errOut, out.Message)
		}
		return nil

	case resp.StatusCode == http.StatusForbidden && refusal(raw) == "access_code_required":
		if accessCode == "" {
			return fmt.Errorf("signup on %s needs an access code. Run it again with --access-code <code>", d.baseURL)
		}
		return fmt.Errorf("%s did not accept that access code", d.baseURL)

	case resp.StatusCode == http.StatusUnprocessableEntity:
		Fatalf("the server rejected those details: %s", strings.TrimSpace(string(raw)))
	case resp.StatusCode == http.StatusTooManyRequests:
		Fatalf("too many attempts from this address. %s", retryHint(resp))
	default:
		Fatalf("registration failed (HTTP %d): %s", resp.StatusCode, strings.TrimSpace(string(raw)))
	}
	return nil
}

// waitForVerification polls the token endpoint until the account stops being
// unverified. The emailed link keeps working exactly as it always did; this
// only notices the result.
func (d registerDeps) waitForVerification(email, password string) (string, error) {
	body, err := json.Marshal(map[string]string{"email": email, "password": password})
	if err != nil {
		return "", err
	}

	steps := d.steps()
	for attempt := 0; ; attempt++ {
		resp, raw, err := d.post("/api/auth/token", body)
		if err != nil {
			return "", fmt.Errorf("could not reach %s: %w", d.baseURL, err)
		}

		switch resp.StatusCode {
		case http.StatusCreated, http.StatusOK:
			key := extractAPIKey(raw)
			if key == "" {
				return "", fmt.Errorf("unexpected token response: %s", raw)
			}
			return key, nil

		case http.StatusForbidden:
			if !unverified(raw) {
				return "", fmt.Errorf("the server refused the sign-in: %s", strings.TrimSpace(string(raw)))
			}
			if attempt == 0 {
				fmt.Fprintf(d.errOut,
					"\nWaiting for you to click the link in that email.\n"+
						"This gives up after about ten minutes; Ctrl-C is safe, and\n"+
						"`fountain auth login` finishes the job whenever you are ready.\n")
			}

		case http.StatusTooManyRequests:
			// The one rule the CLI owes the limiter: never come back sooner
			// than it asked. If it wants longer than the whole remaining
			// schedule, stop rather than pretend to wait.
			wait := retryAfter(resp)
			if wait > 0 && wait <= 10*time.Minute {
				d.sleep(wait)
				continue
			}
			return "", fmt.Errorf("rate limited by the server. %s", retryHint(resp))

		case http.StatusUnauthorized:
			// The account was just created with these credentials, so this is
			// not a typo — it is a different account with the same address,
			// or a password change between the two calls.
			return "", fmt.Errorf(
				"the server did not accept that password for %s.\n"+
					"If the address already had an account, run `fountain auth login`", email)

		default:
			return "", fmt.Errorf("sign-in failed (HTTP %d): %s",
				resp.StatusCode, strings.TrimSpace(string(raw)))
		}

		if attempt >= len(steps) {
			return "", fmt.Errorf(
				"gave up after about ten minutes.\n" +
					"The account exists and the link in your email still works.\n" +
					"Run `fountain auth login` once you have clicked it")
		}
		d.sleep(steps[attempt])
	}
}

func (d registerDeps) post(path string, body []byte) (*http.Response, []byte, error) {
	req, err := http.NewRequestWithContext(
		context.Background(), http.MethodPost, d.baseURL+path, bytes.NewReader(body))
	if err != nil {
		return nil, nil, err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := d.client.Do(req)
	if err != nil {
		return nil, nil, err
	}
	defer resp.Body.Close()

	raw, _ := io.ReadAll(resp.Body)
	return resp, raw, nil
}

// unverified reports whether a 403 is "click the link in your email" rather
// than a refusal to serve this account at all. The server names the reason
// (`email_unverified`, #533) precisely so a client need not read the prose.
func unverified(raw []byte) bool {
	var out struct {
		Reason string `json:"reason"`
	}
	_ = json.Unmarshal(raw, &out)
	return out.Reason == "email_unverified"
}

// refusal is the reason code RegistrationController puts on a 403.
func refusal(raw []byte) string {
	var out struct {
		Error string `json:"error"`
	}
	_ = json.Unmarshal(raw, &out)
	return out.Error
}

// retryAfter reads the header the rate limiter sets. Seconds only: that is
// what FountainWeb.Plugs.RateLimit sends.
func retryAfter(resp *http.Response) time.Duration {
	secs, err := strconv.Atoi(strings.TrimSpace(resp.Header.Get("Retry-After")))
	if err != nil || secs < 0 {
		return 0
	}
	return time.Duration(secs) * time.Second
}

func retryHint(resp *http.Response) string {
	if wait := retryAfter(resp); wait > 0 {
		return fmt.Sprintf("Try again in %s.", wait.Round(time.Second))
	}
	return "Try again later."
}
