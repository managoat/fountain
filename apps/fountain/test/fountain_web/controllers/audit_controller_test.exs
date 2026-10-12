defmodule FountainWeb.AuditControllerTest do
  @moduledoc """
  The account's audit trail over the API (#526).

  Before this, programmatic access meant scraping the `/audit` LiveView.
  """

  use FountainWeb.ConnCase, async: true

  alias Fountain.Audit

  setup do
    user = insert_verified_user()
    {_rec, key} = insert_api_key(user)
    {:ok, user: user, key: key}
  end

  defp record(user, attrs) do
    {:ok, event} =
      Audit.record(
        Map.merge(
          %{
            action: "vault.secret.write",
            resource_type: "vault_secret",
            actor: "api",
            user_id: user.id
          },
          attrs
        )
      )

    event
  end

  defp list(conn, key, query \\ "") do
    conn |> authed_with_key(key) |> get("/api/audit" <> query) |> json_response(200)
  end

  # Follows next_cursor until the server says there is no more, returning every
  # id seen in order plus the final page (for its has_more).
  defp page_to_end(conn, key, page, acc \\ []) do
    acc = acc ++ Enum.map(page["data"], & &1["id"])

    if page["meta"]["has_more"] do
      next = list(conn, key, "?limit=2&before=#{page["meta"]["next_cursor"]}")
      page_to_end(conn, key, next, acc)
    else
      {acc, page}
    end
  end

  describe "GET /api/audit" do
    test "returns the tenant's events newest first with the columns the UI shows", %{
      conn: conn,
      user: user,
      key: key
    } do
      _older = record(user, %{action: "agent.created", resource_type: "agent"})

      newer =
        record(user, %{
          action: "vault.secret.write",
          resource_id: "vault-123",
          metadata: %{"key" => "TOKEN"},
          request_ip: "203.0.113.7"
        })

      body = list(conn, key)
      first = hd(body["data"])

      assert first["id"] == newer.id
      assert first["action"] == "vault.secret.write"
      assert first["resource_type"] == "vault_secret"
      assert first["resource_id"] == "vault-123"
      assert first["actor"] == "api"
      assert first["metadata"] == %{"key" => "TOKEN"}
      assert first["request_ip"] == "203.0.113.7"
      assert first["inserted_at"]
    end

    test "never shows another tenant's events", %{conn: conn, key: key} do
      other = insert_verified_user()
      record(other, %{action: "someone.elses.event", resource_id: "not-yours"})

      body = list(conn, key)

      refute Enum.any?(body["data"], &(&1["action"] == "someone.elses.event"))
    end

    test "requires authentication", %{conn: conn} do
      conn
      |> put_req_header("accept", "application/json")
      |> get("/api/audit")
      |> json_response(401)
    end
  end

  describe "filters" do
    setup %{user: user} do
      record(user, %{action: "agent.created", resource_type: "agent"})
      record(user, %{action: "vault.secret.write", resource_type: "vault_secret"})
      record(user, %{action: "vault.secret.delete", resource_type: "vault_secret"})
      :ok
    end

    test "action_prefix narrows to a family of actions", %{conn: conn, key: key} do
      body = list(conn, key, "?action_prefix=vault.")

      assert length(body["data"]) == 2
      assert Enum.all?(body["data"], &String.starts_with?(&1["action"], "vault."))
    end

    test "action_prefix is a literal, not a LIKE pattern", %{conn: conn, key: key} do
      # Without escaping, `%` would match the whole trail — a filter that
      # silently returns everything is worse than one that returns nothing.
      assert list(conn, key, "?action_prefix=%")["data"] == []
      assert list(conn, key, "?action_prefix=_gent.created")["data"] == []
    end

    test "resource_type is an exact match", %{conn: conn, key: key} do
      body = list(conn, key, "?resource_type=agent")

      # Exact: the two `vault_secret` rows are out. What is in is every `agent`
      # row the account has — the one this setup recorded, and the starter
      # agent verification planted (ADR 0038).
      assert Enum.map(body["data"], & &1["resource_type"]) == ["agent", "agent"]
    end

    test "since and until bound the window", %{conn: conn, user: user, key: key} do
      # Everything above was recorded "now"; an until in the past excludes it.
      past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.to_iso8601()
      future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()

      assert list(conn, key, "?until=#{past}")["data"] == []
      assert list(conn, key, "?since=#{past}")["data"] != []
      assert list(conn, key, "?since=#{future}")["data"] == []

      assert length(list(conn, key, "?since=#{past}&until=#{future}")["data"]) ==
               length(Audit.list_recent_for_user(user.id, 100))
    end

    test "a malformed timestamp is refused rather than ignored", %{conn: conn, key: key} do
      # Ignoring it would return the unfiltered trail and read as "nothing
      # matched my window".
      conn
      |> authed_with_key(key)
      |> get("/api/audit?since=yesterday")
      |> json_response(400)
    end
  end

  describe "pagination" do
    test "pages backwards through history with next_cursor", %{conn: conn, user: user, key: key} do
      for i <- 1..5, do: record(user, %{action: "event.#{i}"})

      page1 = list(conn, key, "?limit=2")
      assert length(page1["data"]) == 2
      assert page1["meta"]["has_more"]

      # Paged to exhaustion rather than a fixed number of pages: the trail is
      # no longer just what this test recorded. `insert_api_key` in the setup
      # audits its mint (#542) and creating the user audits the registration
      # (#544), so hardcoding a page count makes this test a hostage to every
      # future addition to the campaign.
      {ids, last_page} = page_to_end(conn, key, page1)

      assert length(ids) == length(Audit.list_recent_for_user(user.id, 100))
      assert ids == Enum.uniq(ids)
      assert ids == Enum.sort(ids, :desc)
      refute last_page["meta"]["has_more"]
    end

    test "the limit is capped", %{conn: conn, user: user, key: key} do
      record(user, %{})
      assert list(conn, key, "?limit=99999")["meta"]["limit"] == 500
    end

    test "an empty trail returns a null cursor rather than looping", %{conn: conn, key: key} do
      body = list(conn, key, "?action_prefix=nothing.matches.this")

      assert body["data"] == []
      assert body["meta"]["next_cursor"] == nil
      refute body["meta"]["has_more"]
    end
  end
end
