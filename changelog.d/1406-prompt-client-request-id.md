### Added

- **A prompt can carry your own `client_request_id`** (#1406).
  `POST /api/conversations/{id}/prompts` takes an optional string of 1 to 200
  characters and repeats it in the response. Fountain stores it on the turn the
  prompt opens, shows it on the turn in `GET /api/conversations/{id}/turns`, and
  sends it on that turn's `started` stage event beside `turn_id`. A client that
  shares a conversation can now bind its work item to the exact turn instead of
  inferring it from turn order. The value is a correlation and not an
  idempotency key: a second prompt with the same value opens a second turn. The
  response still cannot name the turn, because a conversation that has to wake
  is answered before its turn exists. Read
  [Find the turn your prompt opened](https://managoat.com/docs/api#find-the-turn-your-prompt-opened).
