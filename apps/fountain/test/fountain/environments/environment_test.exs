defmodule Fountain.Environments.EnvironmentTest do
  use Fountain.DataCase, async: true

  alias Fountain.Environments.Environment

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp base_attrs do
    %{"name" => "test-env-#{System.unique_integer([:positive])}"}
  end

  defp changeset(overrides \\ %{}) do
    Environment.changeset(%Environment{}, Map.merge(base_attrs(), overrides))
  end

  # ---------------------------------------------------------------------------
  # warm_start_fields/0
  # ---------------------------------------------------------------------------

  describe "warm_start_fields/0" do
    test "returns the expected warm-start fields" do
      assert Environment.warm_start_fields() ==
               [
                 :packages,
                 :env_vars,
                 :setup_script,
                 :setup_timeout_seconds,
                 :networking_type,
                 :networking_config,
                 :repositories
               ]
    end
  end

  describe "repository_mounts/1" do
    test "is each repository's mount_path, in order, without repeats" do
      env = %Environment{
        repositories: [
          %{"url" => "https://github.com/o/a", "mount_path" => "/workspace/a"},
          %{"url" => "https://github.com/o/b", "mount_path" => "/workspace/b"},
          %{"url" => "https://github.com/o/a2", "mount_path" => "/workspace/a"}
        ]
      }

      assert Environment.repository_mounts(env) == ["/workspace/a", "/workspace/b"]
    end

    test "is empty with no environment or no repositories" do
      assert Environment.repository_mounts(nil) == []
      assert Environment.repository_mounts(%Environment{repositories: []}) == []
      assert Environment.repository_mounts(%Environment{repositories: nil}) == []
    end
  end

  # ---------------------------------------------------------------------------
  # changeset/2 — basic validity
  # ---------------------------------------------------------------------------

  describe "changeset/2 with valid attrs" do
    test "is valid when all required fields are present" do
      assert changeset().valid?
    end
  end

  # ---------------------------------------------------------------------------
  # changeset/2 — required fields
  # ---------------------------------------------------------------------------

  describe "changeset/2 required fields" do
    test "errors when name is missing" do
      errors = changeset(%{"name" => nil}) |> errors_on()
      assert "can't be blank" in errors.name
    end
  end

  # ---------------------------------------------------------------------------
  # changeset/2 — name length
  # ---------------------------------------------------------------------------

  describe "changeset/2 name length" do
    test "accepts a 1-character name" do
      assert changeset(%{"name" => "x"}).valid?
    end

    test "accepts a 200-character name" do
      assert changeset(%{"name" => String.duplicate("a", 200)}).valid?
    end

    test "rejects an empty string name" do
      errors = changeset(%{"name" => ""}) |> errors_on()
      assert errors.name != []
    end

    test "rejects a 201-character name" do
      errors = changeset(%{"name" => String.duplicate("a", 201)}) |> errors_on()
      assert errors.name != []
    end
  end

  # ---------------------------------------------------------------------------
  # changeset/2 — networking_type inclusion
  # ---------------------------------------------------------------------------

  describe "changeset/2 networking_type inclusion" do
    test "accepts 'unrestricted'" do
      assert changeset(%{"networking_type" => "unrestricted"}).valid?
    end

    test "accepts 'limited'" do
      assert changeset(%{"networking_type" => "limited"}).valid?
    end

    test "rejects 'none'" do
      errors = changeset(%{"networking_type" => "none"}) |> errors_on()
      assert "is invalid" in errors.networking_type
    end
  end

  # ---------------------------------------------------------------------------
  # validate_networking_config
  # ---------------------------------------------------------------------------

  describe "validate_networking_config" do
    test "allowed_hosts as a list of hostnames passes" do
      cs =
        changeset(%{
          "networking_type" => "limited",
          "networking_config" => %{"allowed_hosts" => ["registry.npmjs.org", "github.com"]}
        })

      assert cs.valid?
    end

    test "config without allowed_hosts passes (unknown keys are ignored)" do
      cs = changeset(%{"networking_config" => %{"future_knob" => true}})
      assert cs.valid?
    end

    test "allowed_hosts as a bare string fails" do
      errors =
        changeset(%{"networking_config" => %{"allowed_hosts" => "github.com"}})
        |> errors_on()

      assert "allowed_hosts must be a list of hostnames" in errors.networking_config
    end

    test "allowed_hosts containing an empty string fails" do
      errors =
        changeset(%{"networking_config" => %{"allowed_hosts" => ["github.com", ""]}})
        |> errors_on()

      assert "allowed_hosts entries must be non-empty strings" in errors.networking_config
    end

    test "allowed_hosts containing a non-string fails" do
      errors =
        changeset(%{"networking_config" => %{"allowed_hosts" => [42]}})
        |> errors_on()

      assert "allowed_hosts entries must be non-empty strings" in errors.networking_config
    end
  end

  # ---------------------------------------------------------------------------
  # validate_repositories
  # ---------------------------------------------------------------------------

  describe "validate_repositories" do
    test "valid repository entry passes without errors" do
      cs =
        changeset(%{
          "repositories" => [%{"url" => "https://github.com/org/repo", "mount_path" => "/app"}]
        })

      assert cs.valid?
    end

    test "non-https url produces an error" do
      errors =
        changeset(%{
          "repositories" => [
            %{"url" => "http://github.com/org/repo", "mount_path" => "/app"}
          ]
        })
        |> errors_on()

      assert errors.repositories != []
    end

    test "relative mount_path produces an error" do
      errors =
        changeset(%{
          "repositories" => [
            %{"url" => "https://github.com/org/repo", "mount_path" => "relative/path"}
          ]
        })
        |> errors_on()

      assert errors.repositories != []
    end

    test "missing mount_path key produces an error" do
      errors =
        changeset(%{
          "repositories" => [%{"url" => "https://github.com/org/repo"}]
        })
        |> errors_on()

      assert errors.repositories != []
    end

    test "empty list is valid" do
      assert changeset(%{"repositories" => []}).valid?
    end
  end

  # ---------------------------------------------------------------------------
  # maybe_invalidate_checkpoint
  # ---------------------------------------------------------------------------

  describe "maybe_invalidate_checkpoint" do
    test "nulls checkpoint_id when a warm_start_field changes without explicit checkpoint_id" do
      env_with_checkpoint = %Environment{checkpoint_id: "ckpt_abc"}
      cs = Environment.changeset(env_with_checkpoint, %{"setup_script" => "echo hi"})

      assert cs.changes.checkpoint_id == nil
    end

    test "does not touch checkpoint_id when only a non-warm-start field (name) changes" do
      env_with_checkpoint = %Environment{checkpoint_id: "ckpt_abc"}
      cs = Environment.changeset(env_with_checkpoint, %{"name" => "new-name"})

      refute Map.has_key?(cs.changes, :checkpoint_id)
    end

    test "does not touch checkpoint_id when only metadata changes" do
      env_with_checkpoint = %Environment{checkpoint_id: "ckpt_abc"}
      cs = Environment.changeset(env_with_checkpoint, %{"metadata" => %{"owner" => "chant"}})

      refute Map.has_key?(cs.changes, :checkpoint_id)
    end

    test "preserves an explicit checkpoint_id even when a warm_start_field also changes" do
      env_with_checkpoint = %Environment{checkpoint_id: "ckpt_abc"}

      cs =
        Environment.changeset(env_with_checkpoint, %{
          "setup_script" => "echo hi",
          "checkpoint_id" => "ckpt_123"
        })

      assert cs.changes.checkpoint_id == "ckpt_123"
    end
  end
end
