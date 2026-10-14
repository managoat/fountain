### Upgrade notes

- **Inference credential sets are collapsed to one record per account**
  (#2658). Migration `20261014120000` keeps each account's default set and
  deletes its other sets with the keys they held; re-enter any key you still
  need at `/account/inference-credentials`. A conversation bound to a deleted
  set is refused at its next prompt with `409 inference_source_changed`. The
  set columns stay one release for a rolling upgrade; a later release drops
  them. See
  [Upgrade an instance](https://managoat.com/docs/guides/operate/upgrade#credential-sets-collapsed-to-one-record).

### Removed

- The `/api/account/inference-credential-sets` routes, the set controls on
  the inference credentials page and the agent form's set picker (#2658).
  Agents and launches ignore `inference_credential_id` and
  `allowed_inference_credential_ids`. `/api/account/inference-credentials`
  manages an account's keys. The `inference_credential_set.*` audit events
  are no longer recorded. Replacing a key still ends the conversations bound
  to the old one at their next turn.
