defmodule FountainWeb.Plugs.RequireFullScope do
  @moduledoc """
  Restricts account-level writes to `full`-scoped API keys.

  Every conversation hands its sprite a tenant API key so the agent can stream,
  prompt, and spawn sub-agents. Those tokens are `sprite`-scoped and are
  deliberately weaker than the owner's own key: code running in a sandbox is
  untrusted by design, so it must not be able to change the account out from
  under the person who owns it — replace the tenant's inference credentials,
  rotate the password, delete the account.

  `FountainWeb.Plugs.RequireKeyManagement` is the original, API-key-specific
  instance of this rule and now delegates here so there is one implementation
  of "is this credential allowed to act on the account itself".

  Pass `:error` to describe the refused capability; the response always carries
  `reason: "insufficient_scope"` and `required_scope: "full"` so callers can
  branch on shape rather than prose.

  Session-authenticated browser routes never reach this plug; it guards the
  bearer-token API pipeline only.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Fountain.Accounts.ApiKey

  @default_error "This API key is not permitted to perform account-level writes"

  def init(opts), do: opts

  def call(%{assigns: %{current_api_key: %ApiKey{}}} = conn, opts) do
    if full_scope?(conn) do
      conn
    else
      refuse(conn, Keyword.get(opts, :error, @default_error))
    end
  end

  # No key on the connection means this ran outside the bearer-token pipeline.
  # Fail closed rather than assume the caller is privileged.
  def call(conn, _opts) do
    refuse(conn, "API key scope could not be determined")
  end

  @doc """
  Whether the request carries a full-scope key: this plug's rule, for a door
  that admits every scope but decides one thing by it (a guest attach on
  `POST /api/conversations`, #2525). `false` with no key, as the plug fails
  closed.
  """
  @spec full_scope?(Plug.Conn.t()) :: boolean()
  def full_scope?(%Plug.Conn{assigns: %{current_api_key: %ApiKey{} = key}}),
    do: ApiKey.may_manage_keys?(key)

  def full_scope?(%Plug.Conn{}), do: false

  defp refuse(conn, message) do
    conn
    |> put_status(:forbidden)
    |> json(%{
      error: message,
      reason: "insufficient_scope",
      required_scope: "full"
    })
    |> halt()
  end
end
