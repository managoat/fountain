package cmd

import (
	"fmt"
	"os"
	"sort"
	"strings"

	"github.com/managoat/fountain/cli/api"
	"github.com/managoat/fountain/cli/internal/manifest"
	"github.com/managoat/fountain/cli/internal/secrets"
	"github.com/managoat/fountain/cli/internal/substitution"
	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(newApplyCmd())
}

func newApplyCmd() *cobra.Command {
	applyCmd := &cobra.Command{
		Use:   "apply",
		Short: "Apply resource definitions from a YAML file or directory",
		RunE:  runApply,
	}
	applyCmd.Flags().StringP("file", "f", "", "path to YAML file or directory")
	applyCmd.Flags().StringArray("var", nil, "extra variable for ${VAR} substitution (KEY=VAL, repeatable)")
	return applyCmd
}

func runApply(cmd *cobra.Command, args []string) error {
	path, _ := cmd.Flags().GetString("file")
	if path == "" && len(args) > 0 {
		path = args[0]
	}
	if path == "" {
		Fatal("usage: fountain apply -f <path-to-yaml> [--var KEY=VAL ...]")
	}

	varFlags, _ := cmd.Flags().GetStringArray("var")
	applyVars := buildApplyVars(varFlags)

	docs, err := manifest.Read(path)
	if err != nil {
		Fatal(err.Error())
	}

	grouped, unknown := groupDocs(docs)
	if len(unknown) > 0 {
		names := make([]string, len(unknown))
		for i, d := range unknown {
			names[i] = d.Kind
		}
		Fatalf("unsupported kinds in %s: %s", path, strings.Join(names, ", "))
	}

	grouped["Environment"], grouped["Vault"] = expandApplySecrets(grouped["Environment"], grouped["Vault"], applyVars)

	c := activeClient()

	results, err := postApply(c, buildApplyPayload(grouped))
	if err != nil {
		if api.StatusCode(err) == 404 {
			return fmt.Errorf("apply requires Fountain server v0.3.0 or later: POST /api/apply was not found; upgrade the server or check FOUNTAIN_BASE_URL: %w", err)
		}
		return fmt.Errorf("apply failed: %w", err)
	}

	if renderApplyResults(results) {
		os.Exit(1)
	}
	return nil
}

// ── bulk apply ─────────────────────────────────────────────────────────

// applyKindOrder is the order the server reconciles in, and the order the
// payload is built in so the printed output reads the same way. A document
// may name another whatever the file's order: an agent's `spec.environment`,
// a teammate's `spec.agent`/`environment`/`vault`, a schedule's
// `spec.teammate`. The server resolves each by name, including against records
// that already exist and are not part of this manifest.
var applyKindOrder = []string{"Environment", "Vault", "Agent", "Teammate", "Schedule"}

// applyResource is one compiled manifest document. The whole manifest is
// sent to POST /api/apply in a single request.
type applyResource struct {
	Kind string         `json:"kind"`
	Name string         `json:"name"`
	Spec map[string]any `json:"spec"`
}

type applySecretResult struct {
	Key    string         `json:"key"`
	Action string         `json:"action"`
	Errors map[string]any `json:"errors"`
}

type applyResult struct {
	Kind    string              `json:"kind"`
	Name    string              `json:"name"`
	Action  string              `json:"action"`
	Errors  map[string]any      `json:"errors"`
	Secrets []applySecretResult `json:"secrets"`
}

func buildApplyPayload(grouped map[string][]*manifest.Doc) []applyResource {
	var out []applyResource
	for _, kind := range applyKindOrder {
		for _, d := range grouped[kind] {
			name := requireName(d)
			spec := cloneMap(d.Spec)
			// Ownership fields are server-assigned; don't transmit fields the
			// server is just going to drop.
			delete(spec, "id")
			delete(spec, "user_id")
			delete(spec, "created_by")
			out = append(out, applyResource{Kind: d.Kind, Name: name, Spec: spec})
		}
	}
	return out
}

