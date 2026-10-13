package cmd

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/managoat/fountain/cli/config"
	"github.com/managoat/fountain/cli/internal/output"
	"github.com/spf13/cobra"
)

// ── the first request, from the server ──────────────────────────────────
//
// The manual and this CLI print the same request. That is only true if there
// is one copy of the text, and there is: the two files under docs/snippets/,
// read at compile time by `Fountain.FirstRequest`.
// The CLI is Go and cannot read them — `go:embed` cannot reach outside
// cli/'s own module, and a build-time copy would be a second file to keep in
// step, which is the failure this is trying to avoid.
//
// So the text arrives over the wire, from `GET /api/catalog`, whose whole
// purpose is already "the same lists over the API so a client does not
// hard-code them and drift from the server". The server fills in the base
// URL because it knows it; the CLI fills in the key, because the server
// stores only a hash of it and genuinely cannot.

const (
	apiKeyPlaceholder    = "$FOUNTAIN_API_KEY"
	agentIDPlaceholder   = "$FOUNTAIN_AGENT_ID"
	agentNamePlaceholder = "$FOUNTAIN_AGENT_NAME"
	starterAgentName     = "starter"
)

type firstRequest struct {
	Curl         string   `json:"curl"`
	TypeScript   string   `json:"typescript"`
	Prompt       string   `json:"prompt"`
	Placeholders []string `json:"placeholders"`
}

type namedAgent struct {
	ID   string
	Name string
}

// fetchFirstRequest reads the snippet out of the catalog with an explicit
// key, so it works in `auth register` before the credentials file has been
// re-read.
func fetchFirstRequest(base, key string) (firstRequest, error) {
	var out struct {
		Data struct {
			FirstRequest firstRequest `json:"first_request"`
		} `json:"data"`
	}

	raw, err := getJSON(base, key, "/api/catalog")
	if err != nil {
		return firstRequest{}, err
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		return firstRequest{}, err
	}
	return out.Data.FirstRequest, nil
}

// fetchDefaultAgent picks the agent the first request runs against: the
// `starter` planted at verification, or failing that whatever the account
// has. The starter is an ordinary agent and may be renamed or deleted.
func fetchDefaultAgent(base, key string) (namedAgent, error) {
	var out struct {
		Data []map[string]any `json:"data"`
	}

	raw, err := getJSON(base, key, "/api/agents")
	if err != nil {
		return namedAgent{}, err
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		return namedAgent{}, err
	}
	if len(out.Data) == 0 {
		return namedAgent{}, fmt.Errorf("this account has no agent yet")
	}

	agents := make([]namedAgent, 0, len(out.Data))
	for _, a := range out.Data {
		agents = append(agents, namedAgent{
			ID:   output.ToString(a["id"]),
			Name: output.ToString(a["name"]),
		})
	}
	for _, a := range agents {
		if a.Name == starterAgentName {
			return a, nil
		}
	}
	return agents[0], nil
}

// render substitutes what the server could not: the caller's own key, and the
// agent it just resolved.
func (f firstRequest) render(key string, agent namedAgent) (curl, ts string) {
	rep := strings.NewReplacer(
		apiKeyPlaceholder, key,
		agentIDPlaceholder, agent.ID,
		agentNamePlaceholder, agent.Name,
	)
	return rep.Replace(f.Curl), rep.Replace(f.TypeScript)
}

// printFirstRequest is what `auth register` ends with: the first request,
// filled in with the saved key and the account's agent.
func printFirstRequest(w io.Writer, base, key string) {
	req, err := fetchFirstRequest(base, key)
	if err != nil {
		fmt.Fprintf(w, "\nYour key is saved. Run `fountain quickstart` for your first request, or read %s/docs/quickstart.\n", base)
		return
	}

	agent, aerr := fetchDefaultAgent(base, key)
	if aerr != nil {
		fmt.Fprintf(w, "\n%s. Create one with `fountain apply`, then run `fountain quickstart`.\n", aerr)
		return
	}

	curl, ts := req.render(key, agent)

	fmt.Fprintf(w, "\nOne request against your %s agent:\n\n%s\n", agent.Name, curl)
	fmt.Fprintf(w, "\nOr from the TypeScript SDK:\n\n%s\n", ts)
	fmt.Fprintf(w, "\nOr let this CLI run it for you:\n\n  fountain quickstart\n")
}

