### Upgrade notes

- **The `team_schedules` table is dropped** (#2703, ADR 0074), with any
  Oban jobs the removed team scheduler left behind. Upgrade through the
  release that removed the team first, since that release stopped reading
  the table. After this migration, schedules can only be recovered from a
  backup.
