defmodule Fountain.Conversations.CallbackKeyTest do
  use Fountain.DataCase, async: true

  alias Fountain.Accounts
  alias Fountain.Conversations
  alias Fountain.Conversations.CallbackKey

  describe "ttl_seconds/0" do
    test "defaults to thirty days" do
      # The TTL config override is covered by api_key_scope_test in a sync
      # module; this async one must not write application env.
      assert CallbackKey.ttl_seconds() == 30 * 24 * 60 * 60
    end
  end

  describe "env/1" do
    test "is the base URL and the token" do
      assert [{"MANAGOAT_BASE_URL", base}, {"MANAGOAT_TOKEN", "tok"}] = CallbackKey.env("tok")
      assert base == Fountain.PublicUrl.base()
    end

    test "is empty without a token" do
      assert CallbackKey.env(nil) == []
      assert CallbackKey.env("") == []
    end
  end

  describe "api_key_opts/0" do
    test "scopes the key to the sprite, expires it after the TTL, names the actor" do
      opts = CallbackKey.api_key_opts()

      assert Keyword.fetch!(opts, :scopes) == ["sprite"]
      assert Keyword.fetch!(opts, :actor) == "system:conversation_server"

      expires_at = Keyword.fetch!(opts, :expires_at)
      expected = DateTime.add(DateTime.utc_now(), CallbackKey.ttl_seconds(), :second)
      assert_in_delta DateTime.diff(expires_at, expected, :second), 0, 2
      assert expires_at.microsecond == {0, 0}
    end
  end

  describe "rotate/2" do
    test "none never mints a key on first provision or repeated wake" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id, sandbox_api_access: "none")

      for _ <- 1..3 do
        assert {:ok, nil, nil, current} = CallbackKey.rotate(conv, nil)
        assert current.sandbox_api_access == "none"
        assert current.callback_api_key_id == nil
        assert Accounts.list_api_keys(user.id) == []
        assert CallbackKey.env(nil) == []
      end
    end

    test "none revokes stale pointers without revoking another conversation" do
      user = insert_verified_user()
      {:ok, {stale, stale_raw}} = Accounts.create_api_key(user.id, "stale")
      {:ok, {local, _}} = Accounts.create_api_key(user.id, "local")
      {:ok, {other, other_raw}} = Accounts.create_api_key(user.id, "other")

      conv =
        insert_conversation(
          user_id: user.id,
          sandbox_api_access: "none",
          callback_api_key_id: stale.id
        )

      assert {:ok, nil, nil, conv} = CallbackKey.rotate(conv, local.id)
      assert conv.callback_api_key_id == nil
      assert Repo.get!(Accounts.ApiKey, stale.id).revoked_at
      assert Repo.get!(Accounts.ApiKey, local.id).revoked_at
      refute Repo.get!(Accounts.ApiKey, other.id).revoked_at
      refute match?({:ok, _, _}, Accounts.authenticate_api_key(stale_raw))
      assert {:ok, _, _} = Accounts.authenticate_api_key(other_raw)
    end

    test "the launch setting cannot be changed after persistence" do
      user = insert_verified_user()

      for {before, after_value} <- [{"none", "owner"}, {"owner", "none"}] do
        conv = insert_conversation(user_id: user.id, sandbox_api_access: before)

        assert {:error, cs} =
                 Conversations.update_conversation(conv, %{sandbox_api_access: after_value})

        assert {"cannot change after launch", _} = cs.errors[:sandbox_api_access]
      end
    end

    test "mints a sprite-scoped key named for the conversation and points the row at it" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      assert {:ok, "ftn_" <> _ = raw, key_id, conv} = CallbackKey.rotate(conv, nil)
      assert conv.callback_api_key_id == key_id
      assert Conversations.get_conversation(conv.id, user.id).callback_api_key_id == key_id

      assert [%Accounts.ApiKey{id: ^key_id, name: name, scopes: ["sprite"], revoked_at: nil}] =
               Accounts.list_api_keys(user.id)

      assert name == "sprite:" <> String.slice(conv.id, 0, 8)

      assert {:ok, %{id: user_id}, %Accounts.ApiKey{id: ^key_id}} =
               Accounts.authenticate_api_key(raw)

      assert user_id == user.id
    end

    test "revokes the key this server minted before, and only that one" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      {:ok, {other, _raw}} = Accounts.create_api_key(user.id, "not-ours")

      {:ok, _raw1, first_id, conv} = CallbackKey.rotate(conv, nil)
      {:ok, _raw2, second_id, conv} = CallbackKey.rotate(conv, first_id)

      assert second_id != first_id
      assert conv.callback_api_key_id == second_id

      # `list_api_keys/1` hides revoked rows, so read them directly.
      assert Repo.get!(Accounts.ApiKey, first_id).revoked_at
      refute Repo.get!(Accounts.ApiKey, second_id).revoked_at
      refute Repo.get!(Accounts.ApiKey, other.id).revoked_at
    end
  end
end
