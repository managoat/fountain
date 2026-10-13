### Added

- `FORCE_SSL_EXCLUDE_HOSTS` names hosts that the HTTPS redirect and HSTS leave
  alone, for callers inside the deployment's network that reach the app over
  plain HTTP at its service name (a Kubernetes Service). Before, they got a 301
  to `https://` on a host that serves nothing there. `localhost` stays
  excluded.
