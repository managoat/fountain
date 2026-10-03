### Added

- **Wake a conversation without a prompt** (#2551). `POST
  /api/conversations/{id}/wake`, `fountain conv wake <id>` and
  `Conversation.wake()` in the TypeScript SDK bring a conversation's sandbox
  up ahead of its next prompt, so that prompt does not wait for the wake.
