### Changed

- The two service-specific quirks the OAuth client used to ask
  `Fountain.Connections.Platform` about (Google's offline authorize
  parameters, Slack's `user_scope` and `authed_user`-nested token body) are
  fields on `Fountain.Connections.Provider` now (`authorize_params`,
  `token_body_nest`), so the client names no service (#2152).
