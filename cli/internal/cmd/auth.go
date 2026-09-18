package cmd

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"runtime"
	"strings"
	"time"

	"github.com/managoat/fountain/cli/api"
	"github.com/managoat/fountain/cli/config"
	"github.com/managoat/fountain/cli/credentials"
	"github.com/spf13/cobra"
	"golang.org/x/term"
)

func init() {
	authCmd := &cobra.Command{
		Use:   "auth",
		Short: "Authenticate against the Fountain API",
	}
	loginCmd := &cobra.Command{
		Use:   "login",
		Short: "Authenticate and save credentials",
		RunE: func(cmd *cobra.Command, args []string) error {
			withAPIKey, _ := cmd.Flags().GetBool("api-key")
			withDevice, _ := cmd.Flags().GetBool("device")
			withPassword, _ := cmd.Flags().GetBool("password")

			mode, err := loginMode(withAPIKey, withDevice, withPassword,
				term.IsTerminal(int(os.Stdin.Fd())))
			if err != nil {
				Fatal(err.Error())
			}
			switch mode {
			case loginModeAPIKey:
				return authLoginAPIKey()
			case loginModeDevice:
				return authLoginDevice()
			default:
				return authLogin()
			}
		},
	}
	loginCmd.Flags().Bool("device", false,
		"sign in by approving this device in your browser (the default on a terminal)")
	loginCmd.Flags().Bool("password", false,
		"sign in with email + password (the default when stdin is piped)")
	loginCmd.Flags().Bool("api-key", false,
		"paste an API key you created in the console")
	registerCmd := &cobra.Command{
		Use:   "register",
		Short: "Create an account, wait for the emailed link, and save the key",
		Long: "The terminal half of ADR 0038's path. Creates the account, waits " +
			"while you click the link in your email, saves the API key, and prints " +
			"the same first request the start page shows.",
		RunE: func(cmd *cobra.Command, args []string) error {
			email, _ := cmd.Flags().GetString("email")
			password, _ := cmd.Flags().GetString("password")
			accessCode, _ := cmd.Flags().GetString("access-code")
			return authRegister(email, password, accessCode)
		},
	}
	registerCmd.Flags().String("email", "", "email address (prompted for when omitted)")
	registerCmd.Flags().String("password", "", "password (prompted for when omitted, which keeps it out of shell history)")
	registerCmd.Flags().String("access-code", "", "the instance's signup access code, when its operator set one")

	authCmd.AddCommand(
		loginCmd,
		registerCmd,
		&cobra.Command{
			Use:   "logout",
			Short: "Remove saved credentials",
			RunE:  func(cmd *cobra.Command, args []string) error { return authLogout() },
		},
		&cobra.Command{
			Use:   "whoami",
			Short: "Print current user info",
			RunE:  func(cmd *cobra.Command, args []string) error { return authWhoami() },
		},
	)
	rootCmd.AddCommand(authCmd)
}

// deviceFallbackAccepted reads the [Y/n] answer to the post-401 offer:
// enter and anything starting with y mean yes.
func deviceFallbackAccepted(answer string) bool {
	answer = strings.ToLower(strings.TrimSpace(answer))
	return answer == "" || strings.HasPrefix(answer, "y")
}

const (
	loginModeAPIKey   = "api-key"
	loginModeDevice   = "device"
	loginModePassword = "password"
)

// loginMode picks the flow for `auth login`. At most one flag may force one;
// with none, a terminal gets the device flow — it works for every account,
// including "Sign up with GitHub" ones that have no password to type (#1305),
// so there is nothing to detect and no wrong default. Piped stdin keeps the
// email + password read, so a script that feeds credentials is unchanged.
func loginMode(apiKey, device, password, stdinTTY bool) (string, error) {
	forced := 0
	for _, f := range []bool{apiKey, device, password} {
		if f {
			forced++
		}
	}
	if forced > 1 {
		return "", fmt.Errorf("--device, --password and --api-key are different login flows; pick one")
	}
	switch {
	case apiKey:
		return loginModeAPIKey, nil
	case device:
		return loginModeDevice, nil
	case password:
		return loginModePassword, nil
	case stdinTTY:
		return loginModeDevice, nil
	default:
		return loginModePassword, nil
	}
}

