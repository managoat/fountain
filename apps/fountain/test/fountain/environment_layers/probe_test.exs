defmodule Fountain.EnvironmentLayers.ProbeTest do
  use Fountain.DataCase, async: true
  use Mimic
  alias Fountain.EnvironmentLayers.{Helper, Probe}
  alias Fountain.Broker.TransportRelay
  alias Fountain.Conversations.Provisioning
  alias Managoat.Sandbox

  setup do
    stub(Sandbox, :apply_network_policy, fn _, _ -> :ok end)
    stub(Helper, :install, fn _, "amd64" -> :ok end)

    stub(Helper, :call, fn _, %{operation: "snapshot"} ->
      {:ok, %{"result" => %{"base" => "sha256:" <> String.duplicate("b", 64)}}}
    end)

    stub(Provisioning, :install_broker_ca, fn _, nil -> :ok end)
    stub(TransportRelay, :ensure, fn _, _ -> :ok end)
    stub(TransportRelay, :stop, fn _ -> :ok end)
    :ok
  end

  for {name, fields, requested, remote_name} <- [
        {"configured ref instead of an unrelated branch key",
         %{"ref" => "v1", "branch" => "main"}, "v1", "refs/tags/v1^{}"},
        {"default branch when ref is omitted", %{}, "HEAD", "HEAD"},
        {"default branch when ref is empty", %{"ref" => ""}, "HEAD", "HEAD"}
      ] do
    test "probes the same repository selection as cold cloning: #{name}" do
      user = insert_verified_user()

      repo =
        Map.merge(
          %{"url" => "https://github.com/example/repo.git", "mount_path" => "/workspace/repo"},
          unquote(Macro.escape(fields))
        )

      env = insert_env(user_id: user.id, repositories: [repo], cache_enabled: true)
      handle = %Managoat.Sandbox.Handle{provider: :sprites, name: "probe-test"}
      revision = String.duplicate("a", 40)
      requested = unquote(requested)
      remote_name = unquote(remote_name)

      expect(Sandbox, :exec, fn ^handle, "uname", ["-m"], _ -> {:ok, "x86_64\n", 0} end)

      expect(Sandbox, :exec, fn ^handle, "git", args, _ ->
        assert args == [
                 "ls-remote",
                 "--exit-code",
                 "--",
                 repo["url"],
                 requested,
                 "refs/heads/" <> requested,
                 "refs/tags/" <> requested,
                 "refs/tags/" <> requested <> "^{}"
               ]

        {:ok, revision <> "\t" <> remote_name <> "\n", 0}
      end)

      assert {:ok, %{"revisions" => [^revision]}} = Probe.run(handle, env)
    end
  end

  test "resolves HEAD, branch precedence and annotated tag peeling" do
    a = String.duplicate("a", 40)
    b = String.duplicate("b", 40)
    assert {:ok, ^a} = Probe.parse_revision(a <> "\tHEAD\n", "HEAD")

    assert {:ok, ^a} =
             Probe.parse_revision(b <> "\trefs/tags/main\n" <> a <> "\trefs/heads/main\n", "main")

    assert {:ok, ^b} =
             Probe.parse_revision(a <> "\trefs/tags/v1\n" <> b <> "\trefs/tags/v1^{}\n", "v1")

    assert {:error, :revision_unavailable} = Probe.parse_revision("not-a-sha\tHEAD\n", "HEAD")

    assert {:error, :revision_unavailable} =
             Probe.parse_revision(a <> "\trefs/heads/other\n", "main")
  end
end
