defmodule Fountain.ReleaseWithoutPubSubTest do
  @moduledoc """
  The release tasks against the VM they actually run in.

  `Fountain.Release` starts the Repo and nothing else (#256), so a context
  function that reaches for `Fountain.PubSub` raises there and nowhere else —
  which is how #609 shipped past `Fountain.ReleaseTest`, whose VM has the whole
  application up. This module takes PubSub down for the duration so the tasks
  run in the shape production gives them.
  """

  # async: false, and it stops a VM-wide process: ExUnit runs sync modules one
  # at a time after every async one has finished, which is what makes that safe.
  use Fountain.DataCase, async: false

  import ExUnit.CaptureIO

  alias Fountain.Release

  setup do
    :ok = Supervisor.terminate_child(Fountain.Supervisor, Phoenix.PubSub.Supervisor)

    on_exit(fn ->
      {:ok, _} = Supervisor.restart_child(Fountain.Supervisor, Phoenix.PubSub.Supervisor)
    end)

    refute Process.whereis(Fountain.PubSub)
    :ok
  end

  describe "verify_email/1 without PubSub (#609)" do
    test "verifies the account and reports success" do
      user = insert_user()
      assert is_nil(user.email_verified_at)

      # Pre-#609 this raised ArgumentError from Registry.meta/2 — after the
      # row was written and the first-admin bootstrap had run. The account
      # came out verified and the task exited non-zero having printed nothing
      # but a stack trace, so every caller that checks the exit code (the
      # fountain-ops e2e gate among them) concluded it had failed.
      out =
        capture_io(fn ->
          assert {:ok, verified} = Release.verify_email(user.email)
          assert %DateTime{} = verified.email_verified_at
        end)

      assert out =~ "You can now sign in."
      assert %DateTime{} = Repo.reload!(user).email_verified_at
    end

    test "still reports not_found for an unknown email" do
      capture_io(:stderr, fn ->
        assert {:error, :not_found} =
                 Release.verify_email("nobody-#{System.unique_integer([:positive])}@example.com")
      end)
    end
  end

  describe "the other release tasks without PubSub" do
    # None of these broadcast today. They are here because #609 was a shared
    # context function acquiring a broadcast for a web concern with nothing
    # watching the task side — the tasks are what notices, so let them.
    test "create_admin_key/2 mints the key" do
      {:ok, admin} = Fountain.Accounts.update_user_role(insert_user(), "admin")

      capture_io(fn ->
        assert {:ok, key} = Release.create_admin_key(admin.email, "provisioner")
        assert key.scopes == ["full", "admin"]
      end)
    end
  end
end
