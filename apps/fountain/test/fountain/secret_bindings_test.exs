defmodule Fountain.SecretBindingsTest do
  # Secret bindings (ADR 0019 gate 1b): the context, and the validation that
  # mirrors Agent Vault 0.39.1's `broker.Validate` so a binding that saves
  # here is one the broker accepts.
  use Fountain.DataCase, async: true

  alias Fountain.SecretBindings
  alias Fountain.SecretBindings.Catalog

  defp bind(user, attrs) do
    SecretBindings.create_binding(
      user.id,
      Map.merge(
        %{"key" => "STRIPE_SECRET_KEY", "host" => "api.stripe.com", "auth_type" => "bearer"},
        attrs
      )
    )
  end

  describe "create_binding/3" do
    test "a bearer binding, tenant-scoped, enabled by default" do
      user = insert_verified_user()
      other = insert_verified_user()

      assert {:ok, b} = bind(user, %{})
      assert b.enabled
      assert b.user_id == user.id
      assert [^b] = SecretBindings.list_bindings(user.id)
      assert SecretBindings.list_bindings(other.id) == []
      assert SecretBindings.get_binding(b.id, other.id) == nil
    end

    test "the tenant comes from the argument, never the attrs" do
      user = insert_verified_user()
      other = insert_verified_user()
      assert {:ok, b} = bind(user, %{"user_id" => other.id})
      assert b.user_id == user.id
    end

    test "several hosts per key; the same host twice is refused" do
      user = insert_verified_user()
      assert {:ok, _} = bind(user, %{"key" => "GITHUB_TOKEN", "host" => "api.github.com"})

      assert {:ok, _} =
               bind(user, %{
                 "key" => "GITHUB_TOKEN",
                 "host" => "github.com",
                 "auth_type" => "basic",
                 "username" => "x-access-token"
               })

      assert {:error, cs} = bind(user, %{"key" => "GITHUB_TOKEN", "host" => "api.github.com"})
      assert "this secret is already bound to that host" in errors_on(cs).host

      assert %{"GITHUB_TOKEN" => [_, _]} = SecretBindings.enabled_by_key(user.id)
    end

    test "the key must be UPPER_SNAKE_CASE" do
      user = insert_verified_user()
      assert {:error, cs} = bind(user, %{"key" => "stripe-key"})
      assert errors_on(cs).key != []
    end
  end

  describe "host rules (the broker's own)" do
    setup do
      {:ok, user: insert_verified_user()}
    end

    test "accepts a host, a one-level wildcard, a port, and a path glob", %{user: user} do
      for host <-
            ~w(api.stripe.com *.github.com api.example.com:8443 slack.com/api/* Api.Example.COM) do
        assert {:ok, b} = bind(user, %{"host" => host}), host
        assert b.host == String.downcase(host)
      end
    end

    test "rejects what the broker rejects", %{user: user} do
      for {host, fragment} <- [
            {"10.0.0.1", "IP address"},
            {"*", "bare wildcard"},
            {"*github.com", "*.example.com"},
            {"*.com", "two domain levels"},
            {"localhost", "internal"},
            {"kubernetes.default", "internal"},
            {"single-label", "domain"},
            {"bad host.com", "not allowed"},
            {"api.example.com:99999", "65535"},
            {"api.example.com/a/**", "**"},
            {"api.example.com/a b", "not allowed"}
          ] do
        assert {:error, cs} = bind(user, %{"host" => host}), host

        assert Enum.any?(errors_on(cs).host, &String.contains?(&1, fragment)),
               "#{host}: #{inspect(errors_on(cs).host)}"
      end
    end
  end

  describe "auth shapes" do
    setup do
      {:ok, user: insert_verified_user()}
    end

    test "basic needs a username; the other type's fields are cleared", %{user: user} do
      assert {:error, cs} = bind(user, %{"auth_type" => "basic"})
      assert "can't be blank" in errors_on(cs).username

      assert {:ok, b} =
               bind(user, %{
                 "auth_type" => "basic",
                 "username" => "x-access-token",
                 "header" => "stale"
               })

      assert b.username == "x-access-token"
      assert b.header == nil
    end

    test "api_key defaults the header and validates its name", %{user: user} do
      assert {:ok, b} = bind(user, %{"auth_type" => "api_key"})
      assert b.header == "Authorization"

      assert {:ok, b} =
               bind(user, %{
                 "auth_type" => "api_key",
                 "host" => "b.example.com",
                 "header" => "x-api-key",
                 "prefix" => "Token "
               })

      assert {b.header, b.prefix} == {"x-api-key", "Token "}

      assert {:error, cs} =
               bind(user, %{
                 "auth_type" => "api_key",
                 "host" => "c.example.com",
                 "header" => "x api"
               })

      assert errors_on(cs).header != []
    end

    test "custom needs headers whose templates reference UPPER_SNAKE keys", %{user: user} do
      assert {:error, cs} = bind(user, %{"auth_type" => "custom"})
      assert errors_on(cs).headers != []

      assert {:ok, b} =
               bind(user, %{
                 "auth_type" => "custom",
                 "headers" => %{"X-Api-Key" => "{{ STRIPE_SECRET_KEY }}", "X-Account" => "acct_1"}
               })

      assert b.headers["X-Api-Key"] == "{{ STRIPE_SECRET_KEY }}"

      assert {:error, cs} =
               bind(user, %{
                 "auth_type" => "custom",
                 "host" => "d.example.com",
                 "headers" => %{"X-Key" => "{{stripe}}"}
               })

      assert Enum.any?(errors_on(cs).headers, &String.contains?(&1, "UPPER_SNAKE_CASE"))

      assert {:error, cs} =
               bind(user, %{
                 "auth_type" => "custom",
                 "host" => "e.example.com",
                 "headers" => %{"bad header" => "x"}
               })

      assert Enum.any?(errors_on(cs).headers, &String.contains?(&1, "hyphens"))
    end

    test "substitute is the shape with no other field", %{user: user} do
      assert {:ok, b} =
               bind(user, %{
                 "auth_type" => "substitute",
                 "header" => "stale",
                 "username" => "stale"
               })

      assert {b.header, b.username, b.headers} == {nil, nil, %{}}
    end

    test "an unknown auth type is refused", %{user: user} do
      assert {:error, cs} = bind(user, %{"auth_type" => "passthrough"})
      assert errors_on(cs).auth_type != []
    end
  end

  describe "update and delete" do
    test "disabling drops a binding from enabled_by_key; deleting removes it", %{} do
      user = insert_verified_user()
      {:ok, b} = bind(user, %{})

      assert {:ok, b} = SecretBindings.update_binding(b, %{"enabled" => false})
      refute b.enabled
      assert SecretBindings.enabled_by_key(user.id) == %{}

      assert {:ok, _} = SecretBindings.delete_binding(b)
      assert SecretBindings.list_bindings(user.id) == []
    end

    test "every mutation leaves an audit event naming the host, never a value" do
      user = insert_verified_user()
      {:ok, b} = bind(user, %{})
      {:ok, b} = SecretBindings.update_binding(b, %{"host" => "api.stripe.com:443"})
      {:ok, _} = SecretBindings.delete_binding(b)

      events =
        user.id
        |> Fountain.Audit.list_recent_for_user(20)
        |> Enum.filter(&String.starts_with?(&1.action, "secret_binding."))

      actions = Enum.map(events, & &1.action)

      for a <- ~w(secret_binding.created secret_binding.updated secret_binding.deleted),
          do: assert(a in actions)

      assert Enum.all?(events, &(&1.metadata["key"] == "STRIPE_SECRET_KEY"))
    end
  end

  describe "known_keys/1" do
    test "the names of the account's secrets, from every environment and vault, never a value" do
      user = insert_verified_user()
      other = insert_verified_user()
      dek = <<1::256>>
      env = insert_env(user_id: user.id)
      vault = insert_vault(user_id: user.id)
      other_env = insert_env(user_id: other.id)

      {:ok, _} =
        Fountain.Environments.upsert_secret(
          env,
          %{"key" => "GITHUB_TOKEN", "value" => "ghp"},
          dek
        )

      {:ok, _} =
        Fountain.Vaults.upsert_secret(
          vault,
          %{"key" => "STRIPE_SECRET_KEY", "value" => "sk"},
          dek
        )

      {:ok, _} =
        Fountain.Vaults.upsert_secret(vault, %{"key" => "GITHUB_TOKEN", "value" => "ghp2"}, dek)

      {:ok, _} =
        Fountain.Environments.upsert_secret(other_env, %{"key" => "OTHERS", "value" => "x"}, dek)

      assert SecretBindings.known_keys(user.id) == ["GITHUB_TOKEN", "STRIPE_SECRET_KEY"]
    end
  end

  describe "the catalog" do
    test "carries the 35 presets, github first among them, three marked unusable" do
      presets = Catalog.presets()
      assert length(presets) == 35

      assert %{
               host: "api.github.com",
               auth_type: "bearer",
               suggested_key: "GITHUB_TOKEN",
               usable: true
             } = Catalog.get("github")

      assert Enum.map(Enum.reject(presets, & &1.usable), & &1.id) |> Enum.sort() ==
               ~w(aws-s3 jira twilio)

      assert [%{id: "stripe"}] = Catalog.for_key("STRIPE_SECRET_KEY")
      assert Enum.all?(presets, &(&1.auth_type in ~w(substitute bearer basic api_key custom)))
      assert %{auth_type: "substitute", usable: true} = Catalog.get("telegram")
    end
  end
end
