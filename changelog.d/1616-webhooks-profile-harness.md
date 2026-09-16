### Fixed

- **The deployed suite's `webhooks` profile can pass** (#1616). It had never
  passed against a real deployment. Its receiver refused every real delivery,
  because Fountain's webhook envelope gained `labels` in #1637 and the receiver
  checks the envelope's exact keys. That check is kept exact on purpose — the
  envelope promises "ids, a stage, a status, a duration, the labels. Nothing
  else, ever", and a receiver that tolerated added fields would miss content
  arriving in a webhook — so `labels` is now expected and bounded as Fountain
  bounds it. The profile also compared the payload against a conversation
  stream frame, which leaves `duration_ms` out by contract; it now compares
  against the durable event.