func postApply(c *api.Client, resources []applyResource) ([]applyResult, error) {
	var resp struct {
		Data struct {
			Results []applyResult `json:"results"`
		} `json:"data"`
	}
	body := map[string]any{"resources": resources}
	if err := c.Post("/apply", body, &resp); err != nil {
		return nil, err
	}
	return resp.Data.Results, nil
}

var applyKindLabels = map[string]string{
	"Environment": "env",
	"Vault":       "vault",
	"Agent":       "agent",
}

// renderApplyResults prints one line per resource (`+` create, `~` update,
// `=` no change, `!` error to stderr) and reports whether any resource or
// secret failed.
func renderApplyResults(results []applyResult) (anyFailed bool) {
	for _, r := range results {
		label := applyKindLabels[r.Kind]
		if label == "" {
			label = strings.ToLower(r.Kind)
		}
		switch r.Action {
		case "created":
			fmt.Printf("%s  +  %s\n", label, r.Name)
		case "updated":
			fmt.Printf("%s  ~  %s\n", label, r.Name)
		case "unchanged":
			fmt.Printf("%s  =  %s\n", label, r.Name)
		default:
			anyFailed = true
			warnf("%s  !  %s: %s", label, r.Name, formatResultErrors(r.Errors))
		}
		for _, s := range r.Secrets {
			if s.Action == "upserted" {
				fmt.Printf("  secret  ~  %s/%s\n", r.Name, s.Key)
			} else {
				anyFailed = true
				warnf("  secret  !  %s/%s: %s", r.Name, s.Key, formatResultErrors(s.Errors))
			}
		}
	}
	return anyFailed
}

func formatResultErrors(errs map[string]any) string {
	if len(errs) == 0 {
		return "apply failed"
	}
	parts := make([]string, 0, len(errs))
	for _, k := range sortedKeys(errs) {
		parts = append(parts, fmt.Sprintf("%s: %v", k, errs[k]))
	}
	return strings.Join(parts, "; ")
}

// ── grouping ───────────────────────────────────────────────────────────

// groupDocs buckets the parsed documents by kind. The returned map is keyed
// by the kind name, so a caller reads it in applyKindOrder; anything outside
// that list comes back in `unknown` and stops the run.
func groupDocs(docs []*manifest.Doc) (grouped map[string][]*manifest.Doc, unknown []*manifest.Doc) {
	grouped = map[string][]*manifest.Doc{}
	known := map[string]bool{}
	for _, kind := range applyKindOrder {
		known[kind] = true
	}
	for _, d := range docs {
		if known[d.Kind] {
			grouped[d.Kind] = append(grouped[d.Kind], d)
		} else {
			unknown = append(unknown, d)
		}
	}
	return grouped, unknown
}

// ── apply-time secret resolution ───────────────────────────────────────

func buildApplyVars(varFlags []string) map[string]string {
	out := map[string]string{}
	for _, kv := range os.Environ() {
		if eq := strings.IndexByte(kv, '='); eq > 0 {
			out[kv[:eq]] = kv[eq+1:]
		}
	}
	for _, kv := range varFlags {
		eq := strings.IndexByte(kv, '=')
		if eq <= 0 {
			Fatalf("--var must be KEY=VALUE, got: %q", kv)
		}
		out[kv[:eq]] = kv[eq+1:]
	}
	return out
}

// expandApplySecrets runs the two-phase resolution (substitution then
// external refs) across both env and vault doc lists, collecting all
// failures across both before exiting. Returns the same docs with
// `spec.secrets` rewritten in place.
func expandApplySecrets(envs, vaults []*manifest.Doc, vars map[string]string) ([]*manifest.Doc, []*manifest.Doc) {
	all := append([]*manifest.Doc{}, envs...)
	all = append(all, vaults...)

	substErrors := map[string][]string{}
	for _, d := range all {
		if err := substituteDocSecrets(d, vars); err != nil {
			if me, ok := err.(*substitution.MissingVarsError); ok {
				substErrors[d.Name()] = me.Missing
			}
		}
	}
	if len(substErrors) > 0 {
		Fatal(formatMissingVars(substErrors))
	}

	resolverErrors := map[string][]resolverFailure{}
	for _, d := range all {
		if fails := resolveDocExternalRefs(d, secrets.Default); len(fails) > 0 {
			resolverErrors[d.Name()] = fails
		}
	}
	if len(resolverErrors) > 0 {
		Fatal(formatResolverFailures(resolverErrors))
	}

	return envs, vaults
}

