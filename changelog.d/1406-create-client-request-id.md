### Added

- **`POST /api/conversations` takes `client_request_id` for its first prompt**
  (#1406). The value goes to turn 1 of a new conversation, to the first turn of
  a conversation attached with `sandbox_id`, and waits with a queued start
  until it runs. Fountain ignores it when the request carries no `prompt`, and
  when `channel_id` resumes a conversation: a resume does not deliver the
  prompt, so send the value with the prompt on the prompts route. Read
  [Find the turn your prompt opened](https://managoat.com/docs/api#find-the-turn-your-prompt-opened).
