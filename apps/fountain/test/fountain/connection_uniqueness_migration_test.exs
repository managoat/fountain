defmodule Fountain.ConnectionUniquenessMigrationTest do
  use Fountain.DataCase, async: true

  alias Fountain.Repo.Migrations.ScopeConnectionUniquenessToProviderIdentity, as: Migration

  @version 20_260_914_083_132

  unless Code.ensure_loaded?(Migration) do
    Code.require_file(
      "../../priv/repo/migrations/20260914083132_scope_connection_uniqueness_to_provider_identity.exs",
      __DIR__
    )
  end

  setup do
    # The actual migration runs on a connection-local schema. Neither its DDL
    # nor its history changes the shared test database's connection indexes.
    schema = "connection_identity_#{System.unique_integer([:positive])}"
    Repo.query!(~s(CREATE SCHEMA "#{schema}"))
    Repo.query!(~s(SET LOCAL search_path TO "#{schema}", public))

    Repo.query!("""
    CREATE TABLE connections (
      user_id uuid NOT NULL,
      provider varchar NOT NULL,
      provider_id uuid,
      account_email varchar NOT NULL,
      access_token_ciphertext bytea NOT NULL
    )
    """)

    Repo.query!("""
    CREATE UNIQUE INDEX connections_user_id_provider_account_email_index
    ON connections (user_id, provider, account_email)
    """)

    user_id = Ecto.UUID.dump!(Ecto.UUID.generate())
    provider_id = Ecto.UUID.dump!(Ecto.UUID.generate())
    insert_grant(user_id, provider_id, "tenant-ciphertext")
    %{user_id: user_id}
  end

  test "upgrade and rollback preserve legacy grants, and upgrade admits distinct identities",
       ctx do
    run_migration(:up)
    assert %{rows: [["tenant-ciphertext"]]} = tokens()
    run_migration(:down)
    assert %{rows: [["tenant-ciphertext"]]} = tokens()
    run_migration(:up)

    insert_grant(ctx.user_id, nil, "platform-ciphertext")
    assert %{rows: [["platform-ciphertext"], ["tenant-ciphertext"]]} = tokens()

    # An older schema cannot represent these two identities. Refuse rollback
    # without deleting either grant or dropping the replacement constraints.
    assert_raise Postgrex.Error, ~r/connections_user_id_provider_account_email_index/, fn ->
      run_migration(:down)
    end

    assert %{rows: [["platform-ciphertext"], ["tenant-ciphertext"]]} = tokens()
  end

  defp insert_grant(user_id, provider_id, ciphertext) do
    Repo.query!(
      "INSERT INTO connections VALUES ($1, 'google', $2, 'me@example.com', $3)",
      [user_id, provider_id, ciphertext]
    )
  end

  defp tokens,
    do:
      Repo.query!(
        "SELECT access_token_ciphertext FROM connections ORDER BY access_token_ciphertext"
      )

  defp run_migration(direction) do
    Ecto.Migration.Runner.run(
      Repo,
      Repo.config(),
      @version,
      Migration,
      if(direction == :up, do: :forward, else: :backward),
      :change,
      direction,
      log: false
    )
  end
end
