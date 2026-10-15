package cmd

import (
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

	agentCmd.AddCommand(
		listCmd,
		&cobra.Command{
			Use:   "show <id>",
			Short: "Show an agent",
			Args:  cobra.ExactArgs(1),
			RunE:  func(cmd *cobra.Command, args []string) error { return agentShow(args[0]) },
		},
	)
	rootCmd.AddCommand(agentCmd)
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

func agentShow(id string) error {
	c := activeClient()
	var resp struct {
		Data map[string]any `json:"data"`
	}
	if err := c.Get("/agents/"+id, &resp); err != nil {
		Fatal(err.Error())
	}
	return output.PrintJSON(resp.Data)
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
