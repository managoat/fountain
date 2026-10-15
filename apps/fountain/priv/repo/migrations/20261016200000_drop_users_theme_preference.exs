defmodule Fountain.Repo.Migrations.DropUsersThemePreference do
  use Ecto.Migration

  @moduledoc """
  Drops `users.theme_preference` (`20260510200000`). The console's theme lives
  in the browser's localStorage only; the release before this one removed
  `PATCH /api/settings/theme`, the root layout's read of the column, and its
  mapping in `Fountain.Accounts.User`.

  Ecto selects every mapped field, so a replica of any release that still
  mapped the column fails every user load once this runs. Take this only
  after the release that unmapped it is fully rolled out.

  `down` restores the shape, not the values: every user comes back as
  `"system"`.
  """

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    alter table(:users) do
      remove :theme_preference
    end
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    alter table(:users) do
      add :theme_preference, :string, default: "system", null: false
    end
  end
end
