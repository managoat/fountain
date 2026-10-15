package cmd

import (
	"github.com/managoat/managoat/cli/internal/output"
	"github.com/spf13/cobra"
)

func init() {
	envCmd := &cobra.Command{Use: "env", Short: "Manage environments"}

	listCmd := &cobra.Command{
		Use:   "list",
		Short: "List environments",
		RunE:  func(cmd *cobra.Command, args []string) error { return envList(cmd) },
	}
	listCmd.Flags().Bool("json", false, "output JSON")

	envCmd.AddCommand(
		listCmd,
		&cobra.Command{
			Use:   "show <id>",
			Short: "Show an environment",
			Args:  cobra.ExactArgs(1),
			RunE:  func(cmd *cobra.Command, args []string) error { return envShow(args[0]) },
		},
	)
	rootCmd.AddCommand(envCmd)
}

func envList(cmd *cobra.Command) error {
	jsonOut, _ := cmd.Flags().GetBool("json")
	c := activeClient()
	var resp struct {
		Data []map[string]any `json:"data"`
	}
	if err := c.Get("/environments", &resp); err != nil {
		Fatal(err.Error())
	}
	if jsonOut {
		return output.PrintJSON(resp.Data)
	}
	rows := make([][]string, 0, len(resp.Data))
	for _, e := range resp.Data {
		rows = append(rows, []string{
			output.ToString(e["name"]),
			output.ToString(e["networking_type"]),
			output.Truncate(output.ToString(e["setup_script"]), 60),
		})
	}
	output.Table([]string{"name", "networking", "setup_script"}, rows)
	return nil
}

func envShow(id string) error {
	c := activeClient()
	var envResp struct {
		Data map[string]any `json:"data"`
	}
	if err := c.Get("/environments/"+id, &envResp); err != nil {
		Fatal(err.Error())
	}
	var secResp struct {
		Data any `json:"data"`
	}
	if err := c.Get("/environments/"+id+"/secrets", &secResp); err != nil {
		Fatal(err.Error())
	}
	envResp.Data["secrets"] = secResp.Data
	return output.PrintJSON(envResp.Data)
}

// resolveEnvironmentID accepts a UUID or an environment name and returns the id,
// exactly as resolveVaultID does for vaults. Fatal on an unknown name.
func resolveEnvironmentID(target string) string {
	if isUUID(target) {
		return target
	}
	c := activeClient()
	var resp struct {
		Data []map[string]any `json:"data"`
	}
	if err := c.Get("/environments", &resp); err != nil {
		Fatal(err.Error())
	}
	for _, e := range resp.Data {
		if output.ToString(e["name"]) == target {
			return output.ToString(e["id"])
		}
	}
	Fatalf("no environment named %q", target)
	return ""
}
