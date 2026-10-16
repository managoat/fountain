defmodule Fountain.OAuthConfigClientsTest do
  @moduledoc """
  The shapes `config :fountain, Fountain.OAuth, clients:` may take.
  Synchronous because it rewrites application config every other OAuth test
  reads.
  """
  use ExUnit.Case, async: false

  alias Fountain.OAuth

  setup do
    original = Application.get_env(:fountain, OAuth)
    on_exit(fn -> Application.put_env(:fountain, OAuth, original) end)
  end

  test "takes string-keyed (JSON) and keyword entries, name falling back to id" do
    Application.put_env(:fountain, OAuth,
      clients: [
        %{"id" => "json-app", "redirect_uris" => ["https://json.test:8443/cb"]},
        [id: :kw, name: "Keyword"]
      ]
    )

    assert [
             %{id: "managoat-account"},
             %{
               id: "json-app",
               name: "json-app",
               redirect_uris: ["https://json.test:8443/cb"],
               published: true
             },
             %{id: "kw", name: "Keyword", redirect_uris: []}
           ] = OAuth.config_clients()
  end

  test "the account app is always registered" do
    Application.put_env(:fountain, OAuth, clients: nil)
    assert [%{id: "managoat-account"}] = OAuth.config_clients()

    Application.delete_env(:fountain, OAuth)
    assert [%{id: "managoat-account"}] = OAuth.config_clients()
  end

  test "the account app uses its configured URL and cannot be shadowed" do
    original = Application.get_env(:fountain, :account_app_url)

    on_exit(fn ->
      if original,
        do: Application.put_env(:fountain, :account_app_url, original),
        else: Application.delete_env(:fountain, :account_app_url)
    end)

    Application.put_env(:fountain, :account_app_url, "https://account.example")

    Application.put_env(:fountain, OAuth,
      clients: [%{id: "managoat-account", redirect_uris: ["https://wrong.example/"]}]
    )

    assert [%{id: "managoat-account", redirect_uris: ["https://account.example/"]}] =
             OAuth.config_clients()

    assert OAuth.registered_origin?("https://account.example")

    assert Fountain.Apps.account_url("connections") ==
             "https://account.example/?" <>
               URI.encode_query(server: FountainWeb.Endpoint.url(), open: "connections")
  end
end
