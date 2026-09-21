defmodule FountainWeb.ChatGPTSubscriptionControllerTest do
  @moduledoc """
  `/api/account/chatgpt-subscriptions` and its attempts (ADR 0060 decision 3).

  What the ADR's stage 4 asks of the API: full-scope authorization, ownership
  as a 404, every refusal's status and code, redaction of everything that is
  not the owner's to read, and that turning linking off closes one door.
  `async: false`: the broker, the rollout flag and the ceiling are application
  state, and the auth server's stub is shared.
  """

  use FountainWeb.ConnCase, async: false
  use Oban.Testing, repo: Fountain.Repo

  import Ecto.Query, only: [from: 2]
  import Fountain.BrokerTestHelpers
  import Fountain.ChatGPTFixtures

  alias Fountain.ChatGPTAccounts
  alias Fountain.ChatGPTAccounts.LinkAttempt
  alias Fountain.InferenceCredentials
  alias Fountain.PlatformChatGPT.Account
  alias Fountain.Repo
  alias Fountain.Workers.ChatGPTLinkAttempt, as: Worker

  @base "/api/account/chatgpt-subscriptions"

  @user_code "WXYZ-9876"
  @device_auth_id "deviceauth_SECRET_api"
  @authorization_code "authcode_SECRET_api"
  @verifier "verifier_SECRET_api"
  @refresh_token "rt_SECRET_api"

  setup %{conn: conn} do
    enable_chatgpt_subscriptions()
    user = insert_verified_user()
    {_rec, key} = insert_api_key(user)
    other = insert_verified_user()
    {_rec, other_key} = insert_api_key(other)

    %{
      conn: authed_with_key(conn, key),
      user: user,
      other: other,
      other_conn: authed_with_key(build_conn(), other_key)
    }
  end

  # The auth server: a device code for every start, and an approval.
  defp stub_sign_in(access \\ access_token(), account_id \\ "acct-api") do
    test_pid = self()

    stub_auth(%{
      "/api/accounts/deviceauth/usercode" => fn _ ->
        send(test_pid, :device_start)
        {200, %{"user_code" => @user_code, "device_auth_id" => @device_auth_id, "interval" => 5}}
      end,
      "/api/accounts/deviceauth/token" => fn _ ->
        {200, %{"authorization_code" => @authorization_code, "code_verifier" => @verifier}}
      end,
      "/oauth/token" => fn _ ->
        {200,
         %{
           "access_token" => access,
           "refresh_token" => @refresh_token,
           "id_token" => id_token(%{account_id: account_id, email: "owner@example.com"})
         }}
      end
    })
  end

  defp link!(user, name, account_id) do
    {:ok, grant} = ChatGPTAccounts.connect_for_user(user.id, name, user_tokens(account_id))
    grant
  end

  defp start!(conn, body), do: conn |> post_json(@base <> "/attempts", body) |> json_response(201)

  defp approve!(attempt_id, user),
    do: :ok = perform_job(Worker, %{"attempt_id" => attempt_id, "user_id" => user.id})

  describe "scope" do
    test "a sprite-scoped key gets insufficient_scope on every route, and nothing happens",
         %{user: user} do
      grant = link!(user, "Work", "acct-work")
      {:ok, attempt} = start_attempt(user, %{grant_id: grant.grant_id})

      {_rec, raw} = insert_sprite_api_key(user)
      conn = authed_with_key(build_conn(), raw)
      id = grant.grant_id

      responses = [
        get(conn, @base),
        patch_json(conn, "#{@base}/#{id}", %{"name" => "Hijacked"}),
        post_json(conn, "#{@base}/#{id}/disconnect", %{}),
        delete(conn, "#{@base}/#{id}"),
        post_json(conn, "#{@base}/attempts", %{"name" => "Mine now"}),
        get(conn, "#{@base}/attempts"),
        get(conn, "#{@base}/attempts/#{attempt.id}"),
        delete(conn, "#{@base}/attempts/#{attempt.id}")
      ]

      for response <- responses do
        assert %{"reason" => "insufficient_scope"} = body = json_response(response, 403)
        refute inspect(body) =~ attempt.user_code
      end

      assert {:ok, %{name: "Work", status: "active"}} =
               ChatGPTAccounts.get_for_user(id, user.id)

      assert %LinkAttempt{state: "pending"} = Repo.get!(LinkAttempt, attempt.id)
      assert Repo.aggregate(LinkAttempt, :count) == 1
    end

    test "no key at all is a 401" do
      assert build_conn() |> get(@base) |> json_response(401)

      assert build_conn()
             |> post_json(@base <> "/attempts", %{"name" => "x"})
             |> json_response(401)
    end
  end

  describe "GET /chatgpt-subscriptions" do
    test "is empty, with the limit and the gate, for an account that holds none", %{conn: conn} do
      assert %{"data" => [], "count" => 0, "limit" => 5, "linking_enabled" => true} =
               conn |> get(@base) |> json_response(200)
    end

    test "lists the caller's subscriptions by name, and nobody else's",
         %{conn: conn, user: user, other: other} do
      link!(user, "Work", "acct-work")
      link!(user, "Personal", "acct-personal")
      link!(other, "Theirs", "acct-theirs")

      body = conn |> get(@base) |> json_response(200)

      assert ["Personal", "Work"] = Enum.map(body["data"], & &1["name"])
      assert body["count"] == 2

      assert %{
               "status" => "active",
               "plan_type" => "pro",
               "account_email" => "admin@example.com",
               "refreshable" => true,
               "revoked_reason" => nil,
               "exhausted_until" => nil
             } = hd(body["data"])
    end
  end

  describe "PATCH /chatgpt-subscriptions/:id" do
    test "renames, without touching the credential", %{conn: conn, user: user} do
      grant = link!(user, "Work", "acct-work")

      assert %{"data" => %{"name" => "Day job", "id" => id}} =
               conn
               |> patch_json("#{@base}/#{grant.grant_id}", %{"name" => "Day job"})
               |> json_response(200)

      assert id == grant.grant_id
      {:ok, renamed} = ChatGPTAccounts.get_for_user(grant.grant_id, user.id)
      assert renamed.generation == grant.generation

      assert %{actor: "api"} =
               Repo.get_by!(Fountain.Audit.Event,
                 user_id: user.id,
                 action: "chatgpt_grant.renamed"
               )
    end

    test "a duplicate or blank name is 422", %{conn: conn, user: user} do
      grant = link!(user, "Work", "acct-work")
      link!(user, "Personal", "acct-personal")

      assert %{"error" => "validation_failed", "errors" => %{"name" => [_]}} =
               conn
               |> patch_json("#{@base}/#{grant.grant_id}", %{"name" => "Personal"})
               |> json_response(422)

      assert conn
             |> patch_json("#{@base}/#{grant.grant_id}", %{"name" => ""})
             |> json_response(422)

      assert conn |> patch_json("#{@base}/#{grant.grant_id}", %{}) |> json_response(422)
    end

    test "an account that may no longer link is 403 chatgpt_owner_ineligible",
         %{conn: conn, user: user} do
      grant = link!(user, "Work", "acct-work")
      user |> Ecto.Changeset.change(%{principal: true}) |> Repo.update!()

      assert %{"error" => "chatgpt_owner_ineligible"} =
               conn
               |> patch_json("#{@base}/#{grant.grant_id}", %{"name" => "Day job"})
               |> json_response(403)

      # It can still see it and take it away.
      assert %{"count" => 1} = conn |> get(@base) |> json_response(200)
      assert conn |> post_json("#{@base}/#{grant.grant_id}/disconnect", %{}) |> json_response(200)
    end
  end

  describe "POST /chatgpt-subscriptions/:id/disconnect" do
    test "drops the tokens and keeps the row, and is a 200 again", %{conn: conn, user: user} do
      grant = link!(user, "Work", "acct-work")

      for _ <- 1..2 do
        assert %{
                 "data" => %{"status" => "disconnected", "refreshable" => false, "name" => "Work"}
               } =
                 conn
                 |> post_json("#{@base}/#{grant.grant_id}/disconnect", %{})
                 |> json_response(200)
      end

      assert %Account{access_token_ciphertext: nil, refresh_token_ciphertext: nil} =
               Repo.get!(Account, grant.grant_id)

      assert 1 ==
               Repo.aggregate(
                 from(e in Fountain.Audit.Event,
                   where: e.user_id == ^user.id and e.action == "chatgpt_grant.disconnected"
                 ),
                 :count
               )
    end
  end

  describe "DELETE /chatgpt-subscriptions/:id" do
    test "is refused while connected and while a set names it, then removes the row",
         %{conn: conn, user: user} do
      grant = link!(user, "Work", "acct-work")
      {:ok, set} = InferenceCredentials.create_set(user.id, "codex")
      {:ok, set} = InferenceCredentials.set_grant(set, grant.grant_id)

      assert %{"error" => "chatgpt_grant_still_connected"} =
               conn |> delete("#{@base}/#{grant.grant_id}") |> json_response(409)

      assert conn |> post_json("#{@base}/#{grant.grant_id}/disconnect", %{}) |> json_response(200)

      assert %{"error" => "chatgpt_grant_named_by_sets", "sets" => ["codex"]} =
               conn |> delete("#{@base}/#{grant.grant_id}") |> json_response(409)

      assert Repo.get(Account, grant.grant_id)

      {:ok, _} = InferenceCredentials.set_grant(set, nil)
      assert conn |> delete("#{@base}/#{grant.grant_id}") |> response(204)
      refute Repo.get(Account, grant.grant_id)
    end
  end

  describe "ownership" do
    test "another account's subscription and attempt are 404 on every route, and untouched",
         %{conn: conn, other_conn: other_conn, user: user, other: other} do
      grant = link!(user, "Work", "acct-work")
      {:ok, attempt} = start_attempt(user, %{grant_id: grant.grant_id})
      row = Repo.get!(Account, grant.grant_id)
      attempt_row = Repo.get!(LinkAttempt, attempt.id)
      stub_sign_in()
      id = grant.grant_id

      responses = [
        patch_json(other_conn, "#{@base}/#{id}", %{"name" => "Mine"}),
        post_json(other_conn, "#{@base}/#{id}/disconnect", %{}),
        delete(other_conn, "#{@base}/#{id}"),
        post_json(other_conn, "#{@base}/attempts", %{"grant_id" => id}),
        get(other_conn, "#{@base}/attempts/#{attempt.id}"),
        delete(other_conn, "#{@base}/attempts/#{attempt.id}")
      ]

      for response <- responses do
        assert %{"error" => "not_found"} = json_response(response, 404)
      end

      refute_received :device_start

      assert %{"data" => []} = other_conn |> get(@base) |> json_response(200)
      assert %{"data" => []} = other_conn |> get(@base <> "/attempts") |> json_response(200)

      assert Repo.get!(Account, grant.grant_id) == row
      assert Repo.get!(LinkAttempt, attempt.id) == attempt_row
      assert Repo.aggregate(from(a in LinkAttempt, where: a.user_id == ^other.id), :count) == 0

      # The owner's view of both is whole.
      assert %{"data" => [%{"id" => ^id}]} = conn |> get(@base) |> json_response(200)
    end

    test "ids that are not ids are 404, not 500", %{conn: conn} do
      assert conn |> get("#{@base}/attempts/nope") |> json_response(404)
      assert conn |> delete("#{@base}/attempts/nope") |> json_response(404)
      assert conn |> delete("#{@base}/nope") |> json_response(404)
      assert conn |> post_json("#{@base}/nope/disconnect", %{}) |> json_response(404)
    end
  end

  describe "POST /chatgpt-subscriptions/attempts" do
    test "answers 201 with the code to type, uncacheable, and links on approval",
         %{conn: conn, user: user} do
      access = access_token(3_600, %{"label" => "api"})
      stub_sign_in(access, "acct-api")

      response = post_json(conn, @base <> "/attempts", %{"name" => "Work"})

      assert %{
               "data" => %{
                 "id" => attempt_id,
                 "kind" => "link",
                 "name" => "Work",
                 "grant_id" => nil,
                 "state" => "pending",
                 "user_code" => @user_code,
                 "verification_url" => "https://auth.openai.com/codex/device",
                 "poll_interval" => 5,
                 "result_grant_id" => nil,
                 "failure" => nil
               }
             } = json_response(response, 201)

      assert get_resp_header(response, "cache-control") == ["no-store"]

      # A client that lost its state finds it again.
      listed = get(conn, @base <> "/attempts")

      assert %{"data" => [%{"id" => ^attempt_id, "user_code" => @user_code}]} =
               json_response(listed, 200)

      assert get_resp_header(listed, "cache-control") == ["no-store"]

      approve!(attempt_id, user)

      polled = get(conn, "#{@base}/attempts/#{attempt_id}")

      assert %{
               "data" => %{
                 "state" => "completed",
                 "user_code" => nil,
                 "verification_url" => nil,
                 "result_grant_id" => grant_id
               }
             } = json_response(polled, 200)

      assert get_resp_header(polled, "cache-control") == ["no-store"]
      assert %{"data" => []} = conn |> get(@base <> "/attempts") |> json_response(200)

      assert %{"data" => [%{"id" => ^grant_id, "name" => "Work", "status" => "active"}]} =
               conn |> get(@base) |> json_response(200)
    end

    test "a reconnect names the subscription, and the old credential serves until it commits",
         %{conn: conn, user: user} do
      grant = link!(user, "Work", "acct-work")
      stub_sign_in(access_token(), "acct-work")

      assert %{
               "data" => %{
                 "kind" => "reconnect",
                 "name" => nil,
                 "grant_id" => grant_id,
                 "id" => id
               }
             } =
               start!(conn, %{"grant_id" => grant.grant_id})

      assert grant_id == grant.grant_id

      assert {:ok, _} =
               ChatGPTAccounts.credential_for_user(grant.grant_id, user.id, grant.generation)

      assert %{"error" => "chatgpt_link_attempt_pending", "attempt_id" => ^id} =
               conn
               |> post_json(@base <> "/attempts", %{"grant_id" => grant.grant_id})
               |> json_response(409)

      approve!(id, user)

      assert %{"data" => %{"state" => "completed", "result_grant_id" => ^grant_id}} =
               conn |> get("#{@base}/attempts/#{id}") |> json_response(200)
    end

    test "both, neither, and a bad name are 422; the auth server is not asked", %{conn: conn} do
      stub_sign_in()

      for body <- [
            %{},
            %{"name" => "Work", "grant_id" => Ecto.UUID.generate()},
            %{"name" => "   "}
          ] do
        assert %{"error" => "validation_failed", "errors" => %{"name" => [_ | _]}} =
                 conn |> post_json(@base <> "/attempts", body) |> json_response(422)
      end

      assert conn |> post_json(@base <> "/attempts", %{"name" => 7}) |> json_response(422)
      refute_received :device_start
    end

    test "a full account is 409 chatgpt_grant_limit_reached with the numbers",
         %{conn: conn, user: user} do
      previous = Application.fetch_env!(:fountain, :chatgpt_grant_ceiling)
      Application.put_env(:fountain, :chatgpt_grant_ceiling, 1)
      on_exit(fn -> Application.put_env(:fountain, :chatgpt_grant_ceiling, previous) end)
      link!(user, "Work", "acct-work")
      stub_sign_in()

      assert %{"error" => "chatgpt_grant_limit_reached", "count" => 1, "limit" => 1} =
               conn
               |> post_json(@base <> "/attempts", %{"name" => "Personal"})
               |> json_response(409)

      assert %{"limit" => 1, "count" => 1} = conn |> get(@base) |> json_response(200)
      refute_received :device_start
    end

    test "a fourth open sign-in is 409 chatgpt_link_attempts_exceeded", %{conn: conn} do
      stub_sign_in()
      for n <- 1..3, do: start!(conn, %{"name" => "Grant #{n}"})

      assert %{"error" => "chatgpt_link_attempts_exceeded", "count" => 3, "limit" => 3} =
               conn
               |> post_json(@base <> "/attempts", %{"name" => "Fourth"})
               |> json_response(409)
    end

    test "a name a subscription already has is 422", %{conn: conn, user: user} do
      link!(user, "Work", "acct-work")
      stub_sign_in()

      assert %{"errors" => %{"name" => ["already names a ChatGPT subscription on this account"]}} =
               conn |> post_json(@base <> "/attempts", %{"name" => "Work"}) |> json_response(422)
    end

    test "an account that may not link is 403", %{conn: conn, user: user} do
      stub_sign_in()
      user |> Ecto.Changeset.change(%{principal: true}) |> Repo.update!()

      assert %{"error" => "chatgpt_owner_ineligible"} =
               conn |> post_json(@base <> "/attempts", %{"name" => "Work"}) |> json_response(403)
    end

    @tag :capture_log
    test "an auth server that gives no code is 502, and nothing is left behind", %{conn: conn} do
      stub_auth(%{"/api/accounts/deviceauth/usercode" => fn _ -> {503, %{}} end})

      assert %{"error" => "chatgpt_auth_unreachable"} =
               conn |> post_json(@base <> "/attempts", %{"name" => "Work"}) |> json_response(502)

      assert Repo.aggregate(LinkAttempt, :count) == 0
    end

    test "a tenant key that will not load is 503", %{conn: conn, user: user} do
      stub_sign_in()
      Repo.delete_all(from(k in Fountain.Accounts.UserDataKey, where: k.user_id == ^user.id))

      assert %{"error" => "chatgpt_tenant_key_unavailable"} =
               conn |> post_json(@base <> "/attempts", %{"name" => "Work"}) |> json_response(503)

      refute_received :device_start
    end

    test "the eleventh in an hour is 429 with when to come back, whichever key asks",
         %{conn: conn, user: user} do
      stub_sign_in()

      for n <- 1..10 do
        %{"data" => %{"id" => id}} = start!(conn, %{"name" => "Grant #{n}"})
        assert conn |> delete("#{@base}/attempts/#{id}") |> json_response(200)
        assert_received :device_start
      end

      {_rec, second_key} = insert_api_key(user)

      for asking <- [conn, authed_with_key(build_conn(), second_key)] do
        refused = post_json(asking, @base <> "/attempts", %{"name" => "Eleventh"})

        assert %{
                 "error" => "chatgpt_link_attempts_rate_limited",
                 "limit" => 10,
                 "retry_after_seconds" => seconds
               } = json_response(refused, 429)

        assert seconds in 1..3600
        assert get_resp_header(refused, "retry-after") == [Integer.to_string(seconds)]
      end

      refute_received :device_start
      assert Repo.aggregate(LinkAttempt, :count) == 10
    end
  end

  describe "DELETE /chatgpt-subscriptions/attempts/:id" do
    test "cancels, is a 200 again, and an approval afterwards links nothing",
         %{conn: conn, user: user} do
      stub_sign_in()
      %{"data" => %{"id" => id}} = start!(conn, %{"name" => "Work"})

      for _ <- 1..2 do
        assert %{"data" => %{"state" => "cancelled", "user_code" => nil}} =
                 conn |> delete("#{@base}/attempts/#{id}") |> json_response(200)
      end

      approve!(id, user)
      assert %{"data" => [], "count" => 0} = conn |> get(@base) |> json_response(200)
    end

    test "an attempt that completed, or ran out of time, is 409 with its state",
         %{conn: conn, user: user} do
      stub_sign_in()
      %{"data" => %{"id" => done}} = start!(conn, %{"name" => "Work"})
      approve!(done, user)

      assert %{"error" => "chatgpt_link_attempt_not_pending", "state" => "completed"} =
               conn |> delete("#{@base}/attempts/#{done}") |> json_response(409)

      %{"data" => %{"id" => late}} = start!(conn, %{"name" => "Personal"})
      past = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second)
      Repo.update_all(from(a in LinkAttempt, where: a.id == ^late), set: [expires_at: past])

      assert %{"data" => %{"state" => "expired", "user_code" => nil}} =
               conn |> get("#{@base}/attempts/#{late}") |> json_response(200)

      assert %{"error" => "chatgpt_link_attempt_not_pending", "state" => "expired"} =
               conn |> delete("#{@base}/attempts/#{late}") |> json_response(409)
    end
  end

  describe "a failed attempt" do
    test "says why, and names the subscription that already holds the account",
         %{conn: conn, user: user} do
      held = link!(user, "Work", "acct-work")
      stub_sign_in(access_token(), "acct-work")

      %{"data" => %{"id" => id}} = start!(conn, %{"name" => "Personal"})
      approve!(id, user)

      assert %{
               "data" => %{
                 "state" => "failed",
                 "user_code" => nil,
                 "result_grant_id" => nil,
                 "failure" => %{
                   "reason" => "account_already_linked",
                   "grant_id" => grant_id,
                   "grant" => "Work"
                 }
               }
             } = conn |> get("#{@base}/attempts/#{id}") |> json_response(200)

      assert grant_id == held.grant_id
      assert %{"count" => 1} = conn |> get(@base) |> json_response(200)
    end
  end

  describe "redaction" do
    test "no body on any route carries a token, a device id, a claim, the provider's account " <>
           "id or a fencing column",
         %{conn: conn, user: user} do
      access = access_token(3_600, %{"label" => "SECRET-bearer"})
      stub_sign_in(access, "acct-SECRET-upstream")

      started = post_json(conn, @base <> "/attempts", %{"name" => "Work"})
      %{"data" => %{"id" => id}} = json_response(started, 201)
      pending = get(conn, "#{@base}/attempts/#{id}")
      open = get(conn, @base <> "/attempts")
      approve!(id, user)
      completed = get(conn, "#{@base}/attempts/#{id}")
      listed = get(conn, @base)
      %{"data" => [%{"id" => grant_id}]} = json_response(listed, 200)
      renamed = patch_json(conn, "#{@base}/#{grant_id}", %{"name" => "Day job"})
      reconnect = post_json(conn, @base <> "/attempts", %{"grant_id" => grant_id})
      %{"data" => %{"id" => reconnect_id}} = json_response(reconnect, 201)
      cancelled = delete(conn, "#{@base}/attempts/#{reconnect_id}")
      disconnected = post_json(conn, "#{@base}/#{grant_id}/disconnect", %{})
      me = get(conn, "/api/auth/me")

      {:ok, grant} = ChatGPTAccounts.get_for_user(grant_id, user.id)

      bodies =
        for response <- [
              started,
              pending,
              open,
              completed,
              listed,
              renamed,
              reconnect,
              cancelled,
              disconnected,
              me
            ],
            do: response.resp_body

      for body <- bodies,
          secret <- [
            access,
            @refresh_token,
            @device_auth_id,
            @authorization_code,
            @verifier,
            "acct-SECRET-upstream",
            grant.generation,
            "device_auth",
            "ciphertext",
            "id_claims",
            "account_id",
            "generation",
            "lock_version",
            "chatgpt_user_id"
          ] do
        refute body =~ secret, "#{secret} in #{body}"
      end

      # The one secret a body may carry, and only while it is pending.
      assert started.resp_body =~ @user_code
      assert pending.resp_body =~ @user_code
      refute completed.resp_body =~ @user_code
      refute cancelled.resp_body =~ @user_code
    end
  end

  describe "with linking turned off" do
    test "a new link is 404 and everything else still works", %{conn: conn, user: user} do
      grant = link!(user, "Work", "acct-work")
      stub_sign_in(access_token(), "acct-work")
      %{"data" => %{"id" => open}} = start!(conn, %{"name" => "Personal"})
      assert_received :device_start

      chatgpt_subscriptions_flag(false)

      assert %{"error" => "chatgpt_subscriptions_not_enabled"} =
               conn |> post_json(@base <> "/attempts", %{"name" => "Side"}) |> json_response(404)

      refute_received :device_start

      assert %{"chatgpt_subscriptions_enabled" => false} =
               conn |> get("/api/auth/me") |> json_response(200)

      assert %{"linking_enabled" => false, "count" => 1} =
               conn |> get(@base) |> json_response(200)

      assert %{"data" => [_]} = conn |> get(@base <> "/attempts") |> json_response(200)
      assert conn |> get("#{@base}/attempts/#{open}") |> json_response(200)
      assert conn |> delete("#{@base}/attempts/#{open}") |> json_response(200)

      assert conn
             |> patch_json("#{@base}/#{grant.grant_id}", %{"name" => "Day job"})
             |> json_response(200)

      # A reconnect of what the account already holds is not a new link.
      assert %{"data" => %{"kind" => "reconnect", "id" => reconnect}} =
               start!(conn, %{"grant_id" => grant.grant_id})

      approve!(reconnect, user)

      assert %{"data" => %{"state" => "completed"}} =
               conn |> get("#{@base}/attempts/#{reconnect}") |> json_response(200)

      assert conn |> post_json("#{@base}/#{grant.grant_id}/disconnect", %{}) |> json_response(200)
      assert conn |> delete("#{@base}/#{grant.grant_id}") |> response(204)
    end

    test "/api/auth/me reports the gate when it is on", %{conn: conn} do
      assert %{"chatgpt_subscriptions_enabled" => true} =
               conn |> get("/api/auth/me") |> json_response(200)
    end

    test "with no broker, a reconnect is refused too and the kill switch still works",
         %{conn: conn, user: user} do
      grant = link!(user, "Work", "acct-work")
      disable_broker()
      stub_sign_in()

      for body <- [%{"name" => "Personal"}, %{"grant_id" => grant.grant_id}] do
        assert %{"error" => "chatgpt_subscriptions_not_enabled"} =
                 conn |> post_json(@base <> "/attempts", body) |> json_response(404)
      end

      refute_received :device_start
      assert %{"linking_enabled" => false} = conn |> get(@base) |> json_response(200)
      assert conn |> post_json("#{@base}/#{grant.grant_id}/disconnect", %{}) |> json_response(200)
    end
  end

  defp start_attempt(user, target) do
    ChatGPTAccounts.start_attempt_for_user(user.id, target, device_start: device_start(self()))
  end
end
