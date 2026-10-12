defmodule Fountain.SandboxProvidersTest do
  # Mutates global application env (Fountain's and the sandbox library's), so
  # it must not run alongside anything that reads sandbox configuration.
  use ExUnit.Case, async: false

  alias Fountain.SandboxProviders

  setup do
    previous = %{
      sprites: Application.get_env(:managoat_sandbox, Managoat.Sandbox.Sprites, []),
      e2b: Application.get_env(:managoat_sandbox, Managoat.Sandbox.E2B, []),
      runners_enabled: Application.get_env(:fountain, :runners_enabled)
    }

    on_exit(fn ->
      Application.put_env(:managoat_sandbox, Managoat.Sandbox.Sprites, previous.sprites)
      Application.put_env(:managoat_sandbox, Managoat.Sandbox.E2B, previous.e2b)
      restore(:runners_enabled, previous.runners_enabled)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:fountain, key)
  defp restore(key, value), do: Application.put_env(:fountain, key, value)

  defp put_credential(adapter, key, value) do
    current = Application.get_env(:managoat_sandbox, adapter, [])
    Application.put_env(:managoat_sandbox, adapter, Keyword.put(current, key, value))
  end

  test "the known vocabulary is closed and sprites is the default" do
    assert SandboxProviders.known_providers() == ~w(sprites e2b runner)
    assert SandboxProviders.default_provider() == :sprites
  end

  test "every known provider has an adapter registered" do
    for provider <- SandboxProviders.known_providers() do
      assert is_atom(Managoat.Sandbox.adapter_for(String.to_existing_atom(provider)))
    end

    assert Managoat.Sandbox.adapter_for(:runner) == Managoat.Runner.Adapter
  end

  test "a provider is enabled only when its credential is configured" do
    put_credential(Managoat.Sandbox.Sprites, :token, nil)
    refute SandboxProviders.enabled?(:sprites)
    assert SandboxProviders.enabled_providers() == []

    put_credential(Managoat.Sandbox.Sprites, :token, "tok")
    assert SandboxProviders.enabled?(:sprites)
    assert SandboxProviders.enabled_providers() == [:sprites]
  end

  test "the runner provider needs no credential — only the opt-out disables it" do
    Application.put_env(:fountain, :runners_enabled, true)
    assert SandboxProviders.enabled?(:runner)
    assert :runner in SandboxProviders.enabled_providers()

    Application.put_env(:fountain, :runners_enabled, false)
    refute SandboxProviders.enabled?(:runner)
  end

  test "an e2b credential enables the provider now that its adapter ships" do
    refute SandboxProviders.enabled?(:e2b)
    put_credential(Managoat.Sandbox.E2B, :api_key, "e2b_x")
    assert SandboxProviders.enabled?(:e2b)
  end

  test "daytona, removed in 2026-10, is not a provider even with a credential" do
    on_exit(fn -> Application.delete_env(:managoat_sandbox, Managoat.Sandbox.Daytona) end)
    put_credential(Managoat.Sandbox.Daytona, :api_key, "dtn_x")
    refute SandboxProviders.enabled?(:daytona)
    refute "daytona" in SandboxProviders.known_providers()
  end
end
