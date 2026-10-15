package cmd

import (
	"fmt"
	"net/url"
	"strings"

	"github.com/managoat/fountain/cli/internal/api"
	"github.com/managoat/fountain/cli/internal/output"
	"github.com/spf13/cobra"
)

func init() {
	oauthClientCmd := &cobra.Command{
		Use:   "oauth-client",
		Short: "Manage the OAuth apps this account registered",
		Long: "Register an app so it can offer \"Sign in with Managoat\" against this\n" +
			"server, without an operator editing OAUTH_CLIENTS. Registering also lets\n" +
			"the app call the API from its own origin.\n\n" +
			"An app starts in development mode: it signs in its owner and refuses every\n" +
			"other account. Use a sandbox's public HTTPS URL or an HTTP localhost URL.\n" +
			"A loopback URI matches on any port.",
	}

	listCmd := &cobra.Command{
		Use:   "list",
		Short: "List OAuth apps",
		RunE:  func(cmd *cobra.Command, args []string) error { return oauthClientList(cmd) },
	}
	listCmd.Flags().Bool("json", false, "output JSON")

	createCmd := &cobra.Command{
		Use:   "create <name>",
		Short: "Register an OAuth app",
		Args:  cobra.ExactArgs(1),
		RunE:  func(cmd *cobra.Command, args []string) error { return oauthClientCreate(cmd, args[0]) },
	}
	// StringArray, not StringSlice: StringSlice parses each occurrence as CSV,
	// so a redirect URI carrying a comma in its query string would arrive as
	// two URIs, the second of them nonsense.
	createCmd.Flags().StringArray("redirect-uri", nil, "where the code is returned to; repeatable")
	createCmd.Flags().Bool("json", false, "output JSON")
	_ = createCmd.MarkFlagRequired("redirect-uri")

	updateCmd := &cobra.Command{
		Use:   "update <id>",
		Short: "Rename an OAuth app or replace its redirect URIs",
		Args:  cobra.ExactArgs(1),
		RunE:  func(cmd *cobra.Command, args []string) error { return oauthClientUpdate(cmd, args[0]) },
	}
	updateCmd.Flags().String("name", "", "new name")
	updateCmd.Flags().StringArray("redirect-uri", nil, "replaces every redirect URI; repeatable")
	updateCmd.Flags().Bool("json", false, "output JSON")

	oauthClientCmd.AddCommand(
		listCmd,
		createCmd,
		updateCmd,
		&cobra.Command{
			Use:   "delete <id>",
			Short: "Unregister an OAuth app",
			Args:  cobra.ExactArgs(1),
			RunE:  func(cmd *cobra.Command, args []string) error { return oauthClientDelete(args[0]) },
		},
	)
	rootCmd.AddCommand(oauthClientCmd)
}

// oauthClient mirrors FountainWeb.OAuthClientJSON.show/1
// (apps/fountain/lib/fountain_web/controllers/oauth_client_json.ex). `id` is
// the record id these commands take; `client_id` is what goes in the app.
type oauthClient struct {
	ID           string   `json:"id"`
	ClientID     string   `json:"client_id"`
	Name         string   `json:"name"`
	RedirectURIs []string `json:"redirect_uris"`
	Origins      []string `json:"origins"`
	Published    bool     `json:"published"`
	CreatedAt    string   `json:"created_at"`
}

func oauthClientList(cmd *cobra.Command) error {
	jsonOut, _ := cmd.Flags().GetBool("json")
	c := activeClient()
	var resp struct {
		Data []oauthClient `json:"data"`
	}
	if err := c.Get("/oauth/clients", &resp); err != nil {
		Fatal(err.Error())
	}
	if jsonOut {
		return output.PrintJSON(resp.Data)
	}
	rows := make([][]string, 0, len(resp.Data))
	for _, a := range resp.Data {
		rows = append(rows, []string{a.ID, a.ClientID, a.Name, mode(a), strings.Join(a.RedirectURIs, " ")})
	}
	output.Table([]string{"id", "client_id", "name", "mode", "redirect_uris"}, rows)
	return nil
}

func oauthClientCreate(cmd *cobra.Command, name string) error {
	uris, _ := cmd.Flags().GetStringArray("redirect-uri")
	jsonOut, _ := cmd.Flags().GetBool("json")
	c := activeClient()
	var resp oauthClient
	body := map[string]any{"name": name, "redirect_uris": uris}
	if err := c.Post("/oauth/clients", body, &resp); err != nil {
		Fatal(err.Error())
	}
	if jsonOut {
		return output.PrintJSON(resp)
	}
	printOAuthClient(resp)
	return nil
}

func oauthClientUpdate(cmd *cobra.Command, id string) error {
	jsonOut, _ := cmd.Flags().GetBool("json")
	body := map[string]any{}
	if name, _ := cmd.Flags().GetString("name"); name != "" {
		body["name"] = name
	}
	if uris, _ := cmd.Flags().GetStringArray("redirect-uri"); len(uris) > 0 {
		body["redirect_uris"] = uris
	}
	if len(body) == 0 {
		Fatal("nothing to change: pass --name or --redirect-uri")
	}
	c := activeClient()
	var resp oauthClient
	if err := c.Patch("/oauth/clients/"+id, body, &resp); err != nil {
		if api.StatusCode(err) == 404 {
			Fatalf("app not found: %s", id)
		}
		Fatal(err.Error())
	}
	if jsonOut {
		return output.PrintJSON(resp)
	}
	printOAuthClient(resp)
	return nil
}

func oauthClientDelete(id string) error {
	c := activeClient()
	if err := c.Delete("/oauth/clients/"+id, nil); err != nil {
		if api.StatusCode(err) == 404 {
			Fatalf("app not found: %s", id)
		}
		Fatal(err.Error())
	}
	fmt.Printf("Deleted %s. Keys it already issued stay valid until revoked.\n", id)
	return nil
}

func mode(a oauthClient) string {
	if a.Published {
		return "published"
	}
	return "development"
}

func printOAuthClient(a oauthClient) {
	fmt.Printf("id:            %s\n", a.ID)
	fmt.Printf("client_id:     %s\n", a.ClientID)
	fmt.Printf("name:          %s\n", a.Name)
	fmt.Printf("mode:          %s\n", mode(a))
	fmt.Printf("redirect_uris: %s\n", strings.Join(a.RedirectURIs, "\n               "))
	origins := strings.Join(a.Origins, ", ")
	for _, uri := range a.RedirectURIs {
		if oauthClientLoopbackURI(uri) {
			origins += " (loopback: any port)"
			break
		}
	}
	fmt.Printf("origins:       %s\n", origins)
}

// Mirrors Fountain.OAuth.Client.loopback?/1 in apps/fountain/lib/fountain/oauth/client.ex.
func oauthClientLoopbackURI(uri string) bool {
	u, err := url.Parse(uri)
	if err != nil {
		return false
	}
	switch strings.ToLower(u.Hostname()) {
	case "localhost", "127.0.0.1", "::1":
		return true
	default:
		return false
	}
}
