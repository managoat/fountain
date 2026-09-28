### Added

- **Newest-first conversation event pages** (#2531).
  `GET /api/conversations/{id}/events` takes `order=desc` with a `before`
  cursor, and `whole_turns=true` so a page never ends inside a turn. A client
  opens a long conversation at its newest complete turns in one request and
  pages back without re-reading them. Every page also carries a `page`
  object with `order`, `oldest_cursor`, `newest_cursor` and `turn_split`;
  `meta` and forward paging are unchanged. See the
  [API reference](https://managoat.com/docs/api#open-a-thread-at-its-newest-turns).
