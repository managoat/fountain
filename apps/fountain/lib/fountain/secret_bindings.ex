defmodule Fountain.SecretBindings do
  @moduledoc """
  Secret bindings: which hosts a tenant's secret is attached to at the egress
  broker, and how (ADR 0019 gate 1b, #1090).

  A secret with at least one enabled binding is **brokered**: the sandbox
  gets a placeholder, the broker gets the value and one service per binding.
  A secret with none reaches the sandbox in the clear, exactly as before the
  broker existed. That is the whole `exposure` label gate 1b asked for,
  without a second field: the presence of a binding is the declaration.

  Everything here is tenant-scoped by `user_id`. Bindings are only consulted
  on a deployment that brokers egress (`Fountain.Broker.configured?/0`); on
  one without a broker they are rows nobody reads.
  """

  import Ecto.Query, warn: false

  alias Fountain.Audit
  alias Fountain.Repo
  alias Fountain.SecretBindings.Binding

  @doc "Every binding of a tenant, by key then host."
  @spec list_bindings(String.t()) :: [Binding.t()]
  def list_bindings(user_id) when is_binary(user_id) do
    Repo.all(from b in Binding, where: b.user_id == ^user_id, order_by: [asc: b.key, asc: b.host])
  end

  @doc "The enabled bindings of a tenant, grouped by key. What provisioning reads."
  @spec enabled_by_key(String.t()) :: %{String.t() => [Binding.t()]}
  def enabled_by_key(user_id) when is_binary(user_id) do
    user_id |> list_bindings() |> Enum.filter(& &1.enabled) |> Enum.group_by(& &1.key)
  end

  @spec get_binding(String.t(), String.t()) :: Binding.t() | nil
  def get_binding(id, user_id) when is_binary(id) and is_binary(user_id) do
    Repo.get_by(Binding, id: id, user_id: user_id)
  end

  @doc """
  Create a binding for a tenant. `attrs` is string-keyed; the tenant comes
  from the first argument, never from the attrs.
  """
  @spec create_binding(String.t(), map(), keyword()) ::
          {:ok, Binding.t()} | {:error, Ecto.Changeset.t()}
  def create_binding(user_id, attrs, opts \\ []) when is_binary(user_id) and is_map(attrs) do
    %Binding{}
    |> Binding.changeset(Map.put(attrs, "user_id", user_id))
    |> Repo.insert()
    |> audited("secret_binding.created", opts)
  end

  @spec update_binding(Binding.t(), map(), keyword()) ::
          {:ok, Binding.t()} | {:error, Ecto.Changeset.t()}
  def update_binding(%Binding{} = binding, attrs, opts \\ []) when is_map(attrs) do
    changeset = Binding.changeset(binding, Map.delete(attrs, "user_id"))

    changeset
    |> Repo.update()
    |> audited(
      "secret_binding.updated",
      Keyword.put(opts, :metadata, %{"fields" => Audit.changed_fields(changeset)})
    )
  end

  @spec delete_binding(Binding.t(), keyword()) ::
          {:ok, Binding.t()} | {:error, Ecto.Changeset.t()}
  def delete_binding(%Binding{} = binding, opts \\ []) do
    binding |> Repo.delete() |> audited("secret_binding.deleted", opts)
  end

  @doc """
  The secret keys a tenant has anywhere — every environment and every vault —
  so the console can offer them for binding without ever reading a value.
  """
  @spec known_keys(String.t()) :: [String.t()]
  def known_keys(user_id) when is_binary(user_id) do
    env_keys =
      from(s in Fountain.Environments.Secret,
        join: e in assoc(s, :environment),
        where: e.user_id == ^user_id,
        select: s.key
      )

    vault_keys =
      from(s in Fountain.Vaults.VaultSecret,
        join: v in assoc(s, :vault),
        where: v.user_id == ^user_id,
        select: s.key
      )

    # A connection's token is a secret the account holds too (#1178): it is
    # brokered under its env_key, so it can be bound to a host like any other.
    (Repo.all(env_keys) ++ Repo.all(vault_keys) ++ Fountain.Connections.env_keys(user_id))
    |> Enum.uniq()
    |> Enum.sort()
  end

  # ── audit ────────────────────────────────────────────────────────────────

  # Never the value — there is none here — but the host and the shape are
  # what an incident wants to know.
  defp audited({:ok, %Binding{} = binding} = ok, action, opts) do
    metadata =
      %{"key" => binding.key, "host" => binding.host, "auth_type" => binding.auth_type}
      |> Map.merge(Keyword.get(opts, :metadata, %{}))

    Audit.record_resource(
      action,
      "secret_binding",
      binding,
      Keyword.put(opts, :metadata, metadata)
    )

    ok
  end

  defp audited(other, _action, _opts), do: other
end
