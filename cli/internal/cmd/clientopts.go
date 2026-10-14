package cmd

import (
	"github.com/managoat/fountain/cli/internal/api"
	"github.com/managoat/fountain/cli/internal/credentials"
)

// activeOpts builds credentials.Opts from the parsed --profile flag.
func activeOpts() credentials.Opts {
	return credentials.Opts{Profile: profileFlag}
}

// activeClient builds a Client bound to the active profile.
func activeClient() *api.Client {
	return api.New(activeOpts())
}
