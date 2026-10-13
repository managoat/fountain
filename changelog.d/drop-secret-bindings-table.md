### Upgrade notes

- **A migration drops the credential bindings table** (#1090). Migration
  `20261013093000` drops `secret_bindings`, which the release removing
  credential bindings left in place, unread, for one release. Take it only
  once that release is fully rolled out: a rolling deploy straight from an
  older release would fail its old replicas' brokered provisions until they
  are replaced.
