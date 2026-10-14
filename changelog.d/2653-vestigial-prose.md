### Fixed

- **Text left behind by the credits and simplify removals is corrected**
  (#2653). The operator runbook served at `/help` names the deployment-wide
  fleet ceiling instead of a per-account quota, and points at `deploy/k8s/`
  for the kustomization, alert rules and backup CronJob. The bundled
  `fountain` skill describes a self-hosted instance. The manual's services
  overview documents the platform inference keys, and no page describes
  credits, a balance or a per-account sandbox cap any more.
