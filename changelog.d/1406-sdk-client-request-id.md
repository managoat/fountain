### Added

- **Every SDK sends `client_request_id`** (#1406). TypeScript
  `run(prompt, { clientRequestId })` and `resume(id).send(prompt, { clientRequestId })`,
  Python and Elixir `client_request_id`, Swift `clientRequestID:` on `run`,
  `send` and `FountainKit.conversations.prompt`. A client that resumes a
  conversation with `channel_id` now repeats the value on the prompts route:
  that second request is the one that opens the turn, so a value given only to
  the create was being dropped. Read
  [Find the turn your prompt opened](https://managoat.com/docs/api#find-the-turn-your-prompt-opened).
