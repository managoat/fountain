### Upgrade notes

- **Breaking: the self-hosted runner sandbox provider is removed** (#2676,
  ADR 0071). Sandboxes run on Sprites or E2B. A migration moves agents pinned to
  `sandbox_provider: runner` to the instance default and marks runner
  sandboxes that were still live as terminated; their conversations stay, and
  the next prompt provisions on the instance default. Nothing is deleted on
  the runner's machine: stop the `fountain runner` daemon there and delete
  the sandbox directories (default `~/.fountain/runners/<name>/sandboxes`) or
  Firecracker VMs it left. `SANDBOX_PROVIDER=runner` now refuses to boot, and
  `SANDBOX_RUNNERS_ENABLED` is no longer read.

### Removed

- The `runner` sandbox provider and its Firecracker backend (#2676): the
  `fountain runner` and `fountain runner-guest` commands, `GET /api/runners`,
  `DELETE /api/runners/:id`, the daemon socket `GET /api/runners/ws`, the
  console's Runners page, and the `managoat_runner` dependency. Requests that
  name `runner` as a `sandbox_provider` are refused at validation.
- From the API (#2676): the `runner` object on a sandbox, the
  `machine_offline` teammate presence state, and the `no_runner_online`,
  `runner_offline` and `sprite_name_not_supported` errors. Sandboxes created
  before the removal still read `provider: "runner"`.
- The agent form's warning for a limited environment on a backend without a
  network policy (#2676). Every shipped provider has one; the server still
  refuses that pairing before provisioning.
