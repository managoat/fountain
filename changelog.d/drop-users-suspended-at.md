### Upgrade notes

- **`users.suspended_at` is dropped** (#287). Upgrade to the release that
  removed account suspension first, and let it roll out fully before taking
  this one: a replica of an older release still reads the column.
