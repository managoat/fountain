defmodule Fountain.Broker.Native.ManagedGrantProxyTest do
  # The protected broker path for a managed ChatGPT grant, through the real
  # listener, a real CONNECT tunnel and a real TLS origin (ADR 0052 decisions
  # 5 and 6 and its adversarial cases; ADR 0060 stage 3). What the unit tests
  # beside this one assert about `Sessions.authorize/2`, this asserts about
  # bytes: which bearer and which account id the origin actually received.
  #
  # The origin reports the bearer by digest and never repeats it: since
  # managoat_broker 0.15.0 a protected response that does is refused, which
  # the last describe block asserts through Fountain's own store and policy.
  #
  # The origin stands in for the Codex backend: `:codex_chatgpt_backend` is
  # pointed at it, which only the test suite does. Every adversarial case runs
  # for the deployment's grant and for a user's. Global app env and the one
  # platform row, so async: false.
  use Fountain.DataCase, async: false

  import ExUnit.CaptureLog
  import Fountain.ChatGPTFixtures

  alias Fountain.Broker
  alias Fountain.Broker.Native.Session
  alias Fountain.BrokerProxyRig, as: Rig
  alias Fountain.ChatGPTAccounts
  alias Fountain.PlatformChatGPT.Account

  @keys [:broker_listen_port, :broker_proxy_url, :codex_chatgpt_backend]
  @route "/backend-api/codex/responses"

  setup do
    previous = for key <- @keys, do: {key, Application.get_env(:fountain, key)}

    on_exit(fn ->
      for {key, value} <- previous do
        if is_nil(value),
          do: Application.delete_env(:fountain, key),
          else: Application.put_env(:fountain, key, value)
      end
    end)

    Application.put_env(:fountain, :broker_listen_port, 0)
    Application.put_env(:fountain, :broker_proxy_url, "http://broker.test:14322")
    Ecto.Adapters.SQL.Sandbox.mode(Fountain.Repo, {:shared, self()})

    rig = Rig.start()
    Application.put_env(:fountain, :codex_chatgpt_backend, {"localhost", rig.origin_port})

    user = insert_verified_user()
    {:ok, user: user, rig: rig}
  end

  defp conversation(user),
    do: insert_conversation(user_id: user.id, agent: insert_agent(user_id: user.id))

  defp grant(:platform, _user, tag) do
    access = access_token(3_600, %{"grant" => tag})
    {connect!(%{access_token: access}), access}
  end

  defp grant(:user, user, tag) do
    access = access_token(3_600, %{"grant" => tag})
    {user_grant!(user.id, %{access_token: access}), access}
  end

  defp ref(%Account{user_id: nil} = a),
    do: %{owner: :platform, grant_id: a.id, generation: a.generation}

  defp ref(%Account{user_id: user_id} = a),
    do: %{owner: {:user, user_id}, grant_id: a.id, generation: a.generation}

  defp session!(conv, user, account, brokered \\ %{}, bindings \\ %{}) do
    {:ok, session} =
      Broker.prepare(conv.id, brokered, bindings, user_id: user.id, managed: ref(account))

    session
  end

  defp end_generation(%Account{user_id: nil}), do: ChatGPTAccounts.platform_disconnect()

  defp end_generation(%Account{id: id, user_id: user_id}),
    do: ChatGPTAccounts.disconnect_for_user(id, user_id)

  # The request codex sends, as a raw sandbox client may forge it: its own
  # idea of the bearer and of the account, and things no client may set.
  # `:rig` steers the origin from the body, the one place a protected request
  # can: the route refuses a query.
  defp codex_request(rig, opts \\ []) do
    body =
      case Keyword.get(opts, :rig) do
        nil -> ~s({"model":"gpt-5.5-codex"})
        directives -> Jason.encode!(%{"model" => "gpt-5.5-codex", "rig" => directives})
      end

    target = @route <> Keyword.get(opts, :query, "")

    headers =
      [
        {"Host", rig.origin_host},
        {"Authorization", "Bearer " <> Keyword.get(opts, :bearer, "__placeholder__")},
        {"chatgpt-account-id", Keyword.get(opts, :account, "acct-the-client-claims")},
        {"Cookie", "session=client"},
        {"Content-Type", "application/json"},
        {"Accept", "text/event-stream"},
        {"Content-Length", Integer.to_string(byte_size(body))}
      ] ++ Keyword.get(opts, :headers, [])

    "POST #{target} HTTP/1.1\r\n" <>
      Enum.map_join(headers, &"#{elem(&1, 0)}: #{elem(&1, 1)}\r\n") <> "\r\n" <> body
  end

  defp report(%{status: 200, body: body}), do: Jason.decode!(body)

  # Which bearer the origin says it was sent, against the one expected.
  defp bearer?(seen, token),
    do: seen["headers"]["authorization_sha256"] == Rig.digest("Bearer " <> token)

  defp flush_hits do
    receive do
      {:origin_hit, _, _, _} -> flush_hits()
    after
      0 -> :ok
    end
  end

  for owner <- [:platform, :user] do
    describe "#{owner} grant" do
      @describetag owner: owner

      test "the origin gets the grant's bearer and account, and nothing the client claimed",
           %{owner: owner, user: user, rig: rig} do
        {account, access} = grant(owner, user, "one")
        conv = conversation(user)
        tls = Rig.tunnel(rig, session!(conv, user, account))

        seen = tls |> Rig.exchange(codex_request(rig)) |> report()

        assert seen["path"] == @route
        assert bearer?(seen, access)
        refute bearer?(seen, "__placeholder__")
        assert seen["headers"]["chatgpt-account-id"] == account.account_id
        assert seen["headers"]["content-type"] == "application/json"
        refute Map.has_key?(seen["headers"], "cookie")
        assert seen["body"] == ~s({"model":"gpt-5.5-codex"})

        # The egress log names the credential by its reserved name, never by value.
        assert [event] = Rig.rows(rig, conv.id)
        assert event.service == "codex-chatgpt"
        assert event.credential_keys == ["CODEX_CHATGPT_ACCESS_TOKEN"]
        assert event.status == 200
        refute inspect(event) =~ access
      end

      test "a streamed response passes", %{owner: owner, user: user, rig: rig} do
        {account, access} = grant(owner, user, "stream")
        tls = Rig.tunnel(rig, session!(conversation(user), user, account))

        response = Rig.exchange(tls, codex_request(rig, rig: %{stream: 1}))
        assert response.headers["transfer-encoding"] == "chunked"
        assert response |> report() |> bearer?(access)
      end

      # 0052: open a CONNECT tunnel before disconnect, then send another
      # request inside it after the fence. Nothing here tells the broker: no
      # notification exists to be missed, and the durable generation denies.
      test "a request inside a tunnel opened before the disconnect is refused after it",
           %{owner: owner, user: user, rig: rig} do
        {account, _access} = grant(owner, user, "fenced")
        conv = conversation(user)
        tls = Rig.tunnel(rig, session!(conv, user, account))
        assert %{status: 200} = Rig.exchange(tls, codex_request(rig))

        :ok = end_generation(account)
        Repo.update_all(Session, set: [managed_revoked_at: nil])
        flush_hits()

        assert %{status: 403} = Rig.exchange(tls, codex_request(rig))
        refute_receive {:origin_hit, _, _, _}, 100

        assert [denied, _ok] = Rig.rows(rig, conv.id, 2)
        assert denied.status == 403
        assert denied.error == "authorization_denied"
        assert denied.credential_keys == []
      end

      test "an authorization store that cannot answer refuses; it never serves a cached success",
           %{owner: owner, user: user, rig: rig} do
        {account, _access} = grant(owner, user, "unavailable")
        tls = Rig.tunnel(rig, session!(conversation(user), user, account))
        assert %{status: 200} = Rig.exchange(tls, codex_request(rig))
        flush_hits()

        # The proxy's own processes lose their way to the database.
        test = self()
        Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)

        try do
          assert %{status: 503} = Rig.exchange(tls, codex_request(rig))
          refute_receive {:origin_hit, _, _, _}, 100
        after
          Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, test})
        end
      end

      # The documented in-flight semantics: admission is the read, and a
      # request admitted before the fence may finish.
      test "a request admitted before the disconnect completes",
           %{owner: owner, user: user, rig: rig} do
        {account, access} = grant(owner, user, "in-flight")
        tls = Rig.tunnel(rig, session!(conversation(user), user, account))

        slow = Task.async(fn -> Rig.exchange(tls, codex_request(rig, rig: %{delay: 400})) end)
        assert_receive {:origin_hit, "POST", @route, _}, 5_000
        :ok = end_generation(account)

        assert slow |> Task.await(5_000) |> report() |> bearer?(access)
      end

      test "a protocol upgrade is refused before the origin sees it, on any host of the session",
           %{owner: owner, user: user, rig: rig} do
        {account, _access} = grant(owner, user, "upgrade")
        conv = conversation(user)
        session = session!(conv, user, account)

        upgrade = [{"Connection", "Upgrade"}, {"Upgrade", "websocket"}]

        assert %{status: 403} =
                 rig |> Rig.tunnel(session) |> Rig.exchange(codex_request(rig, headers: upgrade))

        # The session is HTTP only, not merely its protected route.
        elsewhere = "127.0.0.1:#{rig.origin_port}"

        assert %{status: 403} =
                 rig
                 |> Rig.tunnel(session, elsewhere)
                 |> Rig.exchange(
                   "GET /socket HTTP/1.1\r\nHost: #{elsewhere}\r\n" <>
                     "Connection: Upgrade\r\nUpgrade: websocket\r\n\r\n"
                 )

        # A tunnel inside the tunnel is the same thing by another name.
        assert %{status: 403} =
                 rig
                 |> Rig.tunnel(session)
                 |> Rig.exchange(
                   "CONNECT #{rig.origin_host} HTTP/1.1\r\nHost: #{rig.origin_host}\r\n\r\n"
                 )

        refute_receive {:origin_hit, _, _, _}, 100
        assert Enum.all?(Rig.rows(rig, conv.id, 3), &(&1.error == "protocol_upgrade"))
      end

      test "only the one route and method reach the backend with the bearer",
           %{owner: owner, user: user, rig: rig} do
        {account, _access} = grant(owner, user, "routes")
        session = session!(conversation(user), user, account)

        for raw <- [
              "GET #{@route} HTTP/1.1\r\nHost: #{rig.origin_host}\r\n\r\n",
              "GET /backend-api/me HTTP/1.1\r\nHost: #{rig.origin_host}\r\n\r\n",
              String.replace(codex_request(rig), @route, @route <> "/../export")
            ] do
          assert %{status: 403} = rig |> Rig.tunnel(session) |> Rig.exchange(raw)
        end

        refute_receive {:origin_hit, _, _, _}, 100
      end

      # A redirect away from the backend, or any other host the agent dials,
      # is an ordinary destination: the session's ordinary rules apply to it
      # and the managed bearer does not exist there.
      test "another destination gets the session's ordinary rules and never the bearer",
           %{owner: owner, user: user, rig: rig} do
        {account, access} = grant(owner, user, "elsewhere")
        elsewhere = "127.0.0.1:#{rig.origin_port}"

        binding = %Fountain.SecretBindings.Binding{
          key: "STRIPE_KEY",
          host: elsewhere,
          auth_type: "bearer",
          headers: %{},
          enabled: true
        }

        session =
          session!(conversation(user), user, account, %{"STRIPE_KEY" => "sk_ordinary"}, %{
            "STRIPE_KEY" => [binding]
          })

        seen =
          rig
          |> Rig.tunnel(session, elsewhere)
          |> Rig.exchange("GET /v1/charges HTTP/1.1\r\nHost: #{elsewhere}\r\n\r\n")
          |> report()

        assert bearer?(seen, "sk_ordinary")
        refute Map.has_key?(seen["headers"], "chatgpt-account-id")
        refute inspect(seen) =~ access
      end
    end
  end

  describe "two grants of one user, concurrently" do
    # ADR 0060's acceptance test for the broker half: two of one user's
    # subscriptions, two conversations, two tunnels, interleaved.
    test "each tunnel carries its own pair, whatever the client claims", %{user: user, rig: rig} do
      {personal, personal_access} = grant(:user, user, "personal")
      {work, work_access} = grant(:user, user, "work")
      personal_session = session!(conversation(user), user, personal)
      work_session = session!(conversation(user), user, work)

      results =
        for {session, claimed} <- [{personal_session, work}, {work_session, personal}],
            _ <- 1..3 do
          Task.async(fn ->
            # Each client sends the *other* grant's placeholder and account id.
            forged =
              codex_request(rig,
                bearer: ChatGPTAccounts.Reserved.placeholder(claimed.id),
                account: claimed.account_id
              )

            {session.token, rig |> Rig.tunnel(session) |> Rig.exchange(forged) |> report()}
          end)
        end
        |> Task.await_many(10_000)

      assert length(results) == 6

      for {token, seen} <- results do
        {account, access} =
          if token == personal_session.token,
            do: {personal, personal_access},
            else: {work, work_access}

        assert bearer?(seen, access)
        assert seen["headers"]["chatgpt-account-id"] == account.account_id
      end
    end

    test "one grant's token rotates between requests; the other, and both sessions, do not move",
         %{user: user, rig: rig} do
      # Inside its refresh margin, so the renewal below has something to do.
      stale = access_token(60, %{"grant" => "personal"})
      personal = user_grant!(user.id, %{access_token: stale, refresh_token: "rt_personal"})
      {work, work_access} = grant(:user, user, "work")
      personal_conv = conversation(user)
      work_conv = conversation(user)
      personal_tls = Rig.tunnel(rig, session!(personal_conv, user, personal))
      work_tls = Rig.tunnel(rig, session!(work_conv, user, work))

      assert personal_tls |> Rig.exchange(codex_request(rig)) |> report() |> bearer?(stale)

      sessions_before = Repo.all(from s in Session, order_by: s.id)
      renewed = access_token(7_200, %{"grant" => "personal", "renewed" => true})

      stub_refresh(%{
        expect_refresh: "rt_personal",
        access_token: renewed,
        id_token: id_token(%{account_id: personal.account_id})
      })

      assert :ok = ChatGPTAccounts.refresh_for_user(personal.id, user.id, personal.generation)

      # The same tunnel, the same session row, the new bearer: rotation reaches
      # the proxy through the grant row, with no rule rewritten.
      assert personal_tls |> Rig.exchange(codex_request(rig)) |> report() |> bearer?(renewed)
      assert work_tls |> Rig.exchange(codex_request(rig)) |> report() |> bearer?(work_access)

      assert Repo.all(from s in Session, order_by: s.id) == sessions_before
      assert Repo.get!(Account, work.id) == work
      assert Repo.get!(Account, personal.id).generation == personal.generation
    end

    test "disconnecting one closes its tunnel's next request and leaves the other's open",
         %{user: user, rig: rig} do
      {personal, _} = grant(:user, user, "personal")
      {work, work_access} = grant(:user, user, "work")
      personal_tls = Rig.tunnel(rig, session!(conversation(user), user, personal))
      work_tls = Rig.tunnel(rig, session!(conversation(user), user, work))
      assert %{status: 200} = Rig.exchange(personal_tls, codex_request(rig))
      assert %{status: 200} = Rig.exchange(work_tls, codex_request(rig))

      :ok = ChatGPTAccounts.disconnect_for_user(personal.id, user.id)

      assert %{status: 403} = Rig.exchange(personal_tls, codex_request(rig))

      assert work_tls |> Rig.exchange(codex_request(rig)) |> report() |> bearer?(work_access)

      assert Repo.get!(Account, work.id) == work
    end
  end

  # managoat_broker 0.15.0's two gates (ADR 0060 "Stage 3 as built"; #2463,
  # #2464), through the session Fountain's store hands the listener and the
  # policy `ProtectedCompiler` writes. What the library recognises is its own
  # suite's business; that Fountain's route is under both gates is this one's.
  for owner <- [:platform, :user] do
    describe "#{owner} grant, the protected route's gates" do
      @describetag owner: owner

      test "a response that repeats the bearer is refused, and the sandbox gets a fixed 502",
           %{owner: owner, user: user, rig: rig} do
        {account, access} = grant(owner, user, "reflected")
        conv = conversation(user)
        tls = Rig.tunnel(rig, session!(conv, user, account))

        log =
          capture_log(fn ->
            received = Rig.drain(tls, codex_request(rig, rig: %{reflect: 1}))
            send(self(), {:received, received})
          end)

        assert_receive {:received, received}
        assert received =~ ~r/\AHTTP\/1\.1 502 /
        refute received =~ access
        refute received =~ account.account_id

        # The origin did get the request: it is the answer that was refused.
        assert_receive {:origin_hit, "POST", @route, _}

        assert [event] = Rig.rows(rig, conv.id)
        assert event.status == 502
        assert event.error == "credential_reflected"
        assert event.service == "codex-chatgpt"
        refute inspect(event) =~ access

        # Said at `error`, by conversation and rule, and never by value.
        assert log =~ "[error] broker: the response to POST localhost under rule codex-chatgpt"
        assert log =~ conv.id
        refute log =~ access
      end

      test "a streamed response that repeats the bearer is cut before any of it arrives",
           %{owner: owner, user: user, rig: rig} do
        {account, access} = grant(owner, user, "reflected-stream")
        conv = conversation(user)
        tls = Rig.tunnel(rig, session!(conv, user, account))

        capture_log(fn ->
          send(
            self(),
            {:received, Rig.drain(tls, codex_request(rig, rig: %{reflect: 1, stream: 1}))}
          )
        end)

        # The head had gone, so there is no 502 to write and the close is the
        # answer. Nothing of the bearer went with what did arrive, not its
        # first bytes either: what could be its start is held back.
        assert_receive {:received, received}
        refute received =~ access
        refute received =~ binary_part(access, 0, 24)
        refute received =~ "\r\n0\r\n"

        assert [event] = Rig.rows(rig, conv.id)
        assert event.error == "credential_reflected"
      end

      test "a query on the route is refused before the grant is read or the origin dialled",
           %{owner: owner, user: user, rig: rig} do
        {account, access} = grant(owner, user, "query")
        conv = conversation(user)
        session = session!(conv, user, account)

        # `authorize` begins by reading the session row, on the proxy's own
        # process, and goes on to the grant's. Opening a tunnel reads the
        # session too, so all three are up before anything is counted.
        [pinned | refused] = for _ <- 1..3, do: Rig.tunnel(rig, session)
        test = self()
        handler = "managed-grant-proxy-#{System.unique_integer([:positive])}"

        :telemetry.attach(
          handler,
          [:fountain, :repo, :query],
          fn _event, _measurements, meta, _config -> send(test, {:repo_query, meta[:source]}) end,
          nil
        )

        on_exit(fn -> :telemetry.detach(handler) end)

        for {query, tls} <- Enum.zip(["?x=1", "?"], refused) do
          assert %{status: 403, body: body} = Rig.exchange(tls, codex_request(rig, query: query))
          refute body =~ access
        end

        refute_received {:repo_query, "broker_sessions"}
        refute_received {:repo_query, "platform_chatgpt_account"}
        refute_receive {:origin_hit, _, _, _}, 100

        assert [second, first] = Rig.rows(rig, conv.id, 2)

        for denied <- [first, second] do
          assert denied.status == 403
          assert denied.error == "protected_query"
          assert denied.credential_keys == []
        end

        # Refused, not fenced: the session still carries the pinned request,
        # and that one is authorized the way the two above were not.
        assert pinned |> Rig.exchange(codex_request(rig)) |> report() |> bearer?(access)
        assert_received {:repo_query, "broker_sessions"}
        assert_received {:repo_query, "platform_chatgpt_account"}
      end

      test "a compressed response is refused unread",
           %{owner: owner, user: user, rig: rig} do
        {account, _access} = grant(owner, user, "encoded")
        conv = conversation(user)
        tls = Rig.tunnel(rig, session!(conv, user, account))

        capture_log(fn ->
          encoded = [{"Accept-Encoding", "gzip"}]
          request = codex_request(rig, rig: %{encoding: "gzip"}, headers: encoded)
          send(self(), {:received, Rig.drain(tls, request)})
        end)

        assert_receive {:received, received}
        assert received =~ ~r/\AHTTP\/1\.1 502 /
        refute received =~ "content-encoding"

        # The client asked for gzip; the origin was asked for none.
        assert_receive {:origin_hit, "POST", @route, %{"accept-encoding" => "identity"}}

        assert [event] = Rig.rows(rig, conv.id)
        assert event.status == 502
        assert event.error == "protected_response_encoded"
      end
    end
  end
end
