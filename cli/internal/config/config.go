// Package config resolves the API key and base URL for the active profile.
//
// API key precedence:
//  1. MANAGOAT_API_KEY env var
//  2. api_key from ~/.managoat/credentials (active profile)
//
// Base URL precedence:
//  1. MANAGOAT_BASE_URL env var
//  2. base_url from ~/.managoat/credentials (active profile)
//  3. compile-time default (https://managoat.com)
package config

import (
	"errors"
	"strings"

	"github.com/managoat/managoat/cli/internal/credentials"
	"github.com/managoat/managoat/cli/internal/env"
)

// DefaultBaseURL is the hosted instance, kept as the fallback deliberately
// (#498): the hosted service is the primary audience. Self-hosters must point
// the CLI at their own instance (MANAGOAT_BASE_URL, recorded by `auth login`)
// before exporting MANAGOAT_API_KEY — docs/cli.md and docs/guides/operate/upgrade.md
// call the footgun out.
const DefaultBaseURL = "https://managoat.com"

// ErrNoAPIKey signals that no API key is configured.
var ErrNoAPIKey = errors.New("MANAGOAT_API_KEY is not set. Run `managoat auth login` or export the MANAGOAT_API_KEY environment variable.")

// APIKey resolves the API key for opts. Returns ErrNoAPIKey if none.
func APIKey(opts credentials.Opts) (string, error) {
	if k := env.Get("MANAGOAT_API_KEY"); k != "" {
		return k, nil
	}
	profile := credentials.ProfileName(opts)
	attrs, err := credentials.ReadProfile(profile)
	if err != nil {
		return "", err
	}
	if k := attrs["api_key"]; k != "" {
		return k, nil
	}
	return "", ErrNoAPIKey
}

// BaseURL resolves the base URL for opts (trailing slash stripped).
func BaseURL(opts credentials.Opts) string {
	if u := env.Get("MANAGOAT_BASE_URL"); u != "" {
		return strings.TrimRight(u, "/")
	}
	profile := credentials.ProfileName(opts)
	if attrs, err := credentials.ReadProfile(profile); err == nil {
		if u := attrs["base_url"]; u != "" {
			return strings.TrimRight(u, "/")
		}
	}
	return strings.TrimRight(DefaultBaseURL, "/")
}
