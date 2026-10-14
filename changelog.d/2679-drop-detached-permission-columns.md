### Upgrade notes

- **The detached permission columns are dropped** (#2679). Migration
  `20261014153000` removes `waiting` and `permission_deadline` from `turns`,
  and strips any `ask_timeout` key from stored permission policies. Take it
  only after the release that removed requests outliving their turn (#2677)
  is fully rolled out.
