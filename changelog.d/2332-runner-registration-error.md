### Fixed

- A runner whose registration fails validation is now told why (#2332).
  `GET /api/runners/ws` rendered a rejected changeset through a view, but the
  route carries no `:accepts_json` — deliberately, since a WebSocket client
  sends no JSON `Accept` — so `render/3` raised and the daemon saw
  `connect: HTTP 500` and reconnected forever with nothing to act on. It now
  answers the usual `validation_failed` body. Reachable by passing
  `fountain runner --name` a name that is not `[a-z0-9][a-z0-9._-]{0,62}`;
  the default name is derived from the hostname and is always valid.
