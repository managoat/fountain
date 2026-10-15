package cmd

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"
)

var profileFlag string

// Version is stamped at build time by release.yml:
//
//	go build -ldflags "-X .../internal/cmd.Version=v0.9.0"
//
// A source build says "dev", which is the honest answer and the one an editor
// shows when it reports which agent it is talking to.
var Version = "dev"

var rootCmd = &cobra.Command{
	Use:     "managoat",
	Version: Version,
	Short:   "Managoat CLI",
	Long: `Managoat CLI.

Credentials are read from MANAGOAT_API_KEY env var or ~/.managoat/credentials.
Use MANAGOAT_PROFILE or --profile to select a non-default profile.`,
	SilenceUsage:  true,
	SilenceErrors: true,
}

func Execute() {
	if err := rootCmd.Execute(); err != nil {
		Fatal(err.Error())
	}
}

func init() {
	rootCmd.PersistentFlags().StringVar(&profileFlag, "profile", "", "credentials profile name")
}

// Fatal prints "managoat: <msg>" to stderr and exits 1.
func Fatal(msg string) {
	fmt.Fprintln(os.Stderr, "managoat: "+msg)
	os.Exit(1)
}

// Fatalf is Fatal with format args.
func Fatalf(format string, a ...any) {
	Fatal(fmt.Sprintf(format, a...))
}
