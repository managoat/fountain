defmodule FountainWeb.AgentAvatarController do
  @moduledoc """
  Agent avatars, for bearer tokens (`/api/agents/:id/avatar`, #528).

  Avatars were entirely outside the API: upload and delete lived only in the
  agents LiveView, and even *reading* the bytes needed a session. `fountain
  apply` shipping an avatar file had nowhere to send it. The session route
  (`GET /agents/:id/avatar`) went with the console's agent pages (ADR 0076);
  nothing in the console renders an avatar now.

  Every path here treats the bytes as client-originated: the media type is
  validated at ingest against `Fountain.Images.valid_media_types/0` **and**
  re-checked at serve time, and responses pin `nosniff` plus a sandboxing CSP.
  """

  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Fountain.{Agents, Images}
  alias FountainWeb.Audited
  alias FountainWeb.Schemas

  action_fallback FountainWeb.FallbackController

  # 5 MB.
  @max_bytes 5_242_880

  tags(["Agents"])

  operation(:api_show,
    summary: "Fetch an agent's avatar",
    description:
      "The image bytes, with the stored media type. 404 when the agent has no " <>
        "avatar — the same answer as an agent that does not exist, so this is " <>
        "not a probe for ids.",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Image bytes", "image/*", %OpenApiSpex.Schema{type: :string, format: :binary}},
      not_found: {"No avatar", "application/json", Schemas.Error}
    ]
  )

  # sobelow_skip ["XSS.SendResp", "XSS.ContentType"] — media type is checked
  # against Fountain.Images.valid_media_types/0 and the response pins
  # nosniff + a sandboxing CSP precisely because the bytes are
  # client-originated. Same treatment as TurnImageController.
  def api_show(conn, %{"id" => id}) do
    serve_avatar(conn, id, conn.assigns.current_user.id)
  end

  operation(:api_update,
    summary: "Upload an agent's avatar",
    description:
      "Send the raw image bytes with an image content-type (`image/png`, " <>
        "`image/jpeg`, `image/gif`, `image/webp`), or JSON with base64 `data` " <>
        "and a `media_type`. Replaces any existing avatar. 5 MB maximum.",
    parameters: [id: [in: :path, type: :string, required: true]],
    request_body: {"Image", "application/json", Schemas.AvatarRequest},
    responses: [
      ok: {"Agent", "application/json", Schemas.AgentResponse},
      not_found: {"Not found", "application/json", Schemas.Error},
      request_entity_too_large: {"Too large", "application/json", Schemas.Error},
      unsupported_media_type: {"Unsupported type", "application/json", Schemas.Error},
      unprocessable_entity: {"Invalid image", "application/json", Schemas.Error}
    ]
  )

  def api_update(conn, %{"id" => id} = params) do
    user = conn.assigns.current_user

    with %_{} = agent <- fetch_agent(id, user.id),
         {:ok, data, media_type, conn} <- read_image(conn, params),
         {:ok, _} <- Agents.upload_avatar(agent, data, media_type, Audited.attribution(conn)) do
      # The agent is what the caller cares about after the write — it now
      # carries avatar_media_type, which is how a client knows one exists.
      #
      # Rendered explicitly rather than through `render/3`: this scope has no
      # `plug :accepts` (the GET below serves image bytes and would 406 on
      # `Accept: image/*`), so there is no negotiated format to render into.
      json(
        conn,
        FountainWeb.AgentJSON.show(%{agent: Agents.get_agent_with_counts(agent.id, user.id)})
      )
    else
      nil ->
        {:error, :not_found}

      {:error, :too_large} ->
        error(conn, :request_entity_too_large, "avatar_too_large", "Avatars are capped at 5 MB.")

      {:error, :invalid_base64} ->
        error(conn, :unprocessable_entity, "invalid_base64", "`data` is not valid base64.")

      {:error, :empty} ->
        error(conn, :unprocessable_entity, "empty_image", "The request carried no image bytes.")

      {:error, reason} when reason in [:unsupported_media_type, :invalid_media_type] ->
        error(
          conn,
          :unsupported_media_type,
          "unsupported_media_type",
          "Send one of #{Enum.join(Images.valid_media_types(), ", ")}, either as the " <>
            "request content-type with raw bytes, or as JSON with data + media_type."
        )
    end
  end

  operation(:api_delete,
    summary: "Delete an agent's avatar",
    description: "Idempotent — an agent with no avatar is still a 204.",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      no_content: "Deleted",
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def api_delete(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    case fetch_agent(id, user.id) do
      nil ->
        {:error, :not_found}

      agent ->
        # Idempotent: clearing an absent avatar is a no-op, not a 404. The
        # resource being addressed is the agent, and it exists.
        {:ok, _} = Agents.delete_avatar(agent, Audited.attribution(conn))
        send_resp(conn, :no_content, "")
    end
  end

  ## Private

  defp fetch_agent(id, user_id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Agents.get_agent(uuid, user_id)
      :error -> nil
    end
  end

  defp serve_avatar(conn, id, user_id) do
    with %{avatar_media_type: media_type} = agent
         when not is_nil(media_type) <- fetch_agent(id, user_id),
         # Re-checked at serve time: a row whose media_type slipped past
         # ingest validation (or predates it) must not be served as active
         # content from the app's own origin, where the page CSP allows
         # 'unsafe-inline'.
         true <- Images.valid_media_type?(media_type),
         %{data: data} <- Agents.get_avatar(agent) do
      conn
      |> put_resp_content_type(media_type)
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("content-security-policy", "default-src 'none'; sandbox")
      |> put_resp_header("cache-control", "private, max-age=3600")
      |> send_resp(200, data)
    else
      _ -> send_resp(conn, 404, "")
    end
  end

  # Two shapes, because both are natural: raw bytes with an image content-type
  # (what `curl --data-binary @avatar.png` sends), and base64 in JSON, which is
  # how prompt images already travel.
  defp read_image(conn, params) do
    case content_type(conn) do
      "application/json" -> decode_json_image(conn, params)
      type -> read_raw_image(conn, type)
    end
  end

  defp read_raw_image(conn, type) do
    if Images.valid_media_type?(type) do
      case Plug.Conn.read_body(conn, length: @max_bytes) do
        {:ok, "", _conn} -> {:error, :empty}
        {:ok, body, conn} -> {:ok, body, type, conn}
        # Plug stopped at the cap and says there is more: that is the 413.
        {:more, _partial, _conn} -> {:error, :too_large}
        {:error, _} -> {:error, :empty}
      end
    else
      {:error, :unsupported_media_type}
    end
  end

  defp decode_json_image(conn, %{"data" => data, "media_type" => media_type})
       when is_binary(data) and is_binary(media_type) do
    cond do
      not Images.valid_media_type?(media_type) ->
        {:error, :unsupported_media_type}

      # Base64 inflates by ~4/3, so anything past this cannot decode to a
      # legal image; refuse before spending the decode.
      byte_size(data) > @max_bytes * 2 ->
        {:error, :too_large}

      true ->
        decode_base64(conn, data, media_type)
    end
  end

  defp decode_json_image(_conn, _params), do: {:error, :unsupported_media_type}

  defp decode_base64(conn, data, media_type) do
    case Base.decode64(data, padding: false) do
      {:ok, ""} -> {:error, :empty}
      {:ok, bytes} when byte_size(bytes) > @max_bytes -> {:error, :too_large}
      {:ok, bytes} -> {:ok, bytes, media_type, conn}
      :error -> {:error, :invalid_base64}
    end
  end

  defp content_type(conn) do
    conn
    |> get_req_header("content-type")
    |> List.first()
    |> to_string()
    |> String.split(";")
    |> List.first()
    |> String.trim()
    |> String.downcase()
  end

  defp error(conn, status, error, message) do
    conn
    |> put_status(status)
    |> json(%{error: error, message: message})
  end
end
