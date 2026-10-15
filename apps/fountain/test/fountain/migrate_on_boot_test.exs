defmodule Fountain.MigrateOnBootTest do
  @moduledoc """
  The switch that lets a deployment migrate somewhere other than at boot (#610).

  A release migrates on every replica before it serves, which is right for the
  single-replica shape the image ships as and wrong for the standard
  Kubernetes shape — migrations once in a Job, pods that only serve. Two paths
  migrate at boot (the image's CMD and the `Ecto.Migrator` child in
  `Fountain.Application`), so a switch that closed only one would read as
  working while every pod still migrated.
  """

  # Mutates process env and application env, so it must not run alongside
  # anything else.
  use ExUnit.Case, async: false

  @repo_root Path.expand("../../../..", __DIR__)
  @runtime_exs Path.join(@repo_root, "config/runtime.exs")

  # The minimum a :prod evaluation of runtime.exs demands (the same set
  # self_host_switches_test.exs uses).
  @required_release_env %{
    "PHX_SERVER" => "true",
    "SECRET_KEY_BASE" => String.duplicate("a", 64),
    "DATABASE_URL" => "postgres://u:p@localhost/db",
    "BROKER_LISTEN_PORT" => "14322",
    "BROKER_PROXY_URL" => "http://broker.example:14322",
    "SMTP_HOST" => "smtp.example.com",
    "EMAIL_FROM" => "noreply@fountain.example.com",
    "PUBLIC_URL" => "https://fountain.example.com"
  }

  defp read_prod_config(extra) do
    previous = System.get_env()

    try do
      System.delete_env("MIGRATE_ON_BOOT")

      @required_release_env
      |> Map.put(
        "MASTER_SECRETS_KEY",
        Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      )
      |> Map.merge(extra)
      |> System.put_env()

      Config.Reader.read!(@runtime_exs, env: :prod)[:fountain][:migrate_on_boot]
    after
      System.put_env(previous)
      unless Map.has_key?(previous, "MIGRATE_ON_BOOT"), do: System.delete_env("MIGRATE_ON_BOOT")
    end
  end

  defp with_switch(value, fun) do
    previous = Application.get_env(:fountain, :migrate_on_boot)
    Application.put_env(:fountain, :migrate_on_boot, value)

    try do
      fun.()
    after
      Application.put_env(:fountain, :migrate_on_boot, previous)
    end
  end

  defp with_release_name(name, fun) do
    previous = System.get_env("RELEASE_NAME")
    if name, do: System.put_env("RELEASE_NAME", name), else: System.delete_env("RELEASE_NAME")

    try do
      fun.()
    after
      if previous,
        do: System.put_env("RELEASE_NAME", previous),
        else: System.delete_env("RELEASE_NAME")
    end
  end

  describe "MIGRATE_ON_BOOT in runtime.exs" do
    test "defaults to migrating, so the shipped image needs no configuration" do
      assert read_prod_config(%{}) == true
    end

    test "false, 0 and no all turn it off" do
      for value <- ~w(false 0 no) do
        assert read_prod_config(%{"MIGRATE_ON_BOOT" => value}) == false,
               "MIGRATE_ON_BOOT=#{value} should disable boot-time migrations"
      end
    end

    test "anything else keeps migrating — the safe reading of a typo" do
      # Getting this wrong migrates as today (benign); the reverse would hand
      # a pod a schema nobody ran.
      for value <- ~w(true 1 yes maybe) do
        assert read_prod_config(%{"MIGRATE_ON_BOOT" => value}) == true,
               "MIGRATE_ON_BOOT=#{value} should leave boot-time migrations on"
      end
    end
  end

  describe "Fountain.Release.migrate_on_boot?/0" do
    test "follows the application env" do
      with_switch(false, fn -> refute Fountain.Release.migrate_on_boot?() end)
      with_switch(true, fn -> assert Fountain.Release.migrate_on_boot?() end)
    end
  end

  describe "the Ecto.Migrator child in Fountain.Application" do
    test "migrates in a release" do
      with_release_name("fountain_server", fn ->
        with_switch(true, fn -> refute Fountain.Application.skip_migrations?() end)
      end)
    end

    test "is skipped by the same switch that skips the CMD's migration" do
      with_release_name("fountain_server", fn ->
        with_switch(false, fn -> assert Fountain.Application.skip_migrations?() end)
      end)
    end

    test "never migrates outside a release, switch or no switch" do
      with_release_name(nil, fn ->
        with_switch(true, fn -> assert Fountain.Application.skip_migrations?() end)
      end)
    end
  end

  describe "the entrypoints" do
    test "the image CMD goes through the gated path" do
      dockerfile = File.read!(Path.join(@repo_root, "Dockerfile"))

      assert dockerfile =~ "Fountain.Release.migrate_on_boot()",
             "the image CMD must call the gated boot migration, or MIGRATE_ON_BOOT=false " <>
               "leaves the CMD migrating anyway"
    end

    test "bin/migrate ignores the switch, because a Job runs it to migrate" do
      script = File.read!(Path.join(@repo_root, "rel/overlays/bin/migrate"))

      assert script =~ "Fountain.Release.migrate"
      refute script =~ "migrate_on_boot"
    end
  end

  describe "the migration lock" do
    test "is a Postgres advisory lock, not Ecto's default table lock" do
      # The default (`FOR UPDATE` on schema_migrations) cannot serialize the
      # creation of schema_migrations itself, which is the race two replicas
      # hit on a virgin database. The deployment docs state this guarantee.
      assert Application.get_env(:fountain, Fountain.Repo)[:migration_lock] ==
               :pg_advisory_lock
    end
  end
end
