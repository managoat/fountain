package cmd

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"time"

	"github.com/managoat/fountain/cli/internal/config"
	"github.com/managoat/fountain/cli/internal/runner"
	"github.com/spf13/cobra"
)

var (
	runnerName     string
	runnerRoot     string
	runnerLogLevel string
	runnerBackend  string
	fcBinary       string
	fcKernel       string
	fcRootfs       string
	fcVCPUs        int
	fcMemoryMiB    int
	fcBridge       string
	fcSubnet       string
	fcBootTimeoutS int
)

func init() {
	runnerCmd := &cobra.Command{
		Use:   "runner",
		Short: "Turn this machine into a sandbox provider for your Fountain agents",
		Long: `Run this machine as a self-hosted Fountain runner.

The daemon dials out to Fountain (no inbound port, works behind NAT), holds
the connection, and serves sandboxes for agents whose sandbox_provider is
"runner". Two backends decide what a sandbox is made of.

--backend process (the default) is trusted mode: a sandbox is a directory
under --root, and the agent's processes run here, as you, with HOME pointed
at that directory. There is no VM, container or egress policy between the
agent and this machine. Run it on a machine you would hand a capable
colleague a shell on.

--backend firecracker gives each sandbox its own Firecracker microVM, booted
from a private copy of --fc-rootfs, on a tap device attached to --bridge.
Commands run in the guest, reached over vsock; the base rootfs must start
the agent (fountain runner-guest) at boot. Linux, /dev/kvm and CAP_NET_ADMIN required.

Idle sandboxes park without losing the disk, which is the agent's memory:
the process backend stops what is running, and the firecracker backend
pauses the VM. See docs/integrations/runners.md.

Names are unique per account; a second daemon with the same name is refused.
The default name is this machine's hostname.`,
		RunE: func(cmd *cobra.Command, args []string) error { return runRunner() },
	}
	runnerCmd.Flags().StringVar(&runnerName, "name", "", "runner name (default: the hostname, lowercased)")
	runnerCmd.Flags().StringVar(&runnerRoot, "root", "", "sandbox root (default: ~/.fountain/runners/<name>/sandboxes)")
	runnerCmd.Flags().StringVar(&runnerLogLevel, "log-level", "info", "debug|info|warn|error")
	runnerCmd.Flags().StringVar(&runnerBackend, "backend", "process", "process|firecracker — what a sandbox is made of")
	runnerCmd.Flags().StringVar(&fcBinary, "fc-bin", "firecracker", "the firecracker executable")
	runnerCmd.Flags().StringVar(&fcKernel, "fc-kernel", "", "uncompressed guest kernel image (vmlinux)")
	runnerCmd.Flags().StringVar(&fcRootfs, "fc-rootfs", "", "base ext4 rootfs every sandbox starts as a copy of")
	runnerCmd.Flags().IntVar(&fcVCPUs, "fc-vcpus", 2, "vCPUs per microVM")
	runnerCmd.Flags().IntVar(&fcMemoryMiB, "fc-memory-mib", 2048, "memory per microVM, in MiB")
	runnerCmd.Flags().StringVar(&fcBridge, "bridge", "", "host bridge the sandboxes' tap devices join")
	runnerCmd.Flags().StringVar(&fcSubnet, "subnet", "10.61.0.0/24", "IPv4 subnet for guests; its first host address is the bridge")
	runnerCmd.Flags().IntVar(&fcBootTimeoutS, "fc-boot-timeout", 60, "seconds to wait for a microVM's agent to answer")
	rootCmd.AddCommand(runnerCmd)
}

var runnerNameClean = regexp.MustCompile(`[^a-z0-9._-]+`)

// DefaultRunnerName derives a valid runner name from a hostname.
func DefaultRunnerName(hostname string) string {
	name := strings.ToLower(hostname)
	if i := strings.IndexByte(name, '.'); i > 0 {
		name = name[:i]
	}
	name = runnerNameClean.ReplaceAllString(name, "-")
	name = strings.Trim(name, "-._")
	if name == "" {
		name = "runner"
	}
	if len(name) > 63 {
		name = name[:63]
	}
	return name
}

func runRunner() error {
	var level slog.Level
	if err := level.UnmarshalText([]byte(runnerLogLevel)); err != nil {
		return fmt.Errorf("--log-level: %w", err)
	}
	log := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: level}))

	opts := activeOpts()
	token, err := config.APIKey(opts)
	if err != nil {
		return err
	}
	name := runnerName
	if name == "" {
		host, _ := os.Hostname()
		name = DefaultRunnerName(host)
	}
	root := runnerRoot
	if root == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return fmt.Errorf("resolve home directory: %w", err)
		}
		root = filepath.Join(home, ".fountain", "runners", name, "sandboxes")
	}
	root, err = filepath.Abs(root)
	if err != nil {
		return err
	}

	backend, err := runnerBackendFor(root, log)
	if err != nil {
		return err
	}
	d := runner.NewWithBackend(backend, log)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	fmt.Fprintf(os.Stderr, "fountain runner %q (%s): sandboxes in %s, connecting to %s\n",
		name, runnerBackend, root, config.BaseURL(opts))
	err = runner.Run(ctx, runner.Config{
		BaseURL: config.BaseURL(opts),
		Token:   token,
		Name:    name,
		Root:    root,
		Version: Version,
	}, d, log)
	// Sessions belong to this process; when it goes, they go — say so rather
	// than leaving orphans writing into a closed pipe.
	d.StopAll()
	return err
}

// runnerBackendFor builds the backend --backend names. The firecracker
// configuration is validated here rather than at first boot, so a missing
// kernel image is a refusal at startup instead of a conversation that fails
// an hour later.
func runnerBackendFor(root string, log *slog.Logger) (runner.Backend, error) {
	switch runnerBackend {
	case "process":
		return runner.NewProcess(root, log)
	case "firecracker":
		fcnet, err := runner.ParseFCNet(fcBridge, fcSubnet)
		if err != nil {
			return nil, err
		}
		return runner.NewFirecracker(runner.FirecrackerConfig{
			Root:        root,
			Binary:      fcBinary,
			Kernel:      fcKernel,
			BaseRootfs:  fcRootfs,
			VCPUs:       fcVCPUs,
			MemoryMiB:   fcMemoryMiB,
			Net:         fcnet,
			BootTimeout: time.Duration(fcBootTimeoutS) * time.Second,
		}, log)
	default:
		return nil, fmt.Errorf("--backend must be process or firecracker, got %q", runnerBackend)
	}
}
