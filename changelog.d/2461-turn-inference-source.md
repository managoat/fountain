### Added

- **A turn says which inference source served it** (#2461).
  `GET /api/conversations/:id/turns` gives each turn a read-only `inference`
  object: `origin` (`own` or `platform`) and `scope`. It is written when the
  turn starts and never rewritten, so repointing a credential set or a
  restart changes later turns only; it is null on turns from before it was
  recorded. The TypeScript SDK's generated `Turn` type gains the field. See
  https://managoat.com/docs/api#conversations.
