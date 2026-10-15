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
             %{
               id: "json-app",
               name: "json-app",
               redirect_uris: ["https://json.test:8443/cb"],
               published: true
             },
             %{id: "kw", name: "Keyword", redirect_uris: []}
           ] = OAuth.config_clients()
  end

  test "no clients configured is none" do
    Application.put_env(:fountain, OAuth, clients: nil)
    assert OAuth.config_clients() == []

    Application.delete_env(:fountain, OAuth)
    assert OAuth.config_clients() == []
  end
end
