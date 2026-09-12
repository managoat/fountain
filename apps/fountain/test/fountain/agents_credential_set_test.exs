defmodule Fountain.AgentsCredentialSetTest do
  @moduledoc """
  An agent names the credential set its conversations run on, and bounds
  which set a launch may name instead (ADR 0053 decision 3).

  Nothing reads `allowed_inference_credential_ids` yet -- the launch override
  it bounds arrives in the next PR. It is stored and versioned here so the
  allowlist exists before anything can be launched past it, which is the
  order `allowed_environment_ids` was built in too.
  """

  use Fountain.DataCase, async: true

  alias Fountain.Agents
  alias Fountain.Conversations.SpriteEnv
  alias Fountain.Crypto
  alias Fountain.InferenceCredentials
  alias Fountain.InferenceCredentials.Source

  setup do
    user = insert_verified_user()
    {:ok, dek} = Crypto.load_tenant_key(user.id)
    %{user: user, dek: dek}
  end

  defp set_with(user, dek, name, credential, value) do
    {:ok, set} = InferenceCredentials.create_set(user.id, name)

    set
    |> Ecto.Changeset.change([{ciphertext_field(credential), Crypto.encrypt(value, dek)}])
    |> Repo.update!()
  end

  defp ciphertext_field(:anthropic_api_key), do: :anthropic_api_key_ciphertext
  defp ciphertext_field(:openai_api_key), do: :openai_api_key_ciphertext

  describe "naming a set" do
    test "an agent runs on the set it names, not the account default", %{user: user, dek: dek} do
      default = set_with(user, dek, "Default", :anthropic_api_key, "sk-default")
      other = set_with(user, dek, "Second subscription", :anthropic_api_key, "sk-second")
      assert default.is_default

      {:ok, agent} =
        Agents.create_agent(
          agent_attrs(%{
            "user_id" => user.id,
            "runtime" => "claude",
            "model" => "anthropic/claude-opus-5",
            "inference_credential_id" => other.id
          })
        )

      assert {:ok, ^dek, creds} =
               SpriteEnv.load_tenant_state(user.id, agent.inference_credential_id)

      assert creds == %{anthropic_api_key: "sk-second"}
    end

    test "an agent naming none runs on the default, as every agent did", %{user: user, dek: dek} do
      _default = set_with(user, dek, "Default", :anthropic_api_key, "sk-default")
      _other = set_with(user, dek, "Second", :anthropic_api_key, "sk-second")

      {:ok, agent} =
        Agents.create_agent(agent_attrs(%{"user_id" => user.id, "runtime" => "claude"}))

      assert is_nil(agent.inference_credential_id)

      assert {:ok, _dek, %{anthropic_api_key: "sk-default"}} =
               SpriteEnv.load_tenant_state(user.id, agent.inference_credential_id)
    end

    test "the selection sees the named set's credential", %{user: user, dek: dek} do
      _default = set_with(user, dek, "Default", :openai_api_key, "sk-openai-only")
      anthropic = set_with(user, dek, "Anthropic", :anthropic_api_key, "sk-ant")

      {:ok, agent} =
        Agents.create_agent(
          agent_attrs(%{
            "user_id" => user.id,
            "runtime" => "claude",
            "model" => "anthropic/claude-opus-5",
            "inference_credential_id" => anthropic.id
          })
        )

      {:ok, _dek, creds} = SpriteEnv.load_tenant_state(user.id, agent.inference_credential_id)

      assert {%Source{origin: :own, scope: :credential}, _} =
               SpriteEnv.select_inference(agent, creds)
    end
  end

  describe "ownership" do
    test "another tenant's set reads as does not exist, not as an attachment", %{user: user} do
      other_tenant = insert_verified_user()
      {:ok, theirs} = InferenceCredentials.create_set(other_tenant.id, "Theirs")

      assert {:error, changeset} =
               Agents.create_agent(
                 agent_attrs(%{
                   "user_id" => user.id,
                   "runtime" => "claude",
                   "inference_credential_id" => theirs.id
                 })
               )

      assert "does not exist" in errors_on(changeset).inference_credential_id
    end

    test "an update cannot move an agent onto another tenant's set", %{user: user, dek: dek} do
      mine = set_with(user, dek, "Mine", :anthropic_api_key, "sk-mine")
      other_tenant = insert_verified_user()
      {:ok, theirs} = InferenceCredentials.create_set(other_tenant.id, "Theirs")

      {:ok, agent} =
        Agents.create_agent(
          agent_attrs(%{
            "user_id" => user.id,
            "runtime" => "claude",
            "inference_credential_id" => mine.id
          })
        )

      assert {:error, changeset} =
               Agents.update_agent(agent, %{"inference_credential_id" => theirs.id})

      assert "does not exist" in errors_on(changeset).inference_credential_id
      assert Repo.reload!(agent).inference_credential_id == mine.id
    end

    # A set an id cannot resolve must not fall through to somebody else's
    # credential. `get_set/2` is tenant-scoped, so it resolves to nil and the
    # account's own default answers instead.
    test "a set id the tenant does not own falls back to their default", %{user: user, dek: dek} do
      _default = set_with(user, dek, "Default", :anthropic_api_key, "sk-mine")
      other_tenant = insert_verified_user()
      {:ok, other_dek} = Crypto.load_tenant_key(other_tenant.id)
      theirs = set_with(other_tenant, other_dek, "Theirs", :anthropic_api_key, "sk-theirs")

      assert {:ok, _dek, %{anthropic_api_key: "sk-mine"}} =
               SpriteEnv.load_tenant_state(user.id, theirs.id)
    end
  end

  describe "deleting a set an agent named" do
    # nilify_all, not delete_all: deleting a credential set must return the
    # agents that named it to the default, never delete them.
    test "returns the agent to the default rather than deleting it", %{user: user, dek: dek} do
      _default = set_with(user, dek, "Default", :anthropic_api_key, "sk-default")
      second = set_with(user, dek, "Second", :anthropic_api_key, "sk-second")

      {:ok, agent} =
        Agents.create_agent(
          agent_attrs(%{
            "user_id" => user.id,
            "runtime" => "claude",
            "inference_credential_id" => second.id
          })
        )

      {:ok, _} = InferenceCredentials.delete_set(second)

      reloaded = Repo.reload!(agent)
      assert is_nil(reloaded.inference_credential_id)

      assert {:ok, _dek, %{anthropic_api_key: "sk-default"}} =
               SpriteEnv.load_tenant_state(user.id, reloaded.inference_credential_id)
    end
  end

  describe "the version snapshot" do
    test "records both fields, so a rollback restores which key the agent ran on", %{
      user: user,
      dek: dek
    } do
      set = set_with(user, dek, "Second", :anthropic_api_key, "sk-second")

      {:ok, agent} =
        Agents.create_agent(
          agent_attrs(%{
            "user_id" => user.id,
            "runtime" => "claude",
            "inference_credential_id" => set.id,
            "allowed_inference_credential_ids" => [set.id]
          })
        )

      config = Agents.snapshot_config(agent)
      assert config["inference_credential_id"] == set.id
      assert config["allowed_inference_credential_ids"] == [set.id]
    end
  end
end
