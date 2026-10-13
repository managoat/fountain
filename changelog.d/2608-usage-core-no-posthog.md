### Upgrade notes

- **`POSTHOG_*` variables are no longer read** (#2608):
  `POSTHOG_PROJECT_API_KEY`, `POSTHOG_HOST`, `POSTHOG_CAPTURE`,
  `POSTHOG_PERSON_PII`, `POSTHOG_BROWSER_CAPTURE` and `POSTHOG_INSTANCE`.
  Remove them from your configuration.

### Removed

- **Product analytics** (#2608). Fountain sends no events to PostHog, and the
  public pages load no PostHog script and record no sessions. The audit trail
  and the Prometheus metrics are unchanged.
- **The lifecycle funnel** (#2608): the funnel tile on `/admin`, the
  `fountain.funnel.*` metrics and the funnel panels on the Grafana product
  dashboard. The verified landing at `/start` is unchanged, and onboarding
  still completes at an account's first reply.

### Changed

- The welcome email no longer mentions credit (#2608).
