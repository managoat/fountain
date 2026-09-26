### Changed

- **Sandboxes record their applied skills per runtime** (#2514). A migration
  adds `sandboxes.applied_skills_by_runtime` and copies each recorded selection
  under the runtime that built the disk, so two runtimes on one machine will
  not treat each other's skills as their own. The old `applied_skills` column
  is no longer read or written and will be dropped in a later release; the
  migration is safe to run while the previous release is still serving. The
  legacy skill-manifest console steps in
  [Run a release task](https://managoat.com/docs/guides/operate/run-a-release-task)
  now read the record with `Sandbox.applied_skills(sandbox, conv.runtime)`.
