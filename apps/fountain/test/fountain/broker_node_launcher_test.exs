defmodule Fountain.BrokerNodeLauncherTest do
  use ExUnit.Case, async: true

  @launcher Path.expand("../../priv/broker/node-launch.sh", __DIR__)

  setup do
    root = Fountain.TmpDir.mkdir!("relay-node")
    sprite = Path.join(root, "sprite with spaces")
    nvm = Path.join(sprite, "languages/node/nvm")
    File.mkdir_p!(Path.join(nvm, "alias"))
    File.write!(Path.join(nvm, "nvm.sh"), "# fixture")
    shim = executable(Path.join(sprite, "bin/node"))
    binary = executable(Path.join(nvm, "versions/node/v24.18.0/bin/node"))
    File.write!(Path.join(nvm, "alias/default"), "24.18.0\n")
    launcher = File.read!(@launcher) |> String.replace("/.sprite", sprite)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, nvm: nvm, shim: shim, binary: binary, launcher: launcher}
  end

  test "exact defaults bypass the shim and preserve arguments with spaces", ctx do
    assert launch(ctx) == [ctx.binary, "argument with spaces", "$(not-a-command)"]
    File.write!(Path.join(ctx.nvm, "alias/default"), "v24.18.0\n")
    assert hd(launch(ctx)) == ctx.binary
  end

  test "changed defaults are resolved afresh, not cached", ctx do
    next = executable(Path.join(ctx.nvm, "versions/node/v26.1.2/bin/node"))
    File.write!(Path.join(ctx.nvm, "alias/default"), "26.1.2\n")
    assert hd(launch(ctx)) == next
  end

  test "aliases, missing and non-executable binaries use the original shim", ctx do
    for version <- ["lts/*", "node", "24", "v99.0.0", "../../other", ""] do
      File.write!(Path.join(ctx.nvm, "alias/default"), version)
      assert hd(launch(ctx)) == ctx.shim
    end

    File.write!(Path.join(ctx.nvm, "alias/default"), "24.18.0")
    File.chmod!(ctx.binary, 0o600)
    assert hd(launch(ctx)) == ctx.shim
    File.rm!(Path.join(ctx.nvm, "alias/default"))
    assert hd(launch(ctx)) == ctx.shim
  end

  test "ordinary and custom PATH Nodes take precedence over Sprite's default", ctx do
    custom = executable(Path.join(ctx.root, "custom/bin/node"))
    assert hd(launch(ctx, [{"PATH", Path.dirname(custom) <> ":/usr/bin:/bin"}])) == custom
  end

  test "honors NVM_DIR and matches the shim's stale-directory fallback", ctx do
    nvm = Path.join(ctx.root, "other nvm")
    File.mkdir_p!(Path.join(nvm, "alias"))
    File.write!(Path.join(nvm, "nvm.sh"), "# fixture")
    File.write!(Path.join(nvm, "alias/default"), "22.1.0")
    binary = executable(Path.join(nvm, "versions/node/v22.1.0/bin/node"))
    assert hd(launch(ctx, [{"NVM_DIR", nvm}])) == binary
    assert hd(launch(ctx, [{"NVM_DIR", "/missing-nvm"}])) == ctx.binary
    File.rm!(Path.join(ctx.nvm, "nvm.sh"))
    assert hd(launch(ctx)) == ctx.shim
  end

  defp executable(path) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "#!/bin/sh\nprintf '%s\\n' \"$0\" \"$@\"\n")
    File.chmod!(path, 0o700)
    path
  end

  defp launch(ctx, overrides \\ []) do
    env =
      Map.merge(
        %{"PATH" => Path.dirname(ctx.shim) <> ":/usr/bin:/bin", "NVM_DIR" => nil},
        Map.new(overrides)
      )

    command = ctx.launcher <> "\nexec \"$(relay_node)\" \"$@\""

    {output, status} =
      System.cmd("bash", ["-c", command, "relay", "argument with spaces", "$(not-a-command)"],
        env: Map.to_list(env),
        stderr_to_stdout: true
      )

    assert status == 0, output
    String.split(output, "\n", trim: true)
  end
end
