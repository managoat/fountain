defmodule FountainBuzz.Workers.HarnessSweepTest do
  @moduledoc """
  The restart sweep for hosted Buzz agents' harnesses (#1017).

  `async: false`: sets application env and starts real harnesses under the
  global Horde supervisor, the same reasons `BootSweepTest` gives.
  """

  use Fountain.DataCase, async: false
  import FountainBuzz.Factory

  alias FountainBuzz.{BootSweep, Manager}
  alias FountainBuzz.Workers.HarnessSweep, as: BuzzHarnessSweep

  setup do
    dir = Fountain.TmpDir.mkdir!("buzz-harness-sweep")
    fake = Path.join(dir, "buzz-acp")
    FountainBuzz.TestSupport.write_fake_acp!(fake)

    prev_path = Application.get_env(:fountain_buzz, :buzz_acp_path)
    prev_url = Application.get_env(:fountain_buzz, :buzz_acp_base_url)

    on_exit(fn ->
      restore(:buzz_acp_path, prev_path)
      restore(:buzz_acp_base_url, prev_url)
      FountainBuzz.TestSupport.stop_all_harnesses!()
      File.rm_rf(dir)
    end)

    Application.put_env(:fountain_buzz, :buzz_acp_path, fake)
    Application.put_env(:fountain_buzz, :buzz_acp_base_url, "https://fountain.test")

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:fountain_buzz, key)
  defp restore(key, val), do: Application.put_env(:fountain_buzz, key, val)

  test "starts an enabled identity's harness that is not running" do
    identity = insert_buzz_identity(%{"enabled" => true})
    refute Manager.running?(identity.id)

    assert %{started: 1} = BuzzHarnessSweep.run()
    assert Manager.running?(identity.id)
  end

  test "leaves a running harness alone" do
    identity = insert_buzz_identity(%{"enabled" => true})
    assert {:ok, pid} = Manager.start_harness(identity)

    assert %{started: 0} = BuzzHarnessSweep.run()
    assert Manager.whereis(identity.id) == pid
  end

  test "ignores a disabled identity" do
    identity = insert_buzz_identity(%{"enabled" => false})

    assert %{started: 0} = BuzzHarnessSweep.run()
    refute Manager.running?(identity.id)
  end

  test "is inert with no buzz-acp binary configured" do
    Application.delete_env(:fountain_buzz, :buzz_acp_path)
    refute BootSweep.enabled?()

    identity = insert_buzz_identity(%{"enabled" => true})

    # Nothing to start: the sweep must not query, log or act on an instance
    # that runs no harnesses at all.
    assert %{started: 0} = BuzzHarnessSweep.run()
    refute Manager.running?(identity.id)
  end
end
