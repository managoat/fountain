### Fixed

- The CLI can send `client_request_id` with `fountain run --client-request-id`
  and `fountain conv prompt --client-request-id`. The ACP bridge accepts
  `_meta.clientRequestId` on each `session/prompt`, so editors can correlate
  their submissions with the resulting turns (#2389).
