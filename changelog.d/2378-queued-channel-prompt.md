### Fixed

- A queued conversation start now delivers its prompt if another request bound
  its `channel_id` while it waited, preserving `client_request_id` and queue
  attribution. A busy conversation leaves the request queued for a later pass;
  non-retryable delivery failures are recorded instead of reporting a successful start
  (#2378).
