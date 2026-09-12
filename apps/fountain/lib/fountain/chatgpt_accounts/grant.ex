defmodule Fountain.ChatGPTAccounts.Grant do
  @moduledoc """
  A server-only credential paired with its non-secret source identity.

  Keep this value separate from generic environment/template inputs. Inspect
  omits the bearer, and no JSON encoder is derived. Transport integration and
  protected broker compilation are follow-up work under ADR 0052.
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
