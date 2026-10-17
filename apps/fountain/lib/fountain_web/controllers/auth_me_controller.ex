defmodule FountainWeb.AuthMeController do
  @moduledoc """
  GET /api/auth/me

  Returns the authenticated user's identity. Used by `managoat auth whoami`
  in the CLI to confirm which account an API key belongs to.
  """

  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Fountain.Accounts.ApiKey
  alias FountainWeb.Schemas

  tags(["Auth"])

  operation(:show,
    summary: "Identity of the authenticated account",
    description:
      "What the presented bearer token resolves to. `managoat auth whoami` " <>
        "calls this to show which account a key belongs to. For a " <>
        ~s(conversation's sandbox key, and for the conversation key an ) <>
        ~s(`"auth": "conversation"` MCP server receives, `conversation_id` ) <>
        "names the conversation.",
    responses: [
      ok: {"The account", "application/json", Schemas.AuthMeResponse},
      unauthorized: {"Missing or invalid key", "application/json", Schemas.Error}
    ]
  )

  def show(conn, _params) do
    user = conn.assigns.current_user

    json(conn, %{
      conversation_id: callback_conversation_id(conn, user),
      id: user.id,
      email: user.email,
      expires_at: conn.assigns.current_api_key.expires_at,
      role: user.role,
      email_verified: not is_nil(user.email_verified_at),
      # Always true: every deployment brokers egress (ADR 0019, amendment
      # of 2026-10-15). Kept so clients that read it (#1154) keep working.
      brokered: true
    })
  end

  # The conversation a key belongs to (ADR 0086), so an MCP server given a key
  # by `"auth": "conversation"` binds it to one conversation instead of
  # trusting a header. A `"conversation"` key names its conversation itself
  # (#2934), and dies with the callback key it was minted from. For a
  # sandbox's own callback key the conversation row names the key it minted;
  # a rotated-away key, or any other key, has none.
  defp callback_conversation_id(
         %{assigns: %{current_api_key: %ApiKey{conversation_id: id} = key}},
         _user
       )
       when is_binary(id) do
    if ApiKey.conversation_bound?(key), do: id
  end

  defp callback_conversation_id(conn, user) do
    case FountainWeb.SandboxKey.id(conn) do
      nil ->
        nil

      key_id ->
        case Fountain.Conversations.get_conversation_for_callback_key(key_id, user.id) do
          nil -> nil
          conv -> conv.id
        end
    end
  end
end
