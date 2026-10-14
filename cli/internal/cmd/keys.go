package cmd

import (
	"bufio"
	"fmt"
	"os"
	"strings"

	"github.com/managoat/fountain/cli/internal/api"
	"github.com/managoat/fountain/cli/internal/output"
	"github.com/spf13/cobra"
)

func init() {
	keysCmd := &cobra.Command{Use: "keys", Short: "Manage Fountain API keys"}
	listCmd := &cobra.Command{
		Use:   "list",
		Short: "List API keys",
		RunE:  func(cmd *cobra.Command, args []string) error { return keysList(cmd) },
	}
	// Every other list command takes --json; docs/cli.md promises it
	// generally.
	listCmd.Flags().Bool("json", false, "output JSON")
	keysCmd.AddCommand(
		listCmd,
		&cobra.Command{
			Use:   "create <name>",
			Short: "Create a new API key",
			Args:  cobra.ExactArgs(1),
			RunE:  func(cmd *cobra.Command, args []string) error { return keysCreate(args[0]) },
		},
		&cobra.Command{
			Use:   "revoke <id>",
			Short: "Revoke an API key",
			Args:  cobra.ExactArgs(1),
			RunE:  func(cmd *cobra.Command, args []string) error { return keysRevoke(args[0]) },
		},
	)
	rootCmd.AddCommand(keysCmd)
}

// apiKeyCreated mirrors FountainWeb.ApiKeyJSON.created/1
// (apps/fountain/lib/fountain_web/controllers/api_key_json.ex): a flat
// object — no `data` envelope — and the prefix field is `prefix`, not
// `key_prefix`. Decoding the wrong shape here loses the plaintext key
// forever, because this response is the only place it ever appears (#398).
type apiKeyCreated struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Key       string `json:"key"`
	Prefix    string `json:"prefix"`
	CreatedAt string `json:"created_at"`
}

// apiKeySummary mirrors one element of FountainWeb.ApiKeyJSON.index/1, which
// does wrap the list in a `data` envelope.
type apiKeySummary struct {
	ID         string `json:"id"`
	Name       string `json:"name"`
	Prefix     string `json:"prefix"`
	CreatedAt  string `json:"created_at"`
	LastUsedAt string `json:"last_used_at"`
}

func keysList(cmd *cobra.Command) error {
	jsonOut, _ := cmd.Flags().GetBool("json")
	c := activeClient()
	var resp struct {
		Data []apiKeySummary `json:"data"`
	}
	if err := c.Get("/auth/api-keys", &resp); err != nil {
		Fatal(err.Error())
	}
	if jsonOut {
		return output.PrintJSON(resp.Data)
	}
	rows := make([][]string, 0, len(resp.Data))
	for _, k := range resp.Data {
		lastUsed := k.LastUsedAt
		if lastUsed == "" {
			lastUsed = "never"
		}
		rows = append(rows, []string{k.Prefix, k.Name, lastUsed})
	}
	output.Table([]string{"prefix", "name", "last_used"}, rows)
	return nil
}

func keysCreate(name string) error {
	c := activeClient()
	var resp apiKeyCreated
	if err := c.Post("/auth/api-keys", map[string]string{"name": name}, &resp); err != nil {
		Fatal(err.Error())
	}
	if resp.Key == "" {
		Fatalf("unexpected response: no key field (id=%q name=%q)", resp.ID, resp.Name)
	}
	fmt.Println()
	fmt.Println("╭────────────────────────────────────────────────────────────────╮")
	fmt.Println("│  Save this key — it will not be shown again.                  │")
	fmt.Println("╰────────────────────────────────────────────────────────────────╯")
	fmt.Println()
	fmt.Println(resp.Key)
	fmt.Println()
	fmt.Printf("Name:   %s\n", resp.Name)
	fmt.Printf("Prefix: %s\n", resp.Prefix)
	fmt.Println()
	return nil
}

func keysRevoke(id string) error {
	fmt.Printf("Revoke API key %s? This cannot be undone. [y/N] ", id)
	r := bufio.NewReader(os.Stdin)
	answer, _ := r.ReadString('\n')
	answer = strings.ToLower(strings.TrimSpace(answer))
	if answer != "y" && answer != "yes" {
		fmt.Println("Aborted.")
		return nil
	}
	c := activeClient()
	if err := c.Delete("/auth/api-keys/"+id, nil); err != nil {
		if api.StatusCode(err) == 404 {
			Fatalf("key not found: %s", id)
		}
		Fatal(err.Error())
	}
	fmt.Printf("Revoked %s.\n", id)
	return nil
}
