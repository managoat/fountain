### Changed

- **A brokered secret written during a turn reaches that turn** (#2548).
  Writing or deleting an environment or vault secret now updates the broker
  rules of every running conversation that uses it, without ending the turn or
  replacing the sandbox's session token. The sandbox's next connection through
  the broker, such as the next `git push`, uses the new value. A client can
  replace a one-hour GitHub App token mid-turn. Unbrokered secrets still reach
  only a new conversation. See
  [Secrets](https://managoat.com/docs/concepts/secrets#hop-3-environment-and-vault-merge).