// ── fountain quickstart ─────────────────────────────────────────────────

func init() {
	rootCmd.AddCommand(&cobra.Command{
		Use:   "quickstart",
		Short: "Run the first request against your default agent and stream the reply",
		Long: "Sends the same prompt the manual shows, to the agent " +
			"this account already has, and streams the reply. It is `fountain run` " +
			"with the agent and the prompt filled in.",
		RunE: func(cmd *cobra.Command, args []string) error { return quickstart() },
	})
}

func quickstart() error {
	opts := activeOpts()
	base := config.BaseURL(opts)
	key, err := config.APIKey(opts)
	if err != nil || key == "" {
		Fatal("no saved credentials. Run `fountain auth register` or `fountain auth login` first.")
	}

	req, err := fetchFirstRequest(base, key)
	if err != nil {
		Fatalf("could not read the first request from %s: %v", base, err)
	}
	agent, err := fetchDefaultAgent(base, key)
	if err != nil {
		Fatalf("%v. Create one with `fountain apply`, then try again", err)
	}

	fmt.Fprintf(os.Stderr, "▸ %s: %s\n", agent.Name, req.Prompt)

	c := activeClient()
	var resp struct {
		Data map[string]any `json:"data"`
	}
	if err := c.Post("/conversations", map[string]any{
		"agent_id": agent.ID,
		"prompt":   req.Prompt,
	}, &resp); err != nil {
		Fatal(err.Error())
	}

	convID := output.ToString(resp.Data["id"])
	fmt.Fprintf(os.Stderr, "▸ conversation %s\n", convID)

	if err := followUntilIdle(convID, ""); err != nil {
		printWhyItMightNotHaveAnswered(os.Stderr, base)
		return err
	}

	printDoors(os.Stdout, base)
	return nil
}

// printWhyItMightNotHaveAnswered runs when the first run a person ever starts
// does not answer. It names the two things that stop one on a fresh account
// and where to look, and it does NOT try to diagnose which: the server's own
// error is above this, and guessing over it would be worse than pointing.
//
// The no-credential case is one of the two, and it is deliberately not
// special-cased here — `InferenceCredentials.select/2` decides whether this
// deployment covers an account that has none (#1388), and a client that
// second-guessed that rule would go stale the moment a platform key appeared.
func printWhyItMightNotHaveAnswered(w io.Writer, base string) {
	fmt.Fprintf(w, "\nThe two usual reasons a first run does not answer:\n")
	fmt.Fprintf(w, "  no model key for this account   %s/account/inference-credentials\n", base)
	fmt.Fprintf(w, "  no sandbox provider configured  %s/docs/self-hosting\n", base)
}

// printDoors is where to go after the first reply.
func printDoors(w io.Writer, base string) {
	fmt.Fprintf(w, "\nThat reply came from your agent, in a sandbox Fountain started for it.\n\n")
	fmt.Fprintf(w, "  Your own inference key   %s/account/inference-credentials\n", base)
	fmt.Fprintf(w, "  Your own agents          fountain apply -f fountain.yml\n")
	fmt.Fprintf(w, "  The SDK, for real code   %s/docs/sdk\n", base)
}

// getJSON is a bare authenticated GET. `api.Client` reads its key from the
// config, and both callers here have one in hand that may not be on disk yet.
func getJSON(base, key, path string) ([]byte, error) {
	req, err := http.NewRequestWithContext(context.Background(), http.MethodGet, base+path, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+key)

	resp, err := (&http.Client{Timeout: 30 * time.Second}).Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	raw, _ := io.ReadAll(resp.Body)
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("GET %s: HTTP %d: %s", path, resp.StatusCode, strings.TrimSpace(string(raw)))
	}
	return raw, nil
}
