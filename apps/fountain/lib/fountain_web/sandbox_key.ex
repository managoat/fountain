defmodule FountainWeb.SandboxKey do
  @moduledoc """
  Which sandbox credential a request was made with, for the contexts whose
  rules depend on it.

  A conversation hands its sandbox a `sprite`-scoped API key. That key
  authenticates as the *account*, so every tenant-scoped check would pass for
  every conversation the account owns. `FountainWeb.Plugs.SandboxKeyScope`
  confines it to its own conversation tree (ADR 0096). A context that must
  tell "this sandbox's own conversation" from
  "another conversation of the same tenant" needs the key's id, and
  `FountainWeb.Audited.attribution/2` deliberately carries only the actor.

  One derivation, in one place, so a new door cannot get it subtly wrong:
  `opts/1` returns the keyword pair to append beside `attribution/1`, and is
  `[]` for anything that is not a sandbox token (a session, the owner's own
  full-scope key, a background caller), which every rule reads as "no sandbox
  restriction applies".
  """

  alias Fountain.Accounts.ApiKey

  @doc """
  The api key id when the request carried a sandbox's per-conversation token,
  and `nil` for anything else.
  """
  @spec id(Plug.Conn.t()) :: binary() | nil
  def id(%Plug.Conn{} = conn) do
    case conn.assigns[:current_api_key] do
      %ApiKey{id: id, scopes: scopes} -> if "sprite" in scopes, do: id
      _ -> nil
    end
  end

  @doc """
  `[sandbox_key_id: id]` for a sandbox token, `[]` otherwise. Append it to
  `FountainWeb.Audited.attribution/1` on any door that writes a conversation
  a sandbox might not own.
  """
  @spec opts(Plug.Conn.t()) :: keyword()
  def opts(%Plug.Conn{} = conn) do
    case id(conn) do
      nil -> []
      key_id -> [sandbox_key_id: key_id]
    end
  end
end
