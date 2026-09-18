### Fixed

- Runner one-shot commands now kill their process group on timeout or parent exit, and stop waiting after 250 ms if an escaped descendant retains the output pipe (#2394). Background work must use a streaming session. Process-group escape and recovery after daemon loss still require further work before file reads can safely coordinate with park/delete.
