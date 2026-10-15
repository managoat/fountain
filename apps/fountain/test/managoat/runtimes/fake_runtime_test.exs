defmodule Managoat.Runtimes.Testing.FakeRuntimeTest do
  @moduledoc """
  The fakes are part of the package (decisions/0037: test support ships in
  the library), so their contract is pinned here rather than only by the
  host tests that use them.
  """
  use ExUnit.Case, async: false

  alias Managoat.Runtimes.Testing.{ConfigFailingRuntime, FailingRuntime, FakeRuntime}

  test "every fake implements the behaviour" do
    for mod <- [FakeRuntime, FailingRuntime, ConfigFailingRuntime] do
      Code.ensure_loaded!(mod)
      assert Managoat.Runtimes in (mod.module_info(:attributes)[:behaviour] || [])
      assert is_binary(mod.skills_root())
      assert is_binary(mod.skills_sh_agent())
    end
  end

  test "FakeRuntime reports each callback to the observer, not to self()" do
    FakeRuntime.observe(self())

    # The host runs the runtime from its own process; the report still lands
    # on the observer.
    spawn(fn ->
      FakeRuntime.write_config(:handle, nil)
      FakeRuntime.prepare_sandbox(:handle, nil, [])
      FakeRuntime.build_command(nil, "hi", :run, nil, [])
    end)

    assert_receive :write_config
    assert_receive :prepare_sandbox
    assert_receive {:build_command, "hi", :run, nil, []}
    assert FakeRuntime.default_env(nil, %{}) == [{"FAKE_RUNTIME", "1"}]
  end

  test "the failing fakes fail where they say they do" do
    assert {:error, :prepare_failed} = FailingRuntime.prepare_sandbox(:h, nil, [])
    assert :ok = FailingRuntime.write_config(:h, nil)

    assert {:error, {:runtime_config, _path, :timeout}} =
             ConfigFailingRuntime.write_config(:h, nil)

    assert :ok = ConfigFailingRuntime.prepare_sandbox(:h, nil, [])
  end
end
