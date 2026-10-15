package cmd

import (
	"fmt"
	"regexp"

	"github.com/managoat/managoat/cli/internal/api"
	"github.com/managoat/managoat/cli/internal/output"
	"github.com/spf13/cobra"
)

var uuidRE = regexp.MustCompile(`^[0-9a-fA-F-]{36}$`)

func isUUID(s string) bool { return uuidRE.MatchString(s) }

func init() {
	vaultCmd := &cobra.Command{Use: "vault", Short: "Manage vaults"}

	listCmd := &cobra.Command{
		Use:   "list",
		Short: "List vaults",
		RunE:  func(cmd *cobra.Command, args []string) error { return vaultList(cmd) },
	}
	listCmd.Flags().Bool("json", false, "output JSON")

	createCmd := &cobra.Command{
		Use:   "create <name>",
		Short: "Create a vault",
		Args:  cobra.ExactArgs(1),
		RunE:  func(cmd *cobra.Command, args []string) error { return vaultCreate(cmd, args[0]) },
	}
	createCmd.Flags().String("description", "", "vault description")

	vaultCmd.AddCommand(
		listCmd,
		createCmd,
		&cobra.Command{
			Use:   "show <id-or-name>",
			Short: "Show a vault",
			Args:  cobra.ExactArgs(1),
			RunE:  func(cmd *cobra.Command, args []string) error { return vaultShow(args[0]) },
		},
		&cobra.Command{
			Use:   "delete <id-or-name>",
			Short: "Delete a vault",
			Args:  cobra.ExactArgs(1),
			RunE:  func(cmd *cobra.Command, args []string) error { return vaultDelete(args[0]) },
		},
		&cobra.Command{
			Use:   "set-secret <id-or-name> <key> <value>",
			Short: "Set a vault secret",
			Args:  cobra.ExactArgs(3),
			RunE: func(cmd *cobra.Command, args []string) error {
				return vaultSetSecret(args[0], args[1], args[2])
			},
		},
		&cobra.Command{
			Use:   "delete-secret <id-or-name> <key>",
			Short: "Delete a vault secret",
			Args:  cobra.ExactArgs(2),
			RunE: func(cmd *cobra.Command, args []string) error {
				return vaultDeleteSecret(args[0], args[1])
			},
		},
	)
	rootCmd.AddCommand(vaultCmd)
}

func vaultList(cmd *cobra.Command) error {
	jsonOut, _ := cmd.Flags().GetBool("json")
	c := activeClient()
	var resp struct {
		Data []map[string]any `json:"data"`
	}
	if err := c.Get("/vaults", &resp); err != nil {
		Fatal(err.Error())
	}
	if jsonOut {
		return output.PrintJSON(resp.Data)
	}
	rows := make([][]string, 0, len(resp.Data))
	for _, v := range resp.Data {
		rows = append(rows, []string{
			output.ToString(v["name"]),
			output.ShortID(output.ToString(v["id"])),
			output.Truncate(output.ToString(v["description"]), 60),
		})
	}
	output.Table([]string{"name", "id", "description"}, rows)
	return nil
}

func vaultShow(target string) error {
	c := activeClient()
	id := resolveVaultID(target)
	var vresp struct {
		Data map[string]any `json:"data"`
	}
	if err := c.Get("/vaults/"+id, &vresp); err != nil {
		Fatal(err.Error())
	}
	var sresp struct {
		Data any `json:"data"`
	}
	if err := c.Get("/vaults/"+id+"/secrets", &sresp); err != nil {
		Fatal(err.Error())
	}
	vresp.Data["secrets"] = sresp.Data
	return output.PrintJSON(vresp.Data)
}

func vaultCreate(cmd *cobra.Command, name string) error {
	desc, _ := cmd.Flags().GetString("description")
	c := activeClient()
	var resp struct {
		Data map[string]any `json:"data"`
	}
	body := map[string]string{"name": name, "description": desc}
	if err := c.Post("/vaults", body, &resp); err != nil {
		Fatal(err.Error())
	}
	fmt.Printf("vault  +  %s (%s)\n", output.ToString(resp.Data["name"]), output.ToString(resp.Data["id"]))
	return nil
}

func vaultDelete(target string) error {
	c := activeClient()
	id := resolveVaultID(target)
	if err := c.Delete("/vaults/"+id, nil); err != nil {
		if api.StatusCode(err) == 404 {
			Fatal("not found")
		}
		Fatal(err.Error())
	}
	fmt.Printf("deleted %s\n", id)
	return nil
}

func vaultSetSecret(target, key, value string) error {
	c := activeClient()
	id := resolveVaultID(target)
	if err := c.Post("/vaults/"+id+"/secrets", map[string]string{"key": key, "value": value}, nil); err != nil {
		Fatal(err.Error())
	}
	fmt.Printf("secret  +  %s\n", key)
	return nil
}

func vaultDeleteSecret(target, key string) error {
	c := activeClient()
	id := resolveVaultID(target)
	if err := c.Delete("/vaults/"+id+"/secrets/"+key, nil); err != nil {
		if api.StatusCode(err) == 404 {
			Fatal("not found")
		}
		Fatal(err.Error())
	}
	fmt.Printf("deleted secret %s\n", key)
	return nil
}

// resolveVaultID accepts a UUID or vault name; for names it queries
// /vaults and matches by exact name.
func resolveVaultID(target string) string {
	if isUUID(target) {
		return target
	}
	c := activeClient()
	var resp struct {
		Data []map[string]any `json:"data"`
	}
	if err := c.Get("/vaults", &resp); err != nil {
		Fatal(err.Error())
	}
	for _, v := range resp.Data {
		if output.ToString(v["name"]) == target {
			return output.ToString(v["id"])
		}
	}
	Fatalf("no vault named %q", target)
	return ""
}