func substituteDocSecrets(d *manifest.Doc, vars map[string]string) error {
	if d.Spec == nil {
		return nil
	}
	raw, ok := d.Spec["secrets"]
	if !ok {
		return nil
	}
	subbed, err := substitution.Apply(raw, vars)
	if err != nil {
		return err
	}
	d.Spec["secrets"] = subbed
	return nil
}

type resolverFailure struct {
	Key   string
	Ref   string
	Mod   secrets.Resolver
	Err   error
	Empty bool
}

func resolveDocExternalRefs(d *manifest.Doc, resolvers []secrets.Resolver) []resolverFailure {
	if d.Spec == nil {
		return nil
	}
	raw, ok := d.Spec["secrets"]
	if !ok {
		return nil
	}
	secMap, ok := raw.(map[string]any)
	if !ok {
		return nil
	}
	var fails []resolverFailure
	resolved := make(map[string]any, len(secMap))

	keys := sortedKeys(secMap)
	for _, k := range keys {
		v := secMap[k]
		s, isStr := v.(string)
		if !isStr {
			resolved[k] = v
			continue
		}
		mod := secrets.ForValue(s, resolvers)
		if mod == nil {
			resolved[k] = v
			continue
		}
		plaintext, err := mod.Read(s)
		if err != nil {
			fails = append(fails, resolverFailure{Key: k, Ref: s, Mod: mod, Err: err})
			continue
		}
		if plaintext == "" {
			// An empty value back from an external CLI nearly always means
			// "secret not found" — surface as a failure rather than silently
			// writing "" and letting the API 422 us later.
			fails = append(fails, resolverFailure{Key: k, Ref: s, Mod: mod, Empty: true})
			continue
		}
		resolved[k] = plaintext
	}
	d.Spec["secrets"] = resolved
	return fails
}

func formatMissingVars(perDoc map[string][]string) string {
	var b strings.Builder
	b.WriteString("apply-time substitution failed — set these in the env or pass --var KEY=VAL:\n")
	for _, name := range sortedStringKeys(perDoc) {
		fmt.Fprintf(&b, "  %s: %s\n", name, strings.Join(perDoc[name], ", "))
	}
	return strings.TrimRight(b.String(), "\n")
}

func formatResolverFailures(perDoc map[string][]resolverFailure) string {
	var b strings.Builder
	b.WriteString("apply-time secret resolution failed:\n")
	for _, name := range sortedStringKeys(perDoc) {
		fmt.Fprintf(&b, "  %s:\n", name)
		for _, f := range perDoc[name] {
			msg := ""
			if f.Empty {
				msg = "resolver returned an empty value (secret missing or wrong env/path?)"
			} else {
				msg = f.Mod.FormatError(f.Err)
			}
			fmt.Fprintf(&b, "    %s (%s): %s\n", f.Key, f.Ref, msg)
		}
	}
	return strings.TrimRight(b.String(), "\n")
}

func sortedStringKeys[V any](m map[string]V) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func sortedKeys(m map[string]any) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func requireName(d *manifest.Doc) string {
	n := d.Name()
	if n == "" {
		Fatalf("resource missing required `metadata.name`: %s/%s", d.APIVersion, d.Kind)
	}
	return n
}

func cloneMap(m map[string]any) map[string]any {
	if m == nil {
		return map[string]any{}
	}
	out := make(map[string]any, len(m))
	for k, v := range m {
		out[k] = v
	}
	return out
}

func warnf(format string, a ...any) {
	fmt.Fprintln(os.Stderr, fmt.Sprintf(format, a...))
}
