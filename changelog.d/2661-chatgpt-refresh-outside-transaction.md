### Fixed

- A ChatGPT subscription is no longer revoked when the database fails right
  after a token refresh (#2661). The call to auth.openai.com now runs outside
  any transaction under a short lease on the row. A failed write of the
  rotated refresh token is retried instead of being rolled back, so a
  database blip no longer means linking the subscription again.
