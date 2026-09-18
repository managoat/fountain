### Fixed

- A queued conversation start now delivers its prompt if another request bound
  its `channel_id` while it waited, preserving `client_request_id` and queue
  attribution. A queued prompt with a nonempty permission override fails before
  resumed delivery; a fresh launch preserves that override. Busy conversations
  and temporary wake failures leave the request queued for a later pass. A prompt
  call timeout or node disconnect records
  `prompt_delivery_unknown` and the target conversation, without automatically
  resending a prompt that may still execute. Other terminal delivery failures
  are recorded instead of reporting a successful start (#2378).
