defmodule FountainWeb.FallbackControllerTest do
  @moduledoc """
  Tests for FallbackController error clauses, exercised through AgentController
  which declares `action_fallback FountainWeb.FallbackController`.
  """
  use FountainWeb.ConnCase, async: true

  test "an uncertain reset reports an explicit conflict", %{conn: conn} do
    conn = FountainWeb.FallbackController.call(conn, {:error, :sandbox_reset_pending})
    assert %{"error" => "sandbox_reset_pending", "message" => message} = json_response(conn, 409)
    assert message =~ "Fountain retries automatically"
    assert message =~ "administrator can retry from the admin sandbox list"
  end

  # Driven directly rather than through the route: reaching this refusal needs
  # an agent on the runner provider, and `runners_enabled` is global
  # application env this async module must not write (#1214). The `message` is
  # the assertion that matters — the terminal safety net answers 422 with the
  # bare atom, so a status-only check would pass with no clause at all (#1632).
  test "a sprite_name on the runner provider is refused with a reason", %{conn: conn} do
    conn = FountainWeb.FallbackController.call(conn, {:error, :sprite_name_not_supported})
    body = json_response(conn, 422)
    assert body["error"] == "sprite_name_not_supported"
    assert body["message"] =~ "self-hosted runner"
  end

  test "every refusal the machine owner can answer has a clause of its own", %{conn: conn} do
    # `Fountain.Machines.Machine.destroy/2` normalizes the protocol's precise
    # vocabulary (`:machine_busy`, `:superseded`, `{:database, sqlstate}`) into
    # these three before anything user-facing sees it (ADR 0058 stage 5), and a
    # terminate renders whatever it answers through here. A tuple would have no
    # clause at all — a 500 — and a retryable refusal caught by the terminal
    # safety net would be a 422 that no SDK retries. `destroy_test.exs` pins the
    # other half: that nothing the door answers is a tuple.
    for {reason, status} <- [
          {:sandbox_unavailable, 503},
          {:not_found, 404},
          {:provider_transaction_open, 422}
        ] do
      conn = FountainWeb.FallbackController.call(conn, {:error, reason})
      assert json_response(conn, status)["error"] == Atom.to_string(reason)
    end
  end

  test "sandbox_unavailable is retryable on the wire, and stage 6a changed nothing about it",
       %{conn: conn} do
    # ADR 0058 stage 6a made this the refusal a wake, an attach and a
    # rehydrate answer when a machine's owner is mid-operation, instead of
    # minting a second word for it (Jake, 2026-09-16; #2304 was written for
    # the second word and closed unmerged). That decision rests on this
    # response already being right: 503 with a `Retry-After`, which every SDK
    # maps to `NotReadyError`. It is pinned here so a change to the clause is
    # a change to the decision.
    conn = FountainWeb.FallbackController.call(conn, {:error, :sandbox_unavailable})

    body = json_response(conn, 503)
    assert body["error"] == "sandbox_unavailable"
    assert Plug.Conn.get_resp_header(conn, "retry-after") == ["30"]

    # And a sentence, since round 1: the wake and attach doors made this the
    # commonest 503 in the product, and the CLI prints `http 503:
    # sandbox_unavailable` and nothing else when the body has no `message`. It
    # names no cause, because the three sources do not share one — only the
    # outcome (round 2).
    assert body["message"] ==
             "this sandbox cannot take that request right now; send it again shortly"
  end

  test "the protocol's own words land on the safety net, which is why they are translated" do
    # Stated here so the cost of *not* translating is on the record next to the
    # clauses above. `:machine_busy` is retryable contention and `:superseded`
    # is a destroy somebody else completed; rendered raw they are a 422 with an
    # "unmapped error atom" warning per request — a permanent status for a
    # transient condition, outside every SDK's retry mapping and outside the
    # `terminate`/`delete` operations' declared responses. Stage 5a answered
    # `:sandbox_unavailable` instead, which is already a 503 above, and stage
    # 6a made that permanent rather than minting the second word the ADR had
    # scheduled. `machines/destroy_test.exs` is what proves the door does it.
    for reason <- [:machine_busy, :superseded] do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          body =
            Phoenix.ConnTest.build_conn()
            |> FountainWeb.FallbackController.call({:error, reason})
            |> json_response(422)

          assert body["error"] == Atom.to_string(reason)
        end)

      assert log =~ "unmapped error atom"
    end
  end

  test "unusable opening input names itself rather than falling to the safety net", %{conn: conn} do
    for {reason, error} <- [invalid_prompt: "invalid_prompt", invalid_images: "invalid_images"] do
      body =
        conn
        |> FountainWeb.FallbackController.call({:error, reason})
        |> json_response(422)

      assert body["error"] == error
      assert is_binary(body["message"]) and body["message"] != ""
    end
  end

  test "inference source refusals carry stable codes and an actionable message", %{conn: conn} do
    for {reason, status, advice} <- [
          {:inference_source_changed, 409, "start a new conversation"},
          {:inference_credential_unusable, 422, "select another set"},
          {:inference_credential_conflict, 422, "keep one credential source"},
          {:codex_inference_conflict, 409, "fresh sandbox"}
        ] do
      body =
        conn |> FountainWeb.FallbackController.call({:error, reason}) |> json_response(status)

      assert body["error"] == Atom.to_string(reason)
      assert body["message"] =~ advice
    end
  end

  describe "{:error, %Ecto.Changeset{}} → 422" do
    test "POST /api/agents with missing required fields returns 422 with errors body", %{
      conn: conn
    } do
      user = insert_verified_user()
      {_key, raw_key} = insert_api_key(user)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/agents", %{})

      assert %{"errors" => _} = json_response(conn, 422)
    end
  end

  describe "{:error, :vault_not_found} → 404" do
    test "POST /api/conversations with nonexistent vault_id returns 404", %{conn: conn} do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      {_key, raw_key} = insert_api_key(user)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/conversations", %{
          agent_id: agent.id,
          vault_id: Ecto.UUID.generate()
        })

      assert %{"error" => "vault_not_found"} = json_response(conn, 404)
    end
  end

  describe "{:error, binary_reason} → 400" do
    test "binary error reason returns 400 with error body", %{conn: conn} do
      conn = FountainWeb.FallbackController.call(conn, {:error, "custom_error_message"})
      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "custom_error_message"
    end
  end

  describe "{:error, :sprite_probe_failed} → 503 (#799)" do
    test "a wake that could not reach the sandbox provider is retryable, not a 422", %{
      conn: conn
    } do
      conn = FountainWeb.FallbackController.call(conn, {:error, :sprite_probe_failed})
      assert conn.status == 503
      assert get_resp_header(conn, "retry-after") == ["10"]
      assert %{"error" => "sandbox_probe_failed"} = Jason.decode!(conn.resp_body)
    end
  end

  describe "{:error, :not_found} → 404" do
    test "GET /api/agents/:id with a nonexistent UUID returns 404 with error body", %{conn: conn} do
      user = insert_verified_user()
      {_key, raw_key} = insert_api_key(user)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> get("/api/agents/#{Ecto.UUID.generate()}")

      assert %{"error" => "not_found"} = json_response(conn, 404)
    end

    test "PUT /api/agents/:id with a nonexistent UUID returns 404", %{conn: conn} do
      user = insert_verified_user()
      {_key, raw_key} = insert_api_key(user)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> put_json("/api/agents/#{Ecto.UUID.generate()}", %{})

      assert json_response(conn, 404)
    end

    test "DELETE /api/agents/:id with a nonexistent UUID returns 404", %{conn: conn} do
      user = insert_verified_user()
      {_key, raw_key} = insert_api_key(user)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> delete("/api/agents/#{Ecto.UUID.generate()}")

      assert %{"error" => "not_found"} = json_response(conn, 404)
    end

    test "a user cannot see another user's agent (cross-tenant isolation → 404)", %{conn: conn} do
      owner = insert_verified_user()
      other = insert_verified_user()
      agent = insert_agent(%{"user_id" => owner.id})

      {_key, raw_key} = insert_api_key(other)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> get("/api/agents/#{agent.id}")

      assert %{"error" => "not_found"} = json_response(conn, 404)
    end
  end
end