func authLogin() error {
	opts := activeOpts()
	profile := credentials.ProfileName(opts)

	email, err := promptLine("Email: ")
	if err != nil {
		return err
	}
	password, err := promptPassword("Password: ")
	if err != nil {
		return err
	}

	base := config.BaseURL(opts)
	body, err := json.Marshal(map[string]string{"email": email, "password": password})
	if err != nil {
		return err
	}

	req, err := http.NewRequestWithContext(context.Background(), http.MethodPost, base+"/api/auth/token", bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")

	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		Fatalf("request failed: %v", err)
	}
	defer resp.Body.Close()

	respBody, _ := io.ReadAll(resp.Body)
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		// The server answers every bad credential with the same 401 on
		// purpose (anti-enumeration, #324) — an account created with "Sign
		// up with GitHub" has no password and lands here too, and the CLI
		// cannot tell the two apart. It does not need to: the device flow
		// works for both, so on a terminal offer it instead of erroring.
		if resp.StatusCode == http.StatusUnauthorized {
			fmt.Fprintf(os.Stderr, "fountain: login failed (HTTP %d): %s\n\n", resp.StatusCode, respBody)
			fmt.Fprintln(os.Stderr, "If you signed up with GitHub, your account has no password.")
			if term.IsTerminal(int(os.Stdin.Fd())) {
				answer, perr := promptLine("Sign in through your browser instead? [Y/n] ")
				if perr == nil && deviceFallbackAccepted(answer) {
					return authLoginDevice()
				}
			}
			Fatalf("run `fountain auth login --device` to sign in through your browser,\n"+
				"or create an API key in the console (%s/api-keys) and run\n"+
				"`fountain auth login --api-key`.", base)
		}
		Fatalf("login failed (HTTP %d): %s", resp.StatusCode, respBody)
	}

	key := extractAPIKey(respBody)
	if key == "" {
		Fatalf("unexpected login response: %s", respBody)
	}

	if err := credentials.WriteProfile(profile, map[string]string{
		"api_key":  key,
		"base_url": base,
	}); err != nil {
		return err
	}

	fmt.Printf("Logged in as %s. Credentials written to ~/.fountain/credentials (profile: %s).\n", email, profile)
	return nil
}

// authLoginAPIKey is `auth login --api-key`: the login path for accounts that
// sign in with GitHub and therefore have no password to exchange at
// /api/auth/token (#1305). The key is prompted for, never taken as a flag
// value, so it stays out of shell history; the prompt is hidden on a TTY and
// falls back to a plain stdin read so `echo $KEY | fountain auth login
// --api-key` works in scripts.
func authLoginAPIKey() error {
	opts := activeOpts()
	profile := credentials.ProfileName(opts)
	base := config.BaseURL(opts)

	key, err := promptPassword("API key: ")
	if err != nil {
		return err
	}
	key = strings.TrimSpace(key)
	if key == "" {
		Fatal("no API key given. Create one in the console at " + base + "/api-keys.")
	}

	// Validate before writing, so a mispasted key fails here rather than on
	// the next command.
	me, err := fetchAuthMe(base, key)
	if err != nil {
		Fatalf("could not verify the API key against %s: %v", base, err)
	}

	if err := credentials.WriteProfile(profile, map[string]string{
		"api_key":  key,
		"base_url": base,
	}); err != nil {
		return err
	}

	fmt.Printf("Logged in as %s. Credentials written to ~/.fountain/credentials (profile: %s).\n", me.Email, profile)
	return nil
}

