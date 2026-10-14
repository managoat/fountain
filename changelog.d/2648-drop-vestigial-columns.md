### Upgrade notes

- **A migration drops six unread columns** (#2648, migration `20261013200000`):
  `users.onboarding_completed_at`, `users.conversations_roots_only`,
  `users.conversation_visible_streams`, `users.conversation_view_mode`,
  `sandboxes.applied_skills` and `sandboxes.provider_instance_id` with its
  unique index. Upgrade to this release only after the release that stopped
  mapping the user preference columns and `provider_instance_id` is fully
  rolled out: replicas of the release before it select those columns on
  every user and sandbox load.
