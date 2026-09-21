defmodule Fountain.ChatGPTAccounts.Grant do
  @moduledoc """
  A server-only credential paired with its non-secret source identity.

  Keep this value separate from generic environment/template inputs. Inspect
  omits the bearer, and no JSON encoder is derived. `source` is a snapshot of
  one row version: the grant's `name` is a label a user may change and is
  deliberately not part of it.

  It is what `Fountain.ChatGPTAccounts.protected_credential/2` answers the
  broker with for one request, and it goes no further than
  `Fountain.Broker.Native.Sessions.authorize/2`, which hands the bearer and
  the account id to the proxy as a `Managoat.Broker.ProtectedCredential`. It
  never enters a conversation process, the `brokered` map, a rule or a row.
  """

  alias Fountain.PlatformChatGPT.Account

  @enforce_keys [:source, :access_token]
  @derive {Inspect, only: [:source]}
  defstruct [:source, :access_token]

  @type t :: %__MODULE__{source: map(), access_token: String.t()}

  @doc false
  def new(%Account{} = account, access_token) when is_binary(access_token) do
    %__MODULE__{
      access_token: access_token,
      source: %{
        kind: :chatgpt,
        owner_scope: owner_scope(account),
        grant_id: account.id,
        generation: account.generation,
        lock_version: account.lock_version,
        account_id: account.account_id,
        plan_type: account.plan_type,
        id_claims: Map.take(account.id_claims, ["account_id", "user_id", "plan_type"])
      }
    }
  end

  defp owner_scope(%Account{user_id: nil}), do: :platform
  defp owner_scope(%Account{user_id: id}) when is_binary(id), do: {:user, id}
end
