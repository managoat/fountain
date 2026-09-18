### Fixed

- **A brokered conversation now provisions on a self-hosted runner** (#2057).
  Installing the broker CA used `sudo` and `update-ca-certificates`. A runner
  sandbox runs as the machine's user with no root, so every launch failed
  with `ca_install_exit` and `sudo: a password is required`. On a runner, the
  CA and a bundle of the machine's own roots plus the CA are now written
  inside the sandbox, under `~/.fountain/broker/`. The sandbox's CA
  variables (`NODE_EXTRA_CA_CERTS`, `SSL_CERT_FILE` and the rest) point at
  their real paths on that machine. The machine's own trust store is never
  changed. Other providers install into the OS trust store as before.
