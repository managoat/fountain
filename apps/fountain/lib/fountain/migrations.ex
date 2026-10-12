defmodule Fountain.Migrations do
  @moduledoc """
  The one ordered migration path set every entrance uses (ADR 0043, #1506).

  Core first, then each installed extension's directories in configured order.
  Four entrances read it and there is no fifth:

    * the boot migrator (`Ecto.Migrator` in `Fountain.Application`);
    * `Fountain.Release.migrate/0` and `rollback/2`, which `bin/migrate` runs;
    * `mix ecto.migrate` and `mix ecto.rollback`, aliased in
      `apps/fountain/mix.exs` to pass this set as `--migrations-path`;
    * `mix ecto.setup` / `ecto.reset` and the test database, through those
      aliases.

  With nothing installed the set is `[core]` and every entrance behaves exactly
  as it did before extensions existed — an absent extension cannot make a
  migration or a rollback fail.

  ## One `schema_migrations` for everyone

  Extension migrations are recorded in Fountain's own `schema_migrations` table,
  not a table of their own. Two consequences worth knowing before writing one:

    * **Version numbers are global.** A version an extension picks must not
      collide with the core's or another extension's. Ecto refuses to run a path
      set containing a duplicate version, so a collision is a loud failed
      migrate rather than a quietly skipped migration. Timestamps make this a
      non-event in practice; hand-picked integers do not.
    * **Moving a migration between paths is not a re-run.** A version already in
      `schema_migrations` stays applied when its file moves from the core
      directory to an extension's, because Ecto matches on the version number
      and never on the path. That is what let #1507 move an extension's table
      without touching a live database.

  ## Two ways to name the core path, and why

  This module resolves the core path through `:code.priv_dir/1`
  (`Ecto.Migrator.migrations_path/1`), which is what a release has. The mix
  aliases in `apps/fountain/mix.exs` resolve it through
  `Mix.EctoSQL.source_repo_priv/1` instead — the *source* directory, and what
  Ecto's own tasks would have used. Handing a mix task the `_build` path would
  give Ecto two directories holding the same files through a symlink, and it
  raises on the duplicate versions that produces. That half lives in `mix.exs`,
  which is not compiled into the release, so nothing shipped refers to `Mix`.
  Extension paths have no such pair and use `:code.priv_dir/1` everywhere.
  """

  alias Fountain.Extensions

  @doc """
  The runtime path set for `repo`: the core migrations directory as a release
  sees it, then every installed extension's.
  """
  @spec paths(module()) :: [String.t()]
  def paths(repo) do
    [Ecto.Migrator.migrations_path(repo) | Extensions.migration_paths()]
  end

  @doc """
  The `:migrator` the boot-time `Ecto.Migrator` child runs.

  Ecto's default is `&Ecto.Migrator.run/3`, which resolves the single core path
  itself. This is the same call with `paths/1` in front of it.
  """
  @spec run(module(), :up | :down, keyword()) :: [integer()]
  def run(repo, direction, opts) do
    Ecto.Migrator.run(repo, paths(repo), direction, opts)
  end

  @doc """
  Every installed extension's migration directories, without the core's.

  What the mix aliases append to the source core path they compute themselves.
  """
  @spec extension_paths() :: [String.t()]
  def extension_paths, do: Extensions.migration_paths()
end