// authLoginDevice is `auth login --device`: the RFC-8628-shaped flow (#1305).
// Works for every account, and is the only interactive option for one created
// with "Sign up with GitHub" — no password exists to exchange. The CLI starts
// a grant, sends the human to the console's /device page with a short code,
// and polls until they approve; the server then mints an API key that is
// written to ~/.fountain/credentials like any other login.
func authLoginDevice() error {
	opts := activeOpts()
	profile := credentials.ProfileName(opts)
	base := config.BaseURL(opts)

	grant, err := startDeviceGrant(base)
	if err != nil {
		Fatalf("could not start a device login against %s: %v", base, err)
	}

	fmt.Printf("First, note your one-time code: %s\n\n", grant.UserCode)
	fmt.Printf("Then approve this device at: %s\n", grant.VerificationURI)
	// Only reach for a browser on a real terminal; scripts and tests get the
	// printed URL and nothing else.
	if term.IsTerminal(int(os.Stdout.Fd())) && openBrowser(grant.VerificationURIComplete) {
		fmt.Println("(opened in your browser)")
	}
	fmt.Println("\nWaiting for approval...")

	key, err := pollDeviceGrant(base, grant)
	if err != nil {
		Fatal(err.Error())
	}

	// The email is cosmetic; the key is already proven by the mint itself.
	email := "you"
	if me, err := fetchAuthMe(base, key); err == nil && me.Email != "" {
		email = me.Email
	}

	if err := credentials.WriteProfile(profile, map[string]string{
		"api_key":  key,
		"base_url": base,
	}); err != nil {
		return err
	}

	fmt.Printf("Logged in as %s. Credentials written to ~/.fountain/credentials (profile: %s).\n", email, profile)
	return nil
}

// deviceGrant mirrors FountainWeb.DeviceAuthController.create/2.
type deviceGrant struct {
	DeviceCode              string `json:"device_code"`
	UserCode                string `json:"user_code"`
	VerificationURI         string `json:"verification_uri"`
	VerificationURIComplete string `json:"verification_uri_complete"`
	ExpiresIn               int    `json:"expires_in"`
	Interval                int    `json:"interval"`
}

func startDeviceGrant(base string) (*deviceGrant, error) {
	req, err := http.NewRequestWithContext(context.Background(), http.MethodPost, base+"/api/auth/device", strings.NewReader("{}"))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")

	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	respBody, _ := io.ReadAll(resp.Body)
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		if resp.StatusCode == http.StatusNotFound {
			return nil, fmt.Errorf("HTTP 404 — this server does not support device login yet; use `fountain auth login --api-key` instead")
		}
		return nil, fmt.Errorf("HTTP %d: %s", resp.StatusCode, respBody)
	}

	var grant deviceGrant
	if err := json.Unmarshal(respBody, &grant); err != nil || grant.DeviceCode == "" || grant.UserCode == "" {
		return nil, fmt.Errorf("unexpected response: %s", respBody)
	}
	return &grant, nil
}

// deviceSleep is swapped out by tests so the poll loop's pacing is
// observable without waiting it out.
var deviceSleep = time.Sleep

// pollDeviceGrant polls until the grant is decided or times out, returning
// the minted API key. The pacing is the server's: `interval` seconds between
// polls, plus five more whenever it answers slow_down (RFC 8628 §3.5).
func pollDeviceGrant(base string, grant *deviceGrant) (string, error) {
	interval := grant.Interval
	expiresIn := grant.ExpiresIn
	if expiresIn <= 0 {
		expiresIn = 900
	}
	deadline := time.Now().Add(time.Duration(expiresIn) * time.Second)

	client := &http.Client{Timeout: 30 * time.Second}
	body, _ := json.Marshal(map[string]string{"device_code": grant.DeviceCode})

	for time.Now().Before(deadline) {
		req, err := http.NewRequestWithContext(context.Background(), http.MethodPost, base+"/api/auth/device/token", bytes.NewReader(body))
		if err != nil {
			return "", err
		}
		req.Header.Set("Content-Type", "application/json")

		resp, err := client.Do(req)
		if err != nil {
			return "", err
		}
		respBody, _ := io.ReadAll(resp.Body)
		resp.Body.Close()

		if resp.StatusCode >= 200 && resp.StatusCode < 300 {
			if key := extractAPIKey(respBody); key != "" {
				return key, nil
			}
			return "", fmt.Errorf("unexpected token response: %s", respBody)
		}

		var errResp struct {
			Error string `json:"error"`
		}
		_ = json.Unmarshal(respBody, &errResp)

		switch errResp.Error {
		case "authorization_pending":
			// keep waiting
		case "slow_down":
			interval += 5
		case "access_denied":
			return "", fmt.Errorf("the request was denied in the console; no key was created")
		case "expired_token":
			return "", fmt.Errorf("the code expired before it was approved — run `fountain auth login --device` again")
		default:
			return "", fmt.Errorf("device login failed (HTTP %d): %s", resp.StatusCode, respBody)
		}

		deviceSleep(time.Duration(interval) * time.Second)
	}
	return "", fmt.Errorf("timed out waiting for approval — run `fountain auth login --device` again")
}

