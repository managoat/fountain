### Added

- **One command verifies a deployed Fountain** (#1612).
  `scripts/verify-deployment.sh https://your-instance.example.com` runs the
  deployed-instance suite against that URL and prints the verdict: the failing
  checks, how many fixtures were left behind and where the evidence landed.
  A second argument selects coverage, from `probe` up to the default
  `streaming`, which completes two real tool-using turns and checks live
  output, reconnect, replay and paginated history. The integration profiles
  keep their existing target-file route through `deployed/cli.mjs`. It reads
  `FOUNTAIN_SUITE_KEY` and `FOUNTAIN_SUITE_OTHER_KEY` from the environment,
  falling back to the macOS keychain, so a routine run puts no credential in
  shell history. `node deployed/verify.mjs --help` covers the flags, and
  `deployed/cli.mjs` still takes a hand-authored target file for a run the
  flags do not cover.
- Provisioning the two test accounts a run needs is now written down, in
  `deployed/README.md`, including the verification gate on minting a key, what
  onboarding creates behind you and the Connections requirement the
  integration profiles carry (#1612).
