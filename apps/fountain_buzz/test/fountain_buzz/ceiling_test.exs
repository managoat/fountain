defmodule FountainBuzz.CeilingTest do
  @moduledoc """
  `BUZZ_IDENTITY_CEILING` on `provision_identity/3` (#1017).

  `async: false`: the ceiling is application env, and an async test that writes
  it leaks into every other module running beside it (#1214).
  """

  use Fountain.DataCase, async: false

  alias FountainBuzz, as: Buzz

  setup do
    prev = Application.get_env(:fountain_buzz, :buzz_identity_ceiling)
    on_exit(fn -> restore(:buzz_identity_ceiling, prev) end)

    user = insert_verified_user()
    agent = insert_agent(%{"user_id" => user.id})

    params = fn pubkey ->
      %{
        "name" => "philo-#{String.slice(pubkey, 0, 6)}",
        "relay_url" => "wss://relay.example",
        "agent_id" => agent.id,
        "pubkey" => pubkey,
        "private_key_nsec" => "nsec1secret",
        "auth_tag" => "[\"auth\",\"owner\"]"
      }
    end

    %{user: user, params: params}
  end

  defp restore(key, nil), do: Application.delete_env(:fountain_buzz, key)
  defp restore(key, val), do: Application.put_env(:fountain_buzz, key, val)

  defp pubkey(n), do: String.duplicate(Integer.to_string(n, 16), 64) |> String.slice(0, 64)

  describe "the ceiling" do
    test "refuses a new identity once the tenant is at the limit", %{user: user, params: params} do
      Application.put_env(:fountain_buzz, :buzz_identity_ceiling, 2)

      assert {:ok, _} = Buzz.provision_identity(user.id, params.(pubkey(1)))
      assert {:ok, _} = Buzz.provision_identity(user.id, params.(pubkey(2)))

      assert {:error, {:identity_limit_reached, %{count: 2, limit: 2}}} =
               Buzz.provision_identity(user.id, params.(pubkey(3)))

      # Refused before anything was written: no orphan vault, no third row.
      assert length(Buzz.list_identities(user.id)) == 2
    end

    test "a converging deploy of an identity that already exists is exempt", %{
      user: user,
      params: params
    } do
      Application.put_env(:fountain_buzz, :buzz_identity_ceiling, 1)

      assert {:ok, first} = Buzz.provision_identity(user.id, params.(pubkey(1)))

      # At the ceiling now. The provider's repeated `deploy` must still land —
      # it adds no standing process, and refusing it would strand a running
      # harness on stale credentials.
      assert {:ok, again} =
               Buzz.provision_identity(
                 user.id,
                 params.(pubkey(1)) |> Map.put("private_key_nsec", "nsec1rotated")
               )

      assert again.id == first.id

      {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)
      vault = Fountain.Vaults.get_vault(again.vault_id, user.id)
      assert Fountain.Vaults.decrypted_env(vault, dek)["BUZZ_PRIVATE_KEY"] == "nsec1rotated"
    end

    test "a disabled identity still occupies a slot", %{user: user, params: params} do
      Application.put_env(:fountain_buzz, :buzz_identity_ceiling, 1)

      assert {:ok, identity} = Buzz.provision_identity(user.id, params.(pubkey(1)))
      {:ok, _} = Buzz.update_identity(identity, %{"enabled" => false})

      # A disabled row is a slot the tenant can re-enable without asking
      # anyone, so a ceiling that ignored it would bound nothing.
      assert {:error, {:identity_limit_reached, %{count: 1, limit: 1}}} =
               Buzz.provision_identity(user.id, params.(pubkey(2)))
    end

    test "the ceiling is per tenant, not global", %{user: user, params: params} do
      Application.put_env(:fountain_buzz, :buzz_identity_ceiling, 1)

      assert {:ok, _} = Buzz.provision_identity(user.id, params.(pubkey(1)))

      other = insert_verified_user()
      other_agent = insert_agent(%{"user_id" => other.id})
      other_params = params.(pubkey(2)) |> Map.put("agent_id", other_agent.id)

      assert {:ok, _} = Buzz.provision_identity(other.id, other_params)
    end
  end
end