// openBrowser best-effort opens url in the user's browser; false means the
// user follows the printed URL by hand.
func openBrowser(url string) bool {
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "darwin":
		cmd = exec.Command("open", url)
	case "windows":
		cmd = exec.Command("rundll32", "url.dll,FileProtocolHandler", url)
	default:
		cmd = exec.Command("xdg-open", url)
	}
	return cmd.Start() == nil
}

// fetchAuthMe checks a raw key against GET /api/auth/me. It cannot go through
// api.Client, which resolves its key from the environment and the credentials
// file — exactly what this key has not been written to yet.
func fetchAuthMe(base, key string) (*authMe, error) {
	req, err := http.NewRequestWithContext(context.Background(), http.MethodGet, base+"/api/auth/me", nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+key)

	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	respBody, _ := io.ReadAll(resp.Body)
	if resp.StatusCode == http.StatusUnauthorized {
		return nil, fmt.Errorf("the server rejected the key (HTTP 401)")
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("HTTP %d: %s", resp.StatusCode, respBody)
	}

	var me authMe
	if err := json.Unmarshal(respBody, &me); err != nil {
		return nil, fmt.Errorf("unexpected response: %s", respBody)
	}
	return &me, nil
}

// extractAPIKey accepts any of the four shapes the server has returned:
// {data:{api_key}}, {data:{token}}, {api_key}, {token}.
func extractAPIKey(body []byte) string {
	var top struct {
		Data struct {
			APIKey string `json:"api_key"`
			Token  string `json:"token"`
		} `json:"data"`
		APIKey string `json:"api_key"`
		Token  string `json:"token"`
	}
	if json.Unmarshal(body, &top) != nil {
		return ""
	}
	switch {
	case top.Data.APIKey != "":
		return top.Data.APIKey
	case top.Data.Token != "":
		return top.Data.Token
	case top.APIKey != "":
		return top.APIKey
	case top.Token != "":
		return top.Token
	}
	return ""
}

func authLogout() error {
	profile := credentials.ProfileName(activeOpts())
	if err := credentials.DeleteProfile(profile); err != nil {
		return err
	}
	fmt.Printf("Profile '%s' removed from ~/.fountain/credentials.\n", profile)
	return nil
}

// authMe mirrors FountainWeb.AuthMeController.show/2
// (apps/fountain/lib/fountain_web/controllers/auth_me_controller.ex): a flat
// object, no `data` envelope.
type authMe struct {
	ID    string `json:"id"`
	Email string `json:"email"`
	Role  string `json:"role"`
}

func authWhoami() error {
	c := activeClient()
	profile := credentials.ProfileName(activeOpts())

	var out authMe
	if err := c.Get("/auth/me", &out); err != nil {
		if api.StatusCode(err) == 401 {
			Fatalf("not authenticated for profile '%s'. Run `fountain auth login --profile %s`.", profile, profile)
		}
		Fatal(err.Error())
	}
	fmt.Printf("email: %s\n", out.Email)
	fmt.Printf("role:  %s\n", out.Role)
	return nil
}

func promptLine(label string) (string, error) {
	fmt.Print(label)
	r := bufio.NewReader(os.Stdin)
	line, err := r.ReadString('\n')
	if err != nil && err != io.EOF {
		return "", err
	}
	return strings.TrimRight(line, "\r\n"), nil
}

func promptPassword(label string) (string, error) {
	fmt.Print(label)
	if term.IsTerminal(int(os.Stdin.Fd())) {
		buf, err := term.ReadPassword(int(os.Stdin.Fd()))
		fmt.Println()
		if err != nil {
			return "", err
		}
		return strings.TrimRight(string(buf), "\r\n"), nil
	}
	// Non-TTY: fall back to plain read so piped tests work.
	return promptLine("")
}
