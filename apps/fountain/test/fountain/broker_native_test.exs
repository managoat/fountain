defmodule Fountain.BrokerNativeTest do
  # The native backend of Fountain.Broker (#1340): prepare mints a session
  # row the Managoat.Broker store can look up, bindings and the catalog map
  # to rules, release deletes, the sweep expires, and the listener refuses a
  # token it does not know. Global app env, so async: false.
  use Fountain.DataCase, async: false

  import ExUnit.CaptureLog

  alias Fountain.Broker
  alias Fountain.Broker.Native
  alias Fountain.Broker.Native.Sessions
  alias Fountain.SecretBindings.Binding
  alias Managoat.Broker.Rule

  @keys [:broker_listen_port, :broker_proxy_url]

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

    user = insert_verified_user()
    conv = insert_conversation(user_id: user.id, agent: insert_agent(user_id: user.id))

    {:ok, user: user, conv: conv}
  end

  defp binding(key, host, auth_type, extra \\ %{}) do
    struct(
      %Binding{key: key, host: host, auth_type: auth_type, headers: %{}, enabled: true},
      extra
    )
  end

  describe "the switch" do
    # There is no per-tenant arm to assert on: the ADR 0019 §9 ratchet retired,
    # so the port is the whole switch and every tenant of a deployment that
    # has one is brokered.
    test "BROKER_LISTEN_PORT selects the native backend" do
      assert Broker.backend() == :native
      assert Broker.configured?()
    end

    test "with neither variable there is no backend and nothing answers" do
      Application.delete_env(:fountain, :broker_listen_port)
      assert Broker.backend() == nil
      refute Broker.configured?()
      assert {:error, {:broker, :unreachable, :not_configured}} = Broker.preflight()
      assert {:error, {:broker, :ca, :not_configured}} = Broker.ca_pem()
      assert {:error, {:broker, :session, :not_configured}} = Broker.prepare("c", %{})
      assert :ok = Broker.release("c")
    end

    test "without the port there is no backend at all" do
      Application.delete_env(:fountain, :broker_listen_port)
      refute Broker.backend()
      refute Broker.configured?()
    end
  end

  describe "the CA" do
    test "the seed is 32 bytes derived from the master key, and is not the master key" do
      seed = Native.ca_seed()
      assert byte_size(seed) == 32
      refute seed == Application.fetch_env!(:fountain, :master_secrets_key)
      assert seed == Native.ca_seed()
    end

    test "ca_pem is the derived root, the same anchor every time" do
      assert {:ok, pem} = Broker.ca_pem()
      assert [{:Certificate, der, :not_encrypted}] = :public_key.pem_decode(pem)
      cert = X509.Certificate.from_der!(der)

      assert X509.Certificate.subject(cert) |> X509.RDNSequence.to_string() =~
               "Managoat Broker CA"

      {:ok, again} = Broker.ca_pem()
      [{:Certificate, der2, :not_encrypted}] = :public_key.pem_decode(again)

      assert X509.Certificate.public_key(X509.Certificate.from_der!(der2)) ==
               X509.Certificate.public_key(cert)
    end
  end

  describe "prepare/4" do
    test "creates a session the store can look up, with the catalog pair for an unbound GitHub key",
         %{user: user, conv: conv} do
      assert {:ok, session} =
               Broker.prepare(conv.id, %{"GITHUB_TOKEN" => "ghp_real"}, %{}, user_id: user.id)

      assert session.vault == Broker.vault_name(conv.id)
      assert "fb_" <> _ = session.token
      assert DateTime.compare(session.expires_at, DateTime.utc_now()) == :gt

      assert {:ok, %Managoat.Broker.Session{} = found} = Sessions.lookup(session.token)
      assert found.unmatched_host_policy == :passthrough
      assert found.meta["conversation_id"] == conv.id
      assert found.meta["user_id"] == user.id
      assert found.expires_at == session.expires_at

      assert [
               %Rule{
                 name: "github-api",
                 pattern: "api.github.com",
                 scheme: :bearer,
                 credential: "ghp_real"
               },
               %Rule{
                 name: "github-api",
                 pattern: "api.github.com",
                 scheme: :substitute,
                 placeholder: "__github_token__",
                 credential: "ghp_real"
               },
               %Rule{
                 name: "github-git",
                 pattern: "github.com",
                 scheme: :basic,
                 credential: {"x-access-token", "ghp_real"}
               }
             ] = found.rules
    end

    test "resolves the tenant from the conversation when the caller has no user id", %{
      conv: conv
    } do
      assert {:ok, session} = Broker.prepare(conv.id, %{"GH_TOKEN" => "g"})
      assert {:ok, %{rules: [%Rule{credential: "g"} | _]}} = Sessions.lookup(session.token)

      assert {:error, {:broker, :session, :unknown_conversation}} =
               Broker.prepare(Ecto.UUID.generate(), %{"GH_TOKEN" => "g"})
    end

    test "every binding shape becomes a rule with the credential resolved", %{
      user: user,
      conv: conv
    } do
      brokered = %{
        "STRIPE_KEY" => "sk_live",
        "DISCORD_BOT_TOKEN" => "disc",
        "PD" => "pd_real",
        "HTTPBIN" => "hb",
        "CLAUDE_CODE_OAUTH_TOKEN" => "oat_real"
      }

      bindings = %{
        "STRIPE_KEY" => [binding("STRIPE_KEY", "api.stripe.com/v1/*", "bearer")],
        "DISCORD_BOT_TOKEN" => [
          binding("DISCORD_BOT_TOKEN", "discord.com/api/*", "api_key", %{
            header: "Authorization",
            prefix: "Bot "
          })
        ],
        "PD" => [
          binding("PD", "api.pagerduty.com", "custom", %{
            headers: %{"Authorization" => "Token token={{ PD }}"}
          })
        ],
        "HTTPBIN" => [binding("HTTPBIN", "httpbin.org", "basic", %{username: "alice"})],
        "CLAUDE_CODE_OAUTH_TOKEN" => [
          binding("CLAUDE_CODE_OAUTH_TOKEN", "api.anthropic.com", "substitute")
        ]
      }

      assert {:ok, session} = Broker.prepare(conv.id, brokered, bindings, user_id: user.id)
      {:ok, %{rules: rules}} = Sessions.lookup(session.token)

      by = fn name, scheme -> Enum.find(rules, &(&1.name == name and &1.scheme == scheme)) end

      # Sorted by key: the OAuth token's rule comes first.
      assert %Rule{scheme: :substitute, placeholder: "sk-ant-oat01-__claude_code_oauth_token__"} =
               hd(rules)

      assert %Rule{pattern: "api.stripe.com/v1/*", credential: "sk_live"} =
               by.("stripe-key-api-stripe-com-v1", :bearer)

      assert %Rule{placeholder: "__stripe_key__", credential: "sk_live"} =
               by.("stripe-key-api-stripe-com-v1", :substitute)

      assert %Rule{header: "Authorization", prefix: "Bot ", credential: "disc"} =
               by.("discord-bot-token-discord-com-api", :api_key)

      assert %Rule{template: %{"Authorization" => "Token token={{ PD }}"}, credential: ^brokered} =
               by.("pd-api-pagerduty-com", :custom)

      assert %Rule{credential: {"alice", "hb"}} = by.("httpbin-httpbin-org", :basic)

      # A bound key gets no catalog pair, and there is no GitHub key here.
      refute Enum.any?(rules, &(&1.name in ["github-api", "github-git"]))
    end

    test "a bound GitHub key keeps its own rule and gets no catalog pair", %{
      user: user,
      conv: conv
    } do
      bindings = %{"GITHUB_TOKEN" => [binding("GITHUB_TOKEN", "ghe.example.com", "bearer")]}

      {:ok, session} =
        Broker.prepare(conv.id, %{"GITHUB_TOKEN" => "gh"}, bindings, user_id: user.id)

      {:ok, %{rules: rules}} = Sessions.lookup(session.token)
      assert Enum.map(rules, & &1.pattern) == ["ghe.example.com", "ghe.example.com"]
    end

    test "a limited network is deny plus a passthrough per allowed host, minus the credentialed ones",
         %{user: user, conv: conv} do
      bindings = %{"K" => [binding("K", "api.example.com", "bearer")]}

      {:ok, session} =
        Broker.prepare(conv.id, %{"K" => "v"}, bindings,
          user_id: user.id,
          network:
            {:limited, ["registry.npmjs.org", " API.Example.com ", "", "registry.npmjs.org"]}
        )

      {:ok, %{unmatched_host_policy: :deny, rules: rules}} = Sessions.lookup(session.token)

      assert [
               %Rule{pattern: "api.example.com", scheme: :bearer},
               %Rule{pattern: "api.example.com", scheme: :substitute},
               %Rule{
                 name: "allow-registry-npmjs-org",
                 pattern: "registry.npmjs.org",
                 scheme: :passthrough
               }
             ] = rules
    end

    test "a second prepare mints a second token; the first stays valid until it expires", %{
      user: user,
      conv: conv
    } do
      {:ok, first} = Broker.prepare(conv.id, %{"GH_TOKEN" => "g"}, %{}, user_id: user.id)
      {:ok, second} = Broker.prepare(conv.id, %{"GH_TOKEN" => "g"}, %{}, user_id: user.id)
      refute first.token == second.token
      assert {:ok, _} = Sessions.lookup(first.token)
      assert {:ok, _} = Sessions.lookup(second.token)
    end
  end

  describe "refresh/4" do
    # #1736: a running process holds its token, so an edited secret has to
    # reach the rules behind that token, not a new token.
    test "rewrites the rules of every live session in place, tokens kept", %{
      user: user,
      conv: conv
    } do
      {:ok, first} =
        Broker.prepare(conv.id, %{"GITHUB_TOKEN" => "ghp_old"}, %{}, user_id: user.id)

      {:ok, second} =
        Broker.prepare(conv.id, %{"GITHUB_TOKEN" => "ghp_old"}, %{}, user_id: user.id)

      other = insert_conversation(user_id: user.id, agent: insert_agent(user_id: user.id))

      {:ok, theirs} =
        Broker.prepare(other.id, %{"GITHUB_TOKEN" => "ghp_other"}, %{}, user_id: user.id)

      assert {:ok, 2} =
               Broker.refresh(
                 conv.id,
                 %{"GITHUB_TOKEN" => "ghp_new", "K" => "v"},
                 %{"K" => [binding("K", "api.example.com", "bearer")]},
                 user_id: user.id
               )

      for session <- [first, second] do
        assert {:ok, %{rules: rules, meta: meta}} = Sessions.lookup(session.token)

        assert %Rule{name: "github-api", credential: "ghp_new"} =
                 Enum.find(rules, &(&1.name == "github-api"))

        assert %Rule{pattern: "api.example.com", credential: "v"} =
                 Enum.find(rules, &(&1.scheme == :bearer and &1.pattern == "api.example.com"))

        assert meta["credential_keys"]["k-api-example-com"] == ["K"]
      end

      # Another conversation's session is not this conversation's to rewrite.
      assert {:ok, %{rules: [%Rule{credential: "ghp_other"} | _]}} = Sessions.lookup(theirs.token)
    end

    test "an expired session is left alone, and no live session is zero", %{
      user: user,
      conv: conv
    } do
      {:ok, session} = Broker.prepare(conv.id, %{"GH_TOKEN" => "g"}, %{}, user_id: user.id)

      Fountain.Repo.update_all(Fountain.Broker.Native.Session,
        set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
      )

      assert {:ok, 0} = Broker.refresh(conv.id, %{"GH_TOKEN" => "h"}, %{}, user_id: user.id)
      assert :error = Sessions.lookup(session.token)
    end

    test "resolves the tenant from the conversation when the caller has no user id", %{
      conv: conv
    } do
      {:ok, session} = Broker.prepare(conv.id, %{"GH_TOKEN" => "g"})
      assert {:ok, 1} = Broker.refresh(conv.id, %{"GH_TOKEN" => "h"})
      assert {:ok, %{rules: [%Rule{credential: "h"} | _]}} = Sessions.lookup(session.token)

      assert {:error, {:broker, :session, :unknown_conversation}} =
               Broker.refresh(Ecto.UUID.generate(), %{"GH_TOKEN" => "h"})
    end
  end

  describe "the store" do
    test "an unknown token is :error", _ctx do
      assert :error = Sessions.lookup("fb_nope")
    end

    test "release deletes every session of the conversation, and only those", %{
      user: user,
      conv: conv
    } do
      other = insert_conversation(user_id: user.id, agent: insert_agent(user_id: user.id))
      {:ok, a} = Broker.prepare(conv.id, %{"GH_TOKEN" => "g"}, %{}, user_id: user.id)
      {:ok, b} = Broker.prepare(other.id, %{"GH_TOKEN" => "g"}, %{}, user_id: user.id)

      assert :ok = Broker.release(conv.id)
      assert :error = Sessions.lookup(a.token)
      assert {:ok, _} = Sessions.lookup(b.token)
    end

    test "session release preserves a replacement token, including on a repeated cleanup", %{
      user: user,
      conv: conv
    } do
      {:ok, old} = Broker.prepare(conv.id, %{"GH_TOKEN" => "old"}, %{}, user_id: user.id)
      {:ok, replacement} = Broker.prepare(conv.id, %{"GH_TOKEN" => "new"}, %{}, user_id: user.id)

      assert :ok = Broker.release_session(user.id, conv.id, old.token)
      assert :error = Sessions.lookup(old.token)
      assert {:ok, %{rules: [%Rule{credential: "new"} | _]}} = Sessions.lookup(replacement.token)

      assert :ok = Broker.release_session(user.id, conv.id, old.token)
      assert {:ok, _} = Sessions.lookup(replacement.token)
    end

    test "session release requires matching tenant, conversation and token", %{
      user: user,
      conv: conv
    } do
      other_user = insert_verified_user()
      other = insert_conversation(user_id: user.id, agent: insert_agent(user_id: user.id))
      {:ok, session} = Broker.prepare(conv.id, %{"GH_TOKEN" => "g"}, %{}, user_id: user.id)

      for {user_id, conversation_id, token} <- [
            {other_user.id, conv.id, session.token},
            {user.id, other.id, session.token},
            {user.id, conv.id, "fb_unknown"}
          ] do
        assert :ok = Broker.release_session(user_id, conversation_id, token)
        assert {:ok, _} = Sessions.lookup(session.token)
      end

      assert :ok = Broker.release_session(user.id, conv.id, session.token)
      assert :error = Sessions.lookup(session.token)
    end

    test "session release works after broker shutdown", %{
      user: user,
      conv: conv
    } do
      {:ok, first} = Broker.prepare(conv.id, %{"GH_TOKEN" => "g"}, %{}, user_id: user.id)
      {:ok, second} = Broker.prepare(conv.id, %{"GH_TOKEN" => "g"}, %{}, user_id: user.id)

      Application.delete_env(:fountain, :broker_listen_port)
      refute Broker.configured?()
      assert :ok = Broker.release_session(user.id, conv.id, first.token)
      assert :error = Sessions.lookup(first.token)
      assert {:ok, _} = Sessions.lookup(second.token)

      Application.delete_env(:fountain, :broker_listen_port)
      assert Broker.backend() == nil
      assert :ok = Broker.release_session(user.id, conv.id, second.token)
      assert :error = Sessions.lookup(second.token)
    end

    test "an expired session is refused, and the sweep deletes it", %{user: user, conv: conv} do
      {:ok, live} = Broker.prepare(conv.id, %{"GH_TOKEN" => "g"}, %{}, user_id: user.id)
      {:ok, stale} = Broker.prepare(conv.id, %{"GH_TOKEN" => "g"}, %{}, user_id: user.id)

      past = DateTime.add(DateTime.utc_now(), -1, :second)

      Repo.update_all(
        from(s in Fountain.Broker.Native.Session,
          where: s.token_hash == ^:crypto.hash(:sha256, stale.token)
        ),
        set: [expires_at: past]
      )

      assert :error = Sessions.lookup(stale.token)
      assert 1 = Sessions.sweep_expired()
      assert 0 = Sessions.sweep_expired()
      assert {:ok, _} = Sessions.lookup(live.token)

      # The reaper's native branch is the same sweep.
      Repo.update_all(
        from(s in Fountain.Broker.Native.Session,
          where: s.token_hash == ^:crypto.hash(:sha256, live.token)
        ),
        set: [expires_at: past]
      )

      assert %{sessions: 1, requests: 0} = Fountain.Workers.BrokerReaper.run()
    end

    test "a row whose ciphertext does not decrypt is :error, not a crash", %{
      user: user,
      conv: conv
    } do
      {:ok, session} = Broker.prepare(conv.id, %{"GH_TOKEN" => "g"}, %{}, user_id: user.id)

      Repo.update_all(Fountain.Broker.Native.Session,
        set: [rules_ciphertext: :crypto.strong_rand_bytes(64)]
      )

      log = capture_log(fn -> assert :error = Sessions.lookup(session.token) end)
      assert log =~ "unreadable"
    end
  end

  describe "the listener" do
    setup do
      Ecto.Adapters.SQL.Sandbox.mode(Fountain.Repo, {:shared, self()})
      :ok
    end

    test "preflight says so when nothing listens" do
      assert {:error, {:broker, :unreachable, :listener_down}} = Broker.preflight()
    end

    test "up on the configured port, it serves a token the store knows and refuses one it does not",
         %{user: user, conv: conv} do
      start_supervised!(Native.listener_spec())
      assert :ok = Broker.preflight()
      port = Managoat.Broker.port()

      # The listener signs with the root ca_pem/0 hands the sandbox: same
      # key (the PEM bytes differ per derivation, the anchor does not).
      {:ok, pem} = Broker.ca_pem()
      assert public_key(pem) == public_key(Managoat.Broker.ca_pem())

      {:ok, session} = Broker.prepare(conv.id, %{"GH_TOKEN" => "g"}, %{}, user_id: user.id)
      [{"HTTPS_PROXY", url} | _] = Broker.sandbox_env(session)
      %URI{userinfo: userinfo} = URI.parse(url)
      good = "Basic " <> Base.encode64(userinfo)
      bad = "Basic " <> Base.encode64("fb_nope:" <> session.vault)

      # The good token is accepted; the origin is then refused because it is
      # a loopback address, which is the SSRF guard doing its job.
      assert connect(port, good) =~ "HTTP/1.1 403"
      assert connect(port, bad) =~ "HTTP/1.1 407"
    end

    test "a plain request with no proxy credentials gets 407, which is what the probe reads" do
      # home-cloud's blackbox probe of this listener asserts exactly this
      # (#1170): a forward proxy has no /health and no 2xx to ask for, so
      # liveness is the 407 an unauthenticated origin-form GET gets. Reaching
      # it means the listener accepted the connection, parsed the request and
      # tried to resolve a session. If this ever answered 400 instead, the
      # production alert would report the broker permanently down.
      start_supervised!(Native.listener_spec())
      port = Managoat.Broker.port()

      {:ok, tcp} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 5_000)
      :ok = :gen_tcp.send(tcp, "GET / HTTP/1.1\r\nHost: fountain.svc:14322\r\n\r\n")
      {:ok, reply} = :gen_tcp.recv(tcp, 0, 5_000)
      :gen_tcp.close(tcp)

      assert reply =~ "HTTP/1.1 407"
    end

    defp public_key(pem) do
      [{:Certificate, der, :not_encrypted}] = :public_key.pem_decode(pem)
      der |> X509.Certificate.from_der!() |> X509.Certificate.public_key()
    end

    defp connect(port, auth) do
      {:ok, tcp} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 5_000)

      :ok =
        :gen_tcp.send(
          tcp,
          "CONNECT localhost:443 HTTP/1.1\r\nHost: localhost:443\r\nProxy-Authorization: #{auth}\r\n\r\n"
        )

      {:ok, reply} = :gen_tcp.recv(tcp, 0, 5_000)
      :gen_tcp.close(tcp)
      reply
    end
  end

  describe "the request log" do
    test "request_log/2 is an empty page for a conversation that sent nothing", %{conv: conv} do
      assert {:ok, %{events: [], next: nil}} = Broker.request_log(conv.id)
    end

    test "the handler stores a row the endpoint reads back, with the credential keys",
         %{user: user, conv: conv} do
      pid = start_supervised!(Fountain.Broker.Native.RequestLog)
      Ecto.Adapters.SQL.Sandbox.allow(Fountain.Repo, self(), pid)
      assert :ok = Native.attach_telemetry()

      {:ok, _} =
        Broker.prepare(
          conv.id,
          %{"GITHUB_TOKEN" => "ghp_real"},
          %{},
          user_id: user.id
        )

      :telemetry.execute([:managoat, :broker, :request], %{count: 1}, %{
        method: "GET",
        host: "api.github.com",
        path: "/user",
        outcome: :injected,
        rule: "github-api",
        meta: %{
          "conversation_id" => conv.id,
          "user_id" => user.id,
          "credential_keys" => %{"github-api" => ["GITHUB_TOKEN"]}
        }
      })

      assert :ok = Fountain.Broker.Native.RequestLog.flush(pid)

      assert {:ok, %{events: [event], next: nil}} = Broker.request_log(conv.id)
      assert event.method == "GET"
      assert event.host == "api.github.com"
      assert event.path == "/user"
      assert event.service == "github-api"

      # The names of the variables whose values were attached, never a value.
      assert event.credential_keys == ["GITHUB_TOKEN"]
      refute inspect(event) =~ "ghp_real"
    end

    test "a request with no conversation on its session stores nothing", %{conv: conv} do
      pid = start_supervised!(Fountain.Broker.Native.RequestLog)
      Ecto.Adapters.SQL.Sandbox.allow(Fountain.Repo, self(), pid)
      assert :ok = Native.attach_telemetry()

      :telemetry.execute([:managoat, :broker, :request], %{count: 1}, %{
        method: "GET",
        host: "example.com",
        path: "/",
        outcome: :passthrough,
        rule: nil,
        meta: %{}
      })

      assert :ok = Fountain.Broker.Native.RequestLog.flush(pid)
      assert {:ok, %{events: [], next: nil}} = Broker.request_log(conv.id)
    end

    test "prepare/4 puts the rule-to-key map on the session, so the log can name a credential",
         %{user: user, conv: conv} do
      {:ok, _} = Broker.prepare(conv.id, %{"GH_TOKEN" => "g"}, %{}, user_id: user.id)

      session = Fountain.Repo.one!(Fountain.Broker.Native.Session)

      assert session.meta["credential_keys"] == %{
               "github-api" => ["GH_TOKEN"],
               "github-git" => ["GH_TOKEN"]
             }
    end

    test "credential_keys/2 names a bound key under the rule name it will match" do
      binding = binding("STRIPE_KEY", "api.stripe.com", "bearer")

      assert Native.credential_keys(%{"STRIPE_KEY" => "sk"}, %{"STRIPE_KEY" => [binding]}) ==
               %{"stripe-key-api-stripe-com" => ["STRIPE_KEY"]}
    end

    test "the telemetry handler writes conversation, method, host, path and outcome, never a header" do
      assert :ok = Native.attach_telemetry()
      assert :ok = Native.attach_telemetry()

      # The suite logs at :warning; the request line is :info, on purpose.
      previous = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous) end)

      log =
        capture_log(fn ->
          :telemetry.execute([:managoat, :broker, :request], %{count: 1}, %{
            method: "GET",
            host: "api.github.com",
            path: "/user",
            outcome: :injected,
            rule: "github-api",
            meta: %{"conversation_id" => "conv-1", "user_id" => "u-1"},
            headers: [{"authorization", "Bearer secret"}]
          })

          :telemetry.execute([:managoat, :broker, :request], %{count: 1}, %{
            method: "POST",
            host: "example.com",
            path: "/x",
            outcome: :denied,
            rule: nil,
            meta: %{"conversation_id" => "conv-1"}
          })
        end)

      assert log =~ "broker: conv conv-1 GET api.github.com/user injected github-api"
      assert log =~ "broker: conv conv-1 POST example.com/x denied"
      refute log =~ "secret"
    end
  end

  # Row 0 of the parity tracker (#1501, managoat/managoat_broker#5): the
  # library's request event carries the URL path alone. Before 0.1.3 an
  # origin-form request inside a CONNECT tunnel was logged with its whole
  # target, so `GET /x?token=... HTTP/1.1` put the query into
  # `broker_requests.path` -- a `decisions/0013` "never record values"
  # violation through a column nobody thought of as sensitive, and a query
  # can hold a credential this proxy never brokered.
  #
  # #1501 asks for this to be confirmed against the release rather than read
  # out of a changelog, which is why it drives the real listener over a real
  # tunnel instead of executing the telemetry event by hand.
  describe "the request log never holds a query string" do
    setup do
      Ecto.Adapters.SQL.Sandbox.mode(Fountain.Repo, {:shared, self()})
      {:ok, rig: Fountain.BrokerProxyRig.start()}
    end

    test "a tunnelled request logs its path and drops the query", ctx do
      %{user: user, conv: conv, rig: rig} = ctx
      {:ok, session} = Broker.prepare(conv.id, %{}, %{}, user_id: user.id)

      echo =
        rig
        |> Fountain.BrokerProxyRig.tunnel(session)
        |> Fountain.BrokerProxyRig.request(
          "GET /user?access_token=squirrel_in_the_query HTTP/1.1\r\n" <>
            "Host: #{rig.origin_host}\r\nConnection: close\r\n\r\n"
        )

      # The origin still gets the target byte for byte: this drops the query
      # from the log, not from the request.
      assert echo["path"] == "/user"
      assert echo["query"] == "access_token=squirrel_in_the_query"

      assert [event] = Fountain.BrokerProxyRig.rows(rig, conv.id)
      assert event.path == "/user"
      refute inspect(event) =~ "squirrel_in_the_query"
    end

    test "so does an absolute-form plain request", ctx do
      %{user: user, conv: conv, rig: rig} = ctx
      port = Fountain.BrokerProxyRig.start_http_origin()
      {:ok, session} = Broker.prepare(conv.id, %{}, %{}, user_id: user.id)

      echo =
        Fountain.BrokerProxyRig.plain_request(
          rig,
          session,
          "http://localhost:#{port}/user?access_token=squirrel_in_the_query",
          "localhost:#{port}"
        )

      assert echo["query"] == "access_token=squirrel_in_the_query"

      assert [event] = Fountain.BrokerProxyRig.rows(rig, conv.id)
      assert event.path == "/user"
      refute inspect(event) =~ "squirrel_in_the_query"
    end
  end

  # Row 2 of the parity tracker: the proxy frames responses now
  # (managoat_broker 0.3.0), so its request event is terminal and can say how
  # a request ended. `broker_requests` has had `status`, `latency_ms` and
  # `error` nullable since the table was created, waiting for exactly this.
  describe "how a request ended" do
    setup %{user: user, conv: conv} do
      pid = start_supervised!(Fountain.Broker.Native.RequestLog)
      Ecto.Adapters.SQL.Sandbox.allow(Fountain.Repo, self(), pid)
      assert :ok = Native.attach_telemetry()
      {:ok, _} = Broker.prepare(conv.id, %{"GITHUB_TOKEN" => "ghp_real"}, %{}, user_id: user.id)
      {:ok, log: pid}
    end

    defp emit(measurements, meta, conv, user) do
      :telemetry.execute(
        [:managoat, :broker, :request],
        measurements,
        Map.merge(
          %{
            method: "GET",
            host: "api.github.com",
            path: "/user",
            outcome: :injected,
            rule: "github-api",
            scheme: :bearer,
            status: nil,
            error: nil,
            meta: %{
              "conversation_id" => conv.id,
              "user_id" => user.id,
              "credential_keys" => %{"github-api" => ["GITHUB_TOKEN"]}
            }
          },
          meta
        )
      )
    end

    test "the status, the total duration and the terminal error reach the row", ctx do
      %{user: user, conv: conv, log: log} = ctx

      emit(
        %{count: 1, duration: System.convert_time_unit(1_500, :millisecond, :native)},
        %{status: 200},
        conv,
        user
      )

      emit(%{count: 1, duration: 0}, %{status: 502, error: :credential_missing}, conv, user)

      assert :ok = Fountain.Broker.Native.RequestLog.flush(log)
      assert {:ok, %{events: [refused, ok]}} = Broker.request_log(conv.id)

      assert ok.status == 200
      assert ok.latency_ms == 1_500
      assert ok.error == nil

      # 0.6.2: a matched rule whose credential the host could not supply is a
      # 502 with a reason, where it used to raise and drop the connection.
      assert refused.status == 502
      assert refused.error == "credential_missing"
    end

    test "an event with no duration and no status stores neither", ctx do
      %{user: user, conv: conv, log: log} = ctx
      emit(%{count: 1}, %{}, conv, user)

      assert :ok = Fountain.Broker.Native.RequestLog.flush(log)
      assert {:ok, %{events: [event]}} = Broker.request_log(conv.id)
      assert event.status == nil
      assert event.latency_ms == nil
      assert event.error == nil
    end

    # managoat/managoat_broker#27, found building managoat/airlock. `outcome`
    # answers "did a rule apply", so a matched `:passthrough` rule -- how a
    # host is allowed under `limited` -- arrives as `:injected`, identical to
    # a `:bearer` rule. Reading the verdict off `outcome` alone would make an
    # allowed host's row claim a credential went to it.
    test "an allowed host is not recorded as a credentialed one", ctx do
      %{user: user, conv: conv, log: log} = ctx

      emit(
        %{count: 1, duration: 0},
        %{host: "pypi.org", rule: "allow-pypi-org", scheme: :passthrough, status: 200},
        conv,
        user
      )

      assert :ok = Fountain.Broker.Native.RequestLog.flush(log)
      assert {:ok, %{events: [event]}} = Broker.request_log(conv.id)

      # `service` promises "the binding that matched, and so which credential
      # was attached". No credential was attached, so it names nothing.
      assert event.service == nil
      assert event.credential_keys == []
      assert Fountain.Repo.one!(Fountain.Broker.Native.Request).outcome == "passthrough"
    end

    test "a credentialed rule still names its binding and its keys", ctx do
      %{user: user, conv: conv, log: log} = ctx
      emit(%{count: 1, duration: 0}, %{status: 200}, conv, user)

      assert :ok = Fountain.Broker.Native.RequestLog.flush(log)
      assert {:ok, %{events: [event]}} = Broker.request_log(conv.id)
      assert event.service == "github-api"
      assert event.credential_keys == ["GITHUB_TOKEN"]
      assert Fountain.Repo.one!(Fountain.Broker.Native.Request).outcome == "injected"
    end

    test "the log line carries the ending, and an allowed host does not read as injected", ctx do
      %{user: user, conv: conv} = ctx

      previous = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous) end)

      log =
        capture_log(fn ->
          emit(
            %{count: 1, duration: System.convert_time_unit(42, :millisecond, :native)},
            %{status: 200},
            conv,
            user
          )

          emit(
            %{count: 1, duration: 0},
            %{host: "pypi.org", rule: "allow-pypi-org", scheme: :passthrough, status: 200},
            conv,
            user
          )
        end)

      assert log =~ "injected github-api 200 42ms"
      assert log =~ "allowed allow-pypi-org 200"
      refute log =~ "injected allow-pypi-org"
    end
  end

  # Row 1: `:substitute` reaches the request target as well as header values
  # since managoat_broker 0.2.0, so a credential a client puts in a URL is
  # brokered. The tracker asks for the redaction half to be asserted here
  # rather than read out of the library's changelog.
  describe "a credential in the URL" do
    setup do
      Ecto.Adapters.SQL.Sandbox.mode(Fountain.Repo, {:shared, self()})
      {:ok, rig: Fountain.BrokerProxyRig.start()}
    end

    test "is substituted in the path and the query, and logged as the placeholder", ctx do
      %{user: user, conv: conv, rig: rig} = ctx
      placeholder = Broker.placeholder("TELEGRAM_TOKEN")

      {:ok, session} =
        Broker.prepare(
          conv.id,
          %{"TELEGRAM_TOKEN" => "8199:tg-secret-value"},
          %{"TELEGRAM_TOKEN" => [binding("TELEGRAM_TOKEN", rig.origin_host, "substitute")]},
          user_id: user.id
        )

      echo =
        rig
        |> Fountain.BrokerProxyRig.tunnel(session)
        |> Fountain.BrokerProxyRig.request(
          "GET /bot#{placeholder}/sendMessage?key=#{placeholder} HTTP/1.1\r\n" <>
            "Host: #{rig.origin_host}\r\nConnection: close\r\n\r\n"
        )

      # The bot-API shape Agent Vault shipped a preset for. A colon is legal
      # unencoded in a path segment and the credential goes in byte for byte,
      # so `8199:tg-secret-value` arrives as itself.
      assert echo["path"] == "/bot8199:tg-secret-value/sendMessage"
      assert echo["query"] == "key=8199:tg-secret-value"

      # Telemetry is derived from the target the client sent, before
      # substitution, so a placeholder in a path is logged as the placeholder
      # and a placeholder in a query is not logged at all.
      assert [event] = Fountain.BrokerProxyRig.rows(rig, conv.id)
      assert event.path == "/bot#{placeholder}/sendMessage"
      assert event.service == "telegram-token-localhost-#{rig.origin_port}"
      assert event.credential_keys == ["TELEGRAM_TOKEN"]
      assert event.status == 200
      refute inspect(event) =~ "tg-secret-value"
    end

    # managoat_broker 0.5.0 refuses a rule whose placeholder is too short,
    # has no boundary or holds no letter or digit, because substitution is a
    # literal find-and-replace and a placeholder like `id` would rewrite every
    # `id` in every matching path. Every placeholder Fountain mints is
    # `__<key>__`, which satisfies it -- this is the guard that says so if the
    # rule ever changes.
    test "every placeholder Fountain mints is one the proxy will accept" do
      keys =
        Broker.catalog_keys() ++
          Map.keys(Broker.inference_keys()) ++
          ~w(A X1 TELEGRAM_TOKEN some-lowercase-key)

      for key <- keys do
        placeholder = Broker.placeholder(key)

        assert Managoat.Broker.Injector.valid_placeholder?(placeholder),
               "#{key} mints #{placeholder}, which the proxy would refuse"
      end
    end
  end

  # Row 3: IPv6 upstreams (managoat_broker 0.4.0). Almost nothing to build
  # here, with one exception the tracker names: a literal in a rule pattern
  # has to be bracketed, and `networking_config.allowed_hosts` is where a
  # tenant would write a bare one.
  describe "an IPv6 allowed host" do
    test "is bracketed before it becomes a rule pattern" do
      network = {:limited, ["::1", "2001:DB8::1", "[fd00::1]:8443", "example.com"]}

      assert [one, two, three, four] = Native.rules_for(%{}, %{}, network)
      assert one.pattern == "[::1]"

      # Downcased on the way, which changes nothing: the library matches an
      # address pattern by value rather than by spelling.
      assert two.pattern == "[2001:db8::1]"

      # Already bracketed, and carrying a port, so it is left exactly alone.
      assert three.pattern == "[fd00::1]:8443"
      assert four.pattern == "example.com"
    end

    test "a bare literal and its bracketed twin are one rule, not two" do
      assert [rule] = Native.rules_for(%{}, %{}, {:limited, ["::1", "[::1]"]})
      assert rule.pattern == "[::1]"
    end

    test "pattern_for leaves a name, an IPv4 literal and a host:port alone" do
      for host <- ["example.com", "*.example.com", "127.0.0.1", "example.com:8443"] do
        assert Native.pattern_for(host) == host
      end
    end
  end

  test "the reaper leaves a live session alone", %{user: user, conv: conv} do
    {:ok, _} = Broker.prepare(conv.id, %{"GH_TOKEN" => "g"}, %{}, user_id: user.id)
    assert %{sessions: 0, requests: 0} = Fountain.Workers.BrokerReaper.run()
    assert Fountain.Repo.aggregate(Fountain.Broker.Native.Session, :count, :id) == 1
  end

  test "the reaper sweeps egress rows past the retention", %{user: user, conv: conv} do
    pid = start_supervised!(Fountain.Broker.Native.RequestLog)
    Ecto.Adapters.SQL.Sandbox.allow(Fountain.Repo, self(), pid)

    stale = DateTime.add(DateTime.utc_now(), -(Broker.log_retention_hours() + 1) * 3600, :second)

    for at <- [stale, DateTime.utc_now()] do
      Fountain.Broker.Native.RequestLog.record(
        %{
          conversation_id: conv.id,
          user_id: user.id,
          method: "GET",
          host: "api.github.com",
          path: "/user",
          outcome: "injected",
          service: "github-api",
          credential_keys: [],
          inserted_at: at
        },
        pid
      )
    end

    assert :ok = Fountain.Broker.Native.RequestLog.flush(pid)

    assert %{requests: 1} = Fountain.Workers.BrokerReaper.run()
    assert {:ok, %{events: [_one]}} = Broker.request_log(conv.id)
  end

  describe "emit_telemetry/0" do
    test "reports the listener, the live sessions and the CA's remaining life",
         %{user: user, conv: conv} do
      {:ok, _} = Broker.prepare(conv.id, %{"GH_TOKEN" => "g"}, %{}, user_id: user.id)

      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:fountain, :broker, :listener],
          [:fountain, :broker, :sessions],
          [:fountain, :broker, :ca]
        ])

      on_exit(fn -> :telemetry.detach(ref) end)

      assert :ok = Native.emit_telemetry()

      assert_received {[:fountain, :broker, :listener], ^ref, %{up: up}, _}
      assert up in [0, 1]
      assert_received {[:fountain, :broker, :sessions], ^ref, %{count: 1}, _}
      assert_received {[:fountain, :broker, :ca], ^ref, %{expires_in_seconds: left}, _}
      assert left > 0
    end

    # The page prints a date and the alert reads a countdown. Two copies of the
    # PEM-to-`DateTime` chain would let them disagree about the one date whose
    # passing stops every sandbox trusting the proxy, which is what a comment
    # in `Insights` claimed could not happen while it was a second copy.
    test "the gauge and the date /admin/broker prints come from one function" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:fountain, :broker, :ca]])
      on_exit(fn -> :telemetry.detach(ref) end)

      before = DateTime.utc_now()
      assert :ok = Native.emit_telemetry()
      assert_received {[:fountain, :broker, :ca], ^ref, %{expires_in_seconds: left}, _}

      assert %DateTime{} = not_after = Native.ca_expires_at()
      # The gauge is that date minus a `utc_now/0` taken a moment earlier.
      assert_in_delta left, DateTime.diff(not_after, before), 2
    end

    test "emits nothing when this deployment does not run the native backend" do
      Application.delete_env(:fountain, :broker_listen_port)

      ref = :telemetry_test.attach_event_handlers(self(), [[:fountain, :broker, :listener]])
      on_exit(fn -> :telemetry.detach(ref) end)

      assert :ok = Native.emit_telemetry()
      refute_received {[:fountain, :broker, :listener], ^ref, _, _}
    end
  end
end
