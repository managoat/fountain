### Upgrade notes

- **Migration `20261016010000` drops `conversations.session_config`**
  (#2740, ADR 0062). The release before it stopped reading the column and
  folded its values into `agent_session_config`; take this release only
  after that one is fully rolled out.
