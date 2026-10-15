defmodule FountainWeb.TurnImageController do
  @moduledoc """
  Images attached to a turn, for the browser session
  (`GET /conversations/:conversation_id/turns/:turn_id/images/:position`) and
  for bearer tokens (`/api/conversations/...`, #578).

  Both routes used to be one `:show` action, which caused two problems. The
  bearer route sat inside the `:accepts_json` pipeline, so
  `plug :accepts, ["json"]` refused `Accept: image/png` with 406 *before* the
  action ran — an endpoint returning PNG bytes worked only if the caller did
  not ask for an image. And a single action behind two routes cannot be given
  an OpenAPI operation without also emitting the session-authenticated browser
  route into the spec as a bearer endpoint, so turn images were in no spec at
  all while `Turn.image_count` advertised them.

  Split the way #528 split `AgentAvatarController` (whose browser half has
  since gone): `:show` for the browser, `:api_show` for bearer tokens, one
  private serve path so the guards cannot drift between them.
  """
  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Fountain.Conversations
  alias Fountain.Conversations.TurnImage
  alias FountainWeb.Schemas

  tags(["Conversations"])

  # Browser route: session-authenticated so <img> tags load without a token.
  operation(:show, false)

  def show(conn, %{"conversation_id" => conv_id, "turn_id" => turn_id, "position" => pos}) do
    serve_image(conn, conv_id, turn_id, pos)
  end

  operation(:api_show,
    summary: "Fetch an image attached to a turn",
    description:
      "The image bytes, with the stored media type. `position` is the " <>
        "zero-based index into the turn's images; `image_count` on the turn " <>
        "(from `GET /api/conversations/{id}/turns`) says how many there are. " <>
        "404 covers every miss — unknown conversation, a turn belonging to a " <>
        "different conversation, an absent position, and a stored media type " <>
        "that is not an image — so this is not a probe for ids.",
    parameters: [
      conversation_id: [in: :path, type: :string, required: true],
      turn_id: [in: :path, type: :string, required: true],
      position: [
        in: :path,
        type: :integer,
        required: true,
        description: "Zero-based index into the turn's images."
      ]
    ],
    responses: [
      ok: {"Image bytes", "image/*", %OpenApiSpex.Schema{type: :string, format: :binary}},
      not_found: {"No such image", "application/json", Schemas.Error}
    ]
  )

  def api_show(conn, %{"conversation_id" => conv_id, "turn_id" => turn_id, "position" => pos}) do
    serve_image(conn, conv_id, turn_id, pos)
  end

  # sobelow_skip ["XSS.SendResp", "XSS.ContentType"] — media type is checked
  # against TurnImage.valid_media_types/0 and the response pins nosniff +
  # a sandboxing CSP precisely because the bytes are client-originated.
  defp serve_image(conn, conv_id, turn_id, pos_str) do
    user_id = conn.assigns.current_user.id

    with {position, ""} <- Integer.parse(pos_str),
         {:ok, conv_id} <- Ecto.UUID.cast(conv_id),
         {:ok, turn_id} <- Ecto.UUID.cast(turn_id),
         turn when not is_nil(turn) <-
           Conversations.get_turn_by_conversation(turn_id, conv_id, user_id),
         # Ownership established by the scoped turn lookup above.
         image when not is_nil(image) <- Conversations._unsafe_get_turn_image(turn.id, position),
         true <- image.media_type in TurnImage.valid_media_types() do
      conn
      |> put_resp_content_type(image.media_type)
      # Stored bytes and their media_type both originate from client input, so
      # pin the type the browser is allowed to infer. Without this a row whose
      # media_type slipped past ingest validation would be served as active
      # content from the app's own origin.
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("content-security-policy", "default-src 'none'; sandbox")
      |> put_resp_header("cache-control", "private, max-age=3600")
      |> send_resp(200, image.data)
    else
      _ -> send_resp(conn, 404, "Not Found")
    end
  end
end
