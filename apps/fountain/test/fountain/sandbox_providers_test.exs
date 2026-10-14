defmodule Fountain.SandboxProvidersTest do
  # Mutates global application env (Fountain's and the sandbox library's), so
  # it must not run alongside anything that reads sandbox configuration.
  use ExUnit.Case, async: false

  alias Fountain.SandboxProviders

  setup do
    previous = %{
      sprites: Application.get_env(:managoat_sandbox, Managoat.Sandbox.Sprites, []),
      e2b: Application.get_env(:managoat_sandbox, Managoat.Sandbox.E2B, [])
    }

    on_exit(fn ->
      Application.put_env(:managoat_sandbox, Managoat.Sandbox.Sprites, previous.sprites)
      Application.put_env(:managoat_sandbox, Managoat.Sandbox.E2B, previous.e2b)
    end)

    :ok
  end

  defp put_credential(adapter, key, value) do
    current = Application.get_env(:managoat_sandbox, adapter, [])
    Application.put_env(:managoat_sandbox, adapter, Keyword.put(current, key, value))
  end

  test "the known vocabulary is closed and sprites is the default" do
    assert SandboxProviders.known_providers() == ~w(sprites e2b)
    assert SandboxProviders.default_provider() == :sprites
  end

  test "every known provider has an adapter registered" do
    for provider <- SandboxProviders.known_providers() do
      assert is_atom(Managoat.Sandbox.adapter_for(String.to_existing_atom(provider)))
    end
  end

  test "a provider is enabled only when its credential is configured" do
    put_credential(Managoat.Sandbox.Sprites, :token, nil)
    refute SandboxProviders.enabled?(:sprites)
    assert SandboxProviders.enabled_providers() == []

    put_credential(Managoat.Sandbox.Sprites, :token, "tok")
    assert SandboxProviders.enabled?(:sprites)
    assert SandboxProviders.enabled_providers() == [:sprites]
  end

  test "an e2b credential enables the provider now that its adapter ships" do
    refute SandboxProviders.enabled?(:e2b)
    put_credential(Managoat.Sandbox.E2B, :api_key, "e2b_x")
    assert SandboxProviders.enabled?(:e2b)
  end
end
