defmodule FountainWeb.CreditsApiControllerTest do
  @moduledoc """
  Billing self-serve over the API (#524).

  A CLI user who hit the credit gate got a 402 and no programmatic route out
  of it: usage numbers and Checkout lived in `CreditsLive`.
  """

  # async: false — credits_enabled is application env.
  use FountainWeb.ConnCase, async: false
  use Mimic

  setup do
    user = insert_active_user()
    {_rec, key} = insert_api_key(user)
    {:ok, user: user, key: key}
  end

  defp with_billing_disabled(fun) do
    previous = Application.get_env(:fountain, :credits_enabled)
    Application.put_env(:fountain, :credits_enabled, false)

    try do
      fun.()
    after
      Application.put_env(:fountain, :credits_enabled, previous)
    end
  end

  describe "GET /api/account/billing" do
    test "reports the account's shape and current-period usage", %{conn: conn, key: key} do
      body =
        conn
        |> authed_with_key(key)
        |> get("/api/account/billing")
        |> json_response(200)

      assert body["data"]["comped"] == false
      assert body["data"]["has_stripe_customer"] == false
      # The opening credit funds five sandboxes (ADR 0031).
      assert body["data"]["sandbox_cap"] == 2
      refute Map.has_key?(body["data"], "status")
      refute Map.has_key?(body["data"], "plan")
      assert body["data"]["usage"]["conversations"] == 0
      assert body["data"]["usage"]["turns"] == 0
      assert body["data"]["usage"]["sandbox_minutes"] == 0
      assert body["data"]["usage"]["sandbox_minutes_by_provider"] == %{}
      assert body["data"]["period"]["start"]
      assert body["data"]["period"]["end"]
      # The calendar month, always (ADR 0031); there is no `source` to say so.
      refute Map.has_key?(body["data"]["period"], "source")
    end

    test "turn hours travel with the usage", %{
      conn: conn,
      user: user,
      key: key
    } do
      # Turn hours, not sandbox minutes: an hour with a prompt in flight.
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      {period_start, _} = Fountain.Usage.current_month_range()
      started = Enum.max([DateTime.add(now, -30, :minute), period_start], DateTime)

      sandbox =
        insert_sandbox(
          user_id: user.id,
          provider: "sprites",
          status: "terminated",
          inserted_at: started,
          terminated_at: now
        )

      agent = insert_agent(user_id: user.id)

      conversation =
        insert_conversation(user_id: user.id, agent_id: agent.id, sandbox: sandbox)

      {:ok, _} =
        Fountain.Conversations._unsafe_create_turn(%{
          conversation_id: conversation.id,
          turn_number: 1,
          prompt: "hello",
          status: "completed",
          started_at: started,
          ended_at: now
        })

      expected = Float.round(DateTime.diff(now, started, :second) / 3600, 2)

      body =
        conn
        |> authed_with_key(key)
        |> get("/api/account/billing")
        |> json_response(200)

      assert body["data"]["usage"]["turn_hours"] == expected
      # The allowance shape is gone (ADR 0030): credits are what act.
      refute Map.has_key?(body["data"]["usage"], "turn_hours_included")
    end

    test "an idle sandbox spends sandbox minutes and no turn hours", %{
      conn: conn,
      user: user,
      key: key
    } do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      {period_start, _} = Fountain.Usage.current_month_range()
      started = Enum.max([DateTime.add(now, -30, :minute), period_start], DateTime)

      insert_sandbox(
        user_id: user.id,
        provider: "sprites",
        status: "terminated",
        inserted_at: started,
        terminated_at: now
      )

      body =
        conn
        |> authed_with_key(key)
        |> get("/api/account/billing")
        |> json_response(200)

      assert body["data"]["usage"]["sandbox_minutes"] > 0
      assert body["data"]["usage"]["turn_hours"] == 0.0
    end

    test "sandbox minutes are reported per provider", %{conn: conn, user: user, key: key} do
      # Which provider ran the minutes is what makes them attributable to a
      # cost: a minute on each is bought at a different price.
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      {period_start, _} = Fountain.Usage.current_month_range()

      # Clamped to the month the endpoint reports on, so the run is ten minutes
      # long every day except the first ten minutes of a month, when it is
      # shorter — and the expected value follows it rather than going stale.
      started =
        [DateTime.add(now, -10, :minute), period_start]
        |> Enum.max(DateTime)

      insert_sandbox(
        user_id: user.id,
        provider: "e2b",
        status: "terminated",
        inserted_at: started,
        terminated_at: now
      )

      expected = Float.round(DateTime.diff(now, started, :second) / 60, 2)

      body =
        conn
        |> authed_with_key(key)
        |> get("/api/account/billing")
        |> json_response(200)

      assert body["data"]["usage"]["sandbox_minutes"] == expected
      assert body["data"]["usage"]["sandbox_minutes_by_provider"] == %{"e2b" => expected}
    end

    test "is 404 with billing: disabled on a self-hosted instance", %{conn: conn, key: key} do
      with_billing_disabled(fn ->
        body =
          conn
          |> authed_with_key(key)
          |> get("/api/account/billing")
          |> json_response(404)

        assert body["billing"] == "disabled"
      end)
    end

    test "a sprite token cannot read the account's billing state", %{conn: conn, user: user} do
      {_rec, sprite_key} = insert_sprite_api_key(user)

      conn
      |> authed_with_key(sprite_key)
      |> get("/api/account/billing")
      |> json_response(403)
    end

    test "requires authentication", %{conn: conn} do
      conn
      |> put_req_header("accept", "application/json")
      |> get("/api/account/billing")
      |> json_response(401)
    end
  end
end
