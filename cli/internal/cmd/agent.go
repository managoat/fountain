package cmd

import (
	"fmt"

	"github.com/managoat/managoat/cli/internal/api"
	"github.com/managoat/managoat/cli/internal/output"
	"github.com/spf13/cobra"
)

func init() {
	agentCmd := &cobra.Command{Use: "agent", Short: "Manage agents"}

	listCmd := &cobra.Command{
		Use:   "list",
		Short: "List agents",
		RunE:  func(cmd *cobra.Command, args []string) error { return agentList(cmd) },
	}
	listCmd.Flags().Bool("json", false, "output JSON")

	createCmd := &cobra.Command{
		Use:   "create <name>",
		Short: "Create an agent",
		Long: "Create an agent from flags. Skills, MCP servers, a permission policy and\n" +
			"the other structured fields are set with `managoat apply`.",
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error { return agentCreate(cmd, args[0]) },
	}
	addAgentFlags(createCmd)
	_ = createCmd.MarkFlagRequired("runtime")

	updateCmd := &cobra.Command{
		Use:   "update <id-or-name>",
		Short: "Update an agent",
		Long: "Change the fields named by flags and leave the rest as they are. An empty\n" +
			"--model or --environment clears that field.",
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error { return agentUpdate(cmd, args[0]) },
	}
	updateCmd.Flags().String("name", "", "new agent name")
	addAgentFlags(updateCmd)

	agentCmd.AddCommand(
		listCmd,
		&cobra.Command{
			Use:   "show <id-or-name>",
			Short: "Show an agent",
			Args:  cobra.ExactArgs(1),
			RunE:  func(cmd *cobra.Command, args []string) error { return agentShow(args[0]) },
		},
		createCmd,
		updateCmd,
		&cobra.Command{
			Use:   "delete <id-or-name>",
			Short: "Delete an agent",
			Args:  cobra.ExactArgs(1),
			RunE:  func(cmd *cobra.Command, args []string) error { return agentDelete(args[0]) },
		},
	)
	rootCmd.AddCommand(agentCmd)
}

func addAgentFlags(c *cobra.Command) {
	f := c.Flags()
	f.String("runtime", "", "runtime: claude, codex, gemini or acp")
	f.String("model", "", "model as provider/name, e.g. anthropic/claude-sonnet-4-5")
	f.String("description", "", "agent description")
	f.String("system", "", "system prompt")
	f.String("system-file", "", "read the system prompt from a file")
	f.String("environment", "", "environment id or name")
	f.String("runtime-command", "", "command the acp runtime launches in the sandbox")
	f.String("sandbox-provider", "", "sandbox backend override: sprites or e2b")
}

// agentBody builds a request body from the flags the caller set. A flag left
// alone is left out, so an update changes only what was named.
func agentBody(cmd *cobra.Command) map[string]any {
	f := cmd.Flags()
	body := map[string]any{}
	setString(f, body, "name", "name", false)
	setString(f, body, "runtime", "runtime", false)
	setString(f, body, "model", "model", true)
	setString(f, body, "description", "description", false)
	setString(f, body, "runtime-command", "runtime_command", true)
	setString(f, body, "sandbox-provider", "sandbox_provider", true)
	setTextOrFile(f, body, "system", "system")
	if f.Changed("environment") {
		v, _ := f.GetString("environment")
		if v == "" {
			body["environment_id"] = nil
		} else {
			body["environment_id"] = resolveEnvironmentID(v)
		}
	}
	return body
}

func agentList(cmd *cobra.Command) error {
	jsonOut, _ := cmd.Flags().GetBool("json")
	c := activeClient()
	var resp struct {
		Data []map[string]any `json:"data"`
	}
	if err := c.Get("/agents", &resp); err != nil {
		Fatal(err.Error())
	}
	if jsonOut {
		return output.PrintJSON(resp.Data)
	}
	rows := make([][]string, 0, len(resp.Data))
	for _, a := range resp.Data {
		envID := output.ToString(a["environment_id"])
		if envID == "" {
			envID = "(none)"
		} else {
			envID = output.ShortID(envID)
		}
		rows = append(rows, []string{
			output.ToString(a["name"]),
			output.ToString(a["runtime"]),
			output.ToString(a["model"]),
			envID,
		})
	}
	output.Table([]string{"name", "runtime", "model", "env"}, rows)
	return nil
}

func agentShow(target string) error {
	c := activeClient()
	id := resolveAgentID(target)
	var resp struct {
		Data map[string]any `json:"data"`
	}
	if err := c.Get("/agents/"+id, &resp); err != nil {
		Fatal(err.Error())
	}
	return output.PrintJSON(resp.Data)
}

func agentCreate(cmd *cobra.Command, name string) error {
	body := agentBody(cmd)
	body["name"] = name
	c := activeClient()
	var resp struct {
		Data map[string]any `json:"data"`
	}
	if err := c.Post("/agents", body, &resp); err != nil {
		Fatal(err.Error())
	}
	fmt.Printf("agent  +  %s (%s)\n", output.ToString(resp.Data["name"]), output.ToString(resp.Data["id"]))
	return nil
}

func agentUpdate(cmd *cobra.Command, target string) error {
	body := agentBody(cmd)
	if len(body) == 0 {
		Fatal("nothing to update: name at least one field to change (see --help)")
	}
	c := activeClient()
	id := resolveAgentID(target)
	var resp struct {
		Data map[string]any `json:"data"`
	}
	if err := c.Patch("/agents/"+id, body, &resp); err != nil {
		if api.StatusCode(err) == 404 {
			Fatal("not found")
		}
		Fatal(err.Error())
	}
	fmt.Printf("agent  ~  %s (%s)\n", output.ToString(resp.Data["name"]), output.ToString(resp.Data["id"]))
	return nil
}

func agentDelete(target string) error {
	c := activeClient()
	id := resolveAgentID(target)
	if err := c.Delete("/agents/"+id, nil); err != nil {
		if api.StatusCode(err) == 404 {
			Fatal("not found")
		}
		Fatal(err.Error())
	}
	fmt.Printf("deleted %s\n", id)
	return nil
}

// resolveAgentID accepts a UUID or a name; for names it queries /agents
// and finds by exact match. Used by `run` for --agent name resolution.
func resolveAgentID(target string) string {
	if isUUID(target) {
		return target
	}
	c := activeClient()
	var resp struct {
		Data []map[string]any `json:"data"`
	}
	if err := c.Get("/agents", &resp); err != nil {
		Fatal(err.Error())
	}
	for _, a := range resp.Data {
		if output.ToString(a["name"]) == target {
			return output.ToString(a["id"])
		}
	}
	Fatalf("no agent named %q", target)
	return ""
}
