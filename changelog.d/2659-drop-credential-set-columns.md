### Upgrade notes

- **The inference credential set columns are dropped** (#2659). Migration
  `20261014140000` removes `name` and `is_default` from
  `inference_credentials` and restores its unique key on `user_id`, and
  drops the set pointers and policies from agents, agent versions and
  conversations. Take it only after the release that collapsed the sets
  (#2658) is fully rolled out. See
  [Upgrade an instance](https://managoat.com/docs/guides/operate/upgrade#credential-sets-collapsed-to-one-record).
