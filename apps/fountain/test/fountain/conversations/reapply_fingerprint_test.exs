defmodule Fountain.Conversations.ReapplyFingerprintTest do
  use Fountain.DataCase, async: true

  alias Fountain.Conversations
  alias Fountain.Conversations.{Reapply, Sandbox}
  alias Fountain.Environments

  describe "fingerprint/1" do
    setup do
      user = insert_verified_user()
      %{user: user, env: insert_env(user_id: user.id)}
    end

    test "is stable across reads, and blind to variables", ctx do
      assert Reapply.fingerprint(ctx.env) == Reapply.fingerprint(ctx.env)
      assert Reapply.fingerprint(nil) == "none"

      {:ok, revarred} =
        Environments.update_environment(ctx.env, %{"env_vars" => %{"ANYTHING" => "else"}})

      assert Reapply.fingerprint(revarred) == Reapply.fingerprint(ctx.env)
    end

    test "changes when a build input does", ctx do
      # Each build field on its own, because the refusal a reapply gives names
      # the field and every one of these has to be able to force it.
      for change <- [
            %{"setup_script" => "echo different"},
            %{"packages" => %{"apt" => ["ripgrep"]}},
            %{
              "repositories" => [
                %{"url" => "https://example.com/repo.git", "mount_path" => "/home/sprite/repo"}
              ]
            },
            %{"networking_type" => "limited", "networking_config" => %{"allow" => ["a.test"]}}
          ] do
        {:ok, rebuilt} = Environments.update_environment(ctx.env, change)
        refute Reapply.fingerprint(rebuilt) == Reapply.fingerprint(ctx.env)
      end
    end
  end

  describe "the columns a reapply reads" do
    test "a sandbox records what its disk was built from and what was mounted on it" do
      user = insert_verified_user()
      env = insert_env(user_id: user.id)

      sandbox =
        insert_sandbox(
          user_id: user.id,
          status: "ready",
          environment_id: env.id,
          build_fingerprint: Reapply.fingerprint(env),
          applied_skills_by_runtime: %{"claude" => [%{"name" => "mine", "content" => "# m"}]}
        )

      reread = Conversations._unsafe_get_sandbox!(sandbox.id)
      assert reread.build_fingerprint == Reapply.fingerprint(env)
      assert Sandbox.applied_skills(reread, "claude") == [%{"name" => "mine", "content" => "# m"}]
      assert Sandbox.applied_skills(reread, "codex") == nil
    end

    test "a conversation starts at revision zero" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      assert Conversations._unsafe_get_conversation!(conv.id).configuration_revision == 0
    end
  end
end
