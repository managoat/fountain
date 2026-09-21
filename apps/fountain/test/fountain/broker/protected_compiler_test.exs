defmodule Fountain.Broker.Native.ProtectedCompilerTest do
  use ExUnit.Case, async: true

  alias Fountain.Broker.Native.ProtectedCompiler
  alias Fountain.ChatGPTAccounts.{Grant, Reserved}
  alias Fountain.SecretBindings.Binding
  alias Managoat.Broker.{Injector, ProtectedCredential, ProtectedRule, Session}

  # The compiler takes no bearer (ADR 0060 stage 3): the session path never
  # holds one. This one exists for the library half of the contract, which is
  # handed a `ProtectedCredential` per request.
  @token "synthetic-managed-bearer"
  @identity "account-fixture"
  @path "/backend-api/codex/responses"

  # What `Sessions` assembles from the two halves: the ordinary rules, and the
  # policy for the account the fenced read of the grant row named.
  defp compile(brokered, bindings, network, identity \\ @identity) do
    with {:ok, compiled} <- ProtectedCompiler.compile(brokered, bindings, network),
         {:ok, policy} <- ProtectedCompiler.policy(identity) do
      {:ok, Map.put(compiled, :protected, policy)}
    end
  end

  defp binding(key, host, extra \\ %{}),
    do: struct(%Binding{key: key, host: host, auth_type: "bearer", enabled: true}, extra)

  defp request(extra \\ %{}),
    do:
      Map.merge(
        %{scheme: :https, host: "chatgpt.com", port: 443, method: "POST", target: @path},
        extra
      )

  defp session(compiled),
    do: struct(Session, Map.put(compiled, :authorization, :synthetic_test_authority))

  test "fixed policy contains identity, but no bearer or authority" do
    assert {:ok, compiled} = compile(%{}, %{}, :unrestricted)
    assert compiled.http_only
    assert compiled.unmatched_host_policy == :passthrough
    assert compiled.rules == []
    assert compiled.protected.identity == "account-fixture"
    refute Map.has_key?(compiled, :authorization)
    refute ProtectedRule.valid_session?(struct(Session, compiled))
    assert ProtectedRule.valid_session?(session(compiled))
    refute :erlang.term_to_binary(compiled) =~ @token
  end

  test "ordinary cross-key templates keep their inputs and never receive the managed grant" do
    secrets = %{"STRIPE_KEY" => "ordinary-stripe", "ACCOUNT" => "ordinary-account"}

    bindings = %{
      "STRIPE_KEY" => [
        binding("STRIPE_KEY", "api.stripe.com", %{
          auth_type: "custom",
          headers: %{"Authorization" => "Bearer {{ STRIPE_KEY }}", "X-Account" => "{{ ACCOUNT }}"}
        })
      ]
    }

    assert {:ok, compiled} = compile(secrets, bindings, :unrestricted)
    assert [%{scheme: :custom, credential: ^secrets}, %{scheme: :substitute}] = compiled.rules
    refute :erlang.term_to_binary(compiled) =~ @token
    assert Enum.all?(compiled.rules, &Injector.matches?(&1.pattern, "api.stripe.com", 443, "/v1"))

    assert {:ok, headers, "/v1", _rule} =
             Injector.inject([], "api.stripe.com", 443, "/v1", session(compiled))

    assert Map.new(headers) == %{
             "Authorization" => "Bearer ordinary-stripe",
             "X-Account" => "ordinary-account"
           }
  end

  test "reserved keys and aliases are refused independently of binding writes" do
    for secrets <- [
          %{Reserved.key() => "some-token"},
          %{"ALIAS" => Reserved.placeholder()},
          %{"ALIAS" => "Bearer " <> Reserved.placeholder(Ecto.UUID.generate())},
          %{"ALIAS" => %Grant{access_token: @token, source: %{account_id: @identity}}}
        ] do
      assert {:error, :managed_credential_conflict} =
               ProtectedCompiler.compile(secrets, %{}, :unrestricted)
    end

    for template <- [
          "{{ CODEX_CHATGPT_ACCESS_TOKEN }}",
          "{{CODEX_CHATGPT_ACCESS_TOKEN}}",
          Reserved.placeholder(),
          "Bearer " <> Reserved.placeholder(Ecto.UUID.generate())
        ] do
      bindings = %{
        "OTHER" => [
          binding("OTHER", "attacker.example", %{
            auth_type: "custom",
            headers: %{"X-Leak" => template}
          })
        ]
      }

      assert {:error, :managed_credential_conflict} =
               ProtectedCompiler.compile(%{"OTHER" => "ordinary"}, bindings, :unrestricted)
    end

    # A persisted managed binding is rejected even if no value currently
    # exists for its key; it cannot become an export rule on a later refresh.
    bindings = %{Reserved.key() => [binding(Reserved.key(), "attacker.example")]}

    assert {:error, :managed_credential_conflict} =
             ProtectedCompiler.compile(%{}, bindings, :unrestricted)
  end

  test "exact, wildcard and path-specific ordinary injection conflicts fail compilation" do
    for host <- [
          "chatgpt.com",
          "*.com",
          "chatgpt.com:443",
          "chatgpt.com/backend-api/*",
          "chatgpt.com" <> @path
        ] do
      bindings = %{"OTHER" => [binding("OTHER", host)]}

      assert {:error, :managed_destination_conflict} =
               ProtectedCompiler.compile(%{"OTHER" => "ordinary"}, bindings, :unrestricted)
    end
  end

  test "network patterns and nested invalid inputs cannot smuggle a managed value into output" do
    for value <- [Reserved.placeholder(), Reserved.placeholder(Ecto.UUID.generate())] do
      assert {:error, :managed_credential_conflict} =
               ProtectedCompiler.compile(%{}, %{}, {:limited, ["attacker.example/" <> value]})

      assert {:error, :managed_credential_conflict} =
               ProtectedCompiler.compile(%{"ALIAS" => {:nested, value}}, %{}, :unrestricted)
    end

    assert {:error, :invalid_managed_identity} = ProtectedCompiler.policy(Reserved.placeholder())

    assert {:error, :invalid_broker_configuration} =
             ProtectedCompiler.compile(%{"OTHER" => 123}, %{}, :unrestricted)
  end

  test "tenant network entries do not widen protected methods, scheme, port or route" do
    assert {:ok, compiled} =
             compile(%{}, %{}, {:limited, ["chatgpt.com", "*.com", "attacker.example"]})

    session = session(compiled)
    assert compiled.unmatched_host_policy == :deny
    assert {:error, :denied} = Injector.inject([], "unlisted.example", 443, "/", session)
    assert {:ok, _} = ProtectedRule.select(session, request())

    assert {:ok, _} =
             ProtectedRule.select(
               session,
               request(%{host: "CHATGPT.COM", target: @path <> "?fixture=1"})
             )

    for extra <- [
          %{scheme: :http},
          %{port: 8443},
          %{method: "GET"},
          %{method: "TRACE"},
          %{method: "CONNECT"},
          %{target: @path <> "/next"},
          %{target: @path <> "-export"},
          %{target: "/backend-api/models"},
          %{target: "/backend-api/codex/../export"},
          %{target: "/backend-api/codex/%72esponses"},
          %{target: "/backend-api//codex/responses"}
        ] do
      assert {:error, :protected_destination} = ProtectedRule.select(session, request(extra))
    end

    # A redirect away from the backend is a separate ordinary destination;
    # none of its rules carries the managed bearer.
    assert :ordinary = ProtectedRule.select(session, request(%{host: "attacker.example"}))
    refute :erlang.term_to_binary(compiled.rules) =~ @token
  end

  test "broker sets only the paired identity and bearer; client routing/identity headers cannot survive" do
    assert {:ok, compiled} = compile(%{}, %{}, :unrestricted)

    headers = [
      {"authorization", "Bearer client-value"},
      {"chatgpt-account-id", "other-account"},
      {"cookie", "client-cookie"},
      {"x-forwarded-host", "attacker.example"},
      {"x-rewrite-url", "/export"},
      {"x-arbitrary", "client-value"},
      {"content-type", "application/json"},
      {"content-length", "2"},
      {"accept", "text/event-stream"}
    ]

    assert {:ok, kept} =
             ProtectedRule.prepare(compiled.protected, session(compiled), request(), headers)

    credential = %ProtectedCredential{bearer: @token, identity: "account-fixture"}

    assert {:ok, outgoing, @path, _} =
             ProtectedRule.inject(compiled.protected, credential, kept, @path)

    assert Map.new(outgoing) == %{
             "authorization" => "Bearer " <> @token,
             "chatgpt-account-id" => "account-fixture",
             "host" => "chatgpt.com",
             "content-type" => "application/json",
             "content-length" => "2",
             "accept" => "text/event-stream"
           }

    assert {:error, :authorization_unavailable} =
             ProtectedRule.inject(
               compiled.protected,
               %{credential | identity: "other-account"},
               kept,
               @path
             )

    assert {:error, :unsafe_request} =
             ProtectedRule.prepare(compiled.protected, session(compiled), request(), [
               {"transfer-encoding", "chunked"}
             ])
  end

  test "malformed inputs produce fixed errors without credential diagnostics" do
    assert {:error, :invalid_broker_configuration} =
             ProtectedCompiler.compile(:not_a_map, %{}, :unrestricted)

    for identity <- ["account\r\nInjected: bad", "", nil, 123] do
      assert {:error, :invalid_managed_identity} = ProtectedCompiler.policy(identity)
    end

    assert {:error, :invalid_broker_configuration} =
             ProtectedCompiler.compile(
               %{"OTHER" => "ordinary"},
               %{"OTHER" => [%{}]},
               :unrestricted
             )
  end

  test "the policy is the fixed Codex backend route, whatever was compiled beside it" do
    assert {:ok, policy} = ProtectedCompiler.policy(@identity)
    assert policy.name == ProtectedCompiler.rule_name()
    assert {policy.host, policy.port} == {"chatgpt.com", 443}
    assert policy.paths == [@path]
    assert policy.methods == ["POST"]
    assert policy.identity_header == "chatgpt-account-id"
    refute "authorization" in policy.allowed_headers
    refute "cookie" in policy.allowed_headers
  end

  test "the captured two-turn ACP request contract survives protected preparation" do
    fixture =
      __DIR__
      |> Path.join("../../fixtures/codex_protected/capture.json")
      |> File.read!()
      |> Jason.decode!()

    assert fixture["versions"] == %{
             "adapter" => "@agentclientprotocol/codex-acp 1.10.0",
             "codex" => "codex-cli 0.153.4"
           }

    assert fixture["turns"] == ["end_turn", "end_turn"]
    assert length(fixture["requests"]) == 2
    assert {:ok, compiled} = compile(%{}, %{}, :unrestricted)

    for captured <- fixture["requests"] do
      assert captured["content_length_matches"]
      assert captured["synthetic_auth_matches"]
      assert captured["synthetic_identity_matches"]
      assert captured["content_encoding"] == "zstd"
      refute "transfer-encoding" in captured["header_names"]

      request = request(%{target: captured["target"], method: captured["method"]})
      assert {:ok, policy} = ProtectedRule.select(session(compiled), request)

      headers =
        captured["header_names"]
        |> Map.new(&{&1, "synthetic-" <> &1})
        |> Map.merge(%{
          "content-length" => "100",
          "content-encoding" => captured["content_encoding"],
          "content-type" => captured["content_type"],
          "accept" => captured["accept"]
        })

      assert {:ok, prepared} =
               ProtectedRule.prepare(policy, session(compiled), request, Map.to_list(headers))

      kept = Map.new(prepared)

      for name <- captured["header_names"] -- ~w(authorization chatgpt-account-id host) do
        assert kept[name] == headers[name], "captured client header was stripped: #{name}"
      end

      refute Map.has_key?(kept, "authorization")
      refute Map.has_key?(kept, "chatgpt-account-id")
      assert kept["host"] == "chatgpt.com"
    end
  end
end
