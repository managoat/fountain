package cmd

import (
	"fmt"

	"github.com/managoat/fountain/cli/internal/api"
	"github.com/managoat/fountain/cli/internal/output"
	"github.com/spf13/cobra"
)

// The caller's sandboxes — the machines conversations run on (ADR 0023).
// `reset` is the one write: it destroys a persistent home so the next
// launch on the same agent, environment and vault builds a clean one
// (#1071). The conversations on it are kept.
func init() {
	sandboxCmd := &cobra.Command{Use: "sandbox", Short: "Manage sandboxes"}

	listCmd := &cobra.Command{
		Use:   "list",
		Short: "List sandboxes",
		RunE:  func(cmd *cobra.Command, args []string) error { return sandboxList(cmd) },
	}
	listCmd.Flags().Bool("json", false, "output JSON")
	listCmd.Flags().String("status", "", "comma-separated statuses to include (default: all)")

	sandboxCmd.AddCommand(
		listCmd,
		&cobra.Command{
			Use:   "show <id>",
			Short: "Show a sandbox and the conversations on it",
			Args:  cobra.ExactArgs(1),
			RunE:  func(cmd *cobra.Command, args []string) error { return sandboxShow(args[0]) },
		},
		&cobra.Command{
			Use:   "reset <id>",
			Short: "Destroy a persistent sandbox; the next launch builds a clean one",
			Args:  cobra.ExactArgs(1),
			RunE:  func(cmd *cobra.Command, args []string) error { return sandboxReset(args[0]) },
		},
	)
	rootCmd.AddCommand(sandboxCmd)
}

func sandboxList(cmd *cobra.Command) error {
	jsonOut, _ := cmd.Flags().GetBool("json")
	status, _ := cmd.Flags().GetString("status")
	c := activeClient()
	path := "/sandboxes"
	if status != "" {
		path += "?status=" + status
	}
	var resp struct {
		Data []map[string]any `json:"data"`
	}
	if err := c.Get(path, &resp); err != nil {
		Fatal(err.Error())
	}
	if jsonOut {
		return output.PrintJSON(resp.Data)
	}
	rows := make([][]string, 0, len(resp.Data))
	for _, v := range resp.Data {
		convs, _ := v["conversations"].([]any)
		rows = append(rows, []string{
			output.ToString(v["status"]),
			output.ToString(v["mode"]),
			output.ShortID(output.ToString(v["id"])),
			output.ShortID(output.ToString(v["agent_id"])),
			output.ToString(v["provider"]),
			fmt.Sprintf("%d", len(convs)),
			output.ToString(v["inserted_at"]),
		})
	}
	output.Table([]string{"status", "mode", "id", "agent_id", "provider", "convs", "started"}, rows)
	return nil
}

func sandboxShow(id string) error {
	c := activeClient()
	var resp struct {
		Data map[string]any `json:"data"`
	}
	if err := c.Get("/sandboxes/"+id, &resp); err != nil {
		if api.StatusCode(err) == 404 {
			Fatal("not found")
		}
		Fatal(err.Error())
	}
	s := resp.Data
	fmt.Printf("sandbox %s\n", output.ToString(s["id"]))
	fmt.Printf("  status:       %s\n", output.ToString(s["status"]))
	fmt.Printf("  mode:         %s\n", output.ToString(s["mode"]))
	fmt.Printf("  provider:     %s\n", output.ToString(s["provider"]))
	fmt.Printf("  agent:        %s\n", output.ToString(s["agent_id"]))
	fmt.Printf("  environment:  %s\n", output.ToString(s["environment_id"]))
	fmt.Printf("  vault:        %s\n", output.ToString(s["vault_id"]))
	fmt.Printf("  started:      %s\n", output.ToString(s["inserted_at"]))
	convs, _ := s["conversations"].([]any)
	fmt.Printf("  conversations: %d\n", len(convs))
	for _, raw := range convs {
		conv, _ := raw.(map[string]any)
		midTurn := ""
		if b, ok := conv["mid_turn"].(bool); ok && b {
			midTurn = "  (mid-turn)"
		}
		fmt.Printf("    %s  %s%s\n", output.ToString(conv["status"]), output.ToString(conv["id"]), midTurn)
	}
	return nil
}

func sandboxReset(id string) error {
	c := activeClient()
	if err := c.Delete("/sandboxes/"+id, nil); err != nil {
		if api.StatusCode(err) == 404 {
			Fatal("not found")
		}
		Fatal(err.Error())
	}
	fmt.Printf("reset %s\n", id)
	return nil
}
