### Changed

- **A prompt to a conversation whose sandbox is still being set up answers
  `queued`** (#2577). It used to wait on the server for 30 s and answer `503`,
  and the prompt still ran once setup finished, so a client that retried got a
  duplicate turn. It is now queued behind the setup after the same checks a
  parked conversation's prompt gets. A queued prompt that then cannot run
  (another turn is running, or it is refused when its turn would open) is
  reported as `conversation.wake.failed` with its reason, where it was dropped
  silently before.
