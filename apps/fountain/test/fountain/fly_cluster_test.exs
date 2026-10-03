defmodule Fountain.FlyClusterTest do
  @moduledoc """
  Clustering on Fly: `rel/env.sh.eex` names the node and picks the query, and
  `config/runtime.exs` turns the query into a libcluster topology.

  The env script is shell the release sources before every command, so these
  cases render it and source it in `sh` under a scrubbed environment, the way
  `bin/fountain_server` does, and read back what it exported. Off Fly it must
  export nothing: Kubernetes names its nodes in the manifest.
  """

  # Mutates process env for the runtime.exs case.
  use ExUnit.Case, async: false

  @repo_root Path.expand("../../../..", __DIR__)
  @env_sh Path.join(@repo_root, "rel/env.sh.eex")
  @runtime_exs Path.join(@repo_root, "config/runtime.exs")

  @fly %{"FLY_APP_NAME" => "fountain-ab12", "FLY_PRIVATE_IP" => "fdaa:0:1:a7b:2:3:4:2"}
  @cookie %{"RELEASE_COOKIE" => "a-cookie-of-the-operators-own"}
  @exported ~w(CLUSTER_DNS_QUERY RELEASE_DISTRIBUTION RELEASE_NODE ERL_AFLAGS)

  defp source_env_sh(env) do
    script =
      EEx.eval_file(@env_sh, assigns: [release: %{name: :fountain_server}])

    path = Fountain.TmpDir.path("env") <> ".sh"
    File.write!(path, script)
    on_exit(fn -> File.rm(path) end)

    # The bin script sets RELEASE_NAME before it sources env.sh.
    env = Map.put(env, "RELEASE_NAME", "fountain_server")
    assignments = Enum.map(env, fn {k, v} -> "#{k}=#{v}" end)
    print = Enum.map_join(@exported, "; ", &~s(printf '%s=%s\\n' #{&1} "${#{&1}-<unset>}"))

    {out, status} =
      System.cmd("env", ["-i"] ++ assignments ++ ["sh", "-c", ". #{path}; #{print}"],
        stderr_to_stdout: true
      )

    vars =
      for line <- String.split(out, "\n", trim: true),
          [k, v] <- [String.split(line, "=", parts: 2)],
          k in @exported,
          into: %{},
          do: {k, v}

    {status, vars, out}
  end

  defp unchanged?(vars), do: Enum.all?(@exported, &(vars[&1] == "<unset>"))

  test "off Fly it exports nothing, whatever else is set" do
    for env <- [
          %{},
          @cookie,
          # The Kubernetes shape: the manifest sets all of it, and the script
          # must neither add to it nor refuse it.
          %{"CLUSTER_DNS_QUERY" => "fountain-headless.fountain.svc.cluster.local"}
        ] do
      {status, vars, _} = source_env_sh(env)
      assert status == 0

      assert vars["CLUSTER_DNS_QUERY"] == (env["CLUSTER_DNS_QUERY"] || "<unset>")
      assert vars["RELEASE_NODE"] == "<unset>"
      assert vars["RELEASE_DISTRIBUTION"] == "<unset>"
      assert vars["ERL_AFLAGS"] == "<unset>"
    end
  end

  test "on Fly without a cookie it is one node, as before" do
    {0, vars, _} = source_env_sh(@fly)
    assert unchanged?(vars)
  end

  test "on Fly with a cookie it names the node after the 6PN address and polls <app>.internal" do
    {0, vars, _} = source_env_sh(Map.merge(@fly, @cookie))

    assert vars == %{
             "CLUSTER_DNS_QUERY" => "fountain-ab12.internal",
             "RELEASE_DISTRIBUTION" => "name",
             "RELEASE_NODE" => "fountain_server@fdaa:0:1:a7b:2:3:4:2",
             "ERL_AFLAGS" => "-proto_dist inet6_tcp"
           }
  end

  test "it keeps what the operator set, and adds inet6 once" do
    env =
      @fly
      |> Map.merge(@cookie)
      |> Map.merge(%{
        "CLUSTER_DNS_QUERY" => "top1.nearest.of.fountain-ab12.internal",
        "RELEASE_NODE" => "custom@fdaa::1",
        "ERL_AFLAGS" => "-kernel shell_history enabled"
      })

    {0, vars, _} = source_env_sh(env)
    assert vars["CLUSTER_DNS_QUERY"] == "top1.nearest.of.fountain-ab12.internal"
    assert vars["RELEASE_NODE"] == "custom@fdaa::1"
    assert vars["ERL_AFLAGS"] == "-kernel shell_history enabled -proto_dist inet6_tcp"

    {0, again, _} = source_env_sh(Map.put(env, "ERL_AFLAGS", vars["ERL_AFLAGS"]))
    assert again["ERL_AFLAGS"] == vars["ERL_AFLAGS"]
  end

  test "an empty CLUSTER_DNS_QUERY keeps the cookie and turns discovery off" do
    {0, vars, _} = source_env_sh(@fly |> Map.merge(@cookie) |> Map.put("CLUSTER_DNS_QUERY", ""))
    assert vars["CLUSTER_DNS_QUERY"] == ""
    assert vars["RELEASE_NODE"] == "<unset>"
    assert vars["ERL_AFLAGS"] == "<unset>"
  end

  test "discovery on Fly without a cookie of the operator's own refuses to start" do
    {status, _, out} = source_env_sh(Map.put(@fly, "CLUSTER_DNS_QUERY", "fountain-ab12.internal"))
    assert status == 1
    assert out =~ "RELEASE_COOKIE is not"
  end

  test "runtime.exs polls the query for nodes named after the release" do
    previous = System.get_env()

    on_exit(fn ->
      for k <- ~w(CLUSTER_DNS_QUERY RELEASE_NAME), not Map.has_key?(previous, k) do
        System.delete_env(k)
      end

      System.put_env(previous)
    end)

    System.put_env(%{
      "CLUSTER_DNS_QUERY" => "fountain-ab12.internal",
      "RELEASE_NAME" => "fountain_server"
    })

    topologies = Config.Reader.read!(@runtime_exs, env: :test)[:libcluster][:topologies]

    assert [fountain: [strategy: Cluster.Strategy.DNSPoll, config: config]] = topologies
    assert config[:query] == "fountain-ab12.internal"
    assert config[:node_basename] == "fountain_server"

    System.put_env("CLUSTER_DNS_QUERY", "")
    assert Config.Reader.read!(@runtime_exs, env: :test)[:libcluster][:topologies] == []
  end
end
