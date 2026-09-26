### Changed

- **Codex on a ChatGPT subscription can read its model list** (#2503). The
  credential broker now allows
  `GET https://chatgpt.com/backend-api/codex/models` for a subscription, with
  only the `client_version` query parameter. Before this change Codex asked
  for the list after every reply, and the broker refused it each time: about
  560 refusals an hour from one busy sandbox. The models a Codex conversation
  on a subscription offers are now the ones the backend lists for that
  subscription, not the list that ships with Codex. Every other `chatgpt.com`
  route except the Responses call stays refused.
- **A refused request no longer closes its connection through the broker**
  (#2503). `managoat_broker` 0.16.0 answers a refused request that has no body
  and keeps the connection open for the next request. A refused request with a
  body still closes it. A sandbox now opens far fewer connections when it
  keeps asking for routes the broker refuses.
