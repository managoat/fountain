defmodule Fountain.AgentsCredentialSetTest do
  @moduledoc """
  An agent names the credential set its conversations run on, and bounds
  which set a launch may name instead (ADR 0053 decision 3).

  This file covers storing, owning and versioning the set and the allowlist.
  Enforcing `allowed_inference_credential_ids` at launch is tested in
  `Fountain.Conversations.LaunchCredentialSetTest`, and the explicit policy it
  derives (#2107) in `Fountain.Agents.CredentialSetAccessTest`.
  """

  use Fountain.DataCase, async: true

  alias Fountain.Agents
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

      assert InferenceCredentials.decrypted_for(user.id, agent.inference_credential_id, dek) ==
               {:ok, %{anthropic_api_key: "sk-second"}}
    end

    test "an agent naming none runs on the default, as every agent did", %{user: user, dek: dek} do
      _default = set_with(user, dek, "Default", :anthropic_api_key, "sk-default")
      _other = set_with(user, dek, "Second", :anthropic_api_key, "sk-second")

      {:ok, agent} =
        Agents.create_agent(agent_attrs(%{"user_id" => user.id, "runtime" => "claude"}))

      assert is_nil(agent.inference_credential_id)

      assert InferenceCredentials.decrypted_for(user.id, agent.inference_credential_id, dek) ==
               {:ok, %{anthropic_api_key: "sk-default"}}
    end

    test "an account holding nothing reads as an empty map", %{user: user, dek: dek} do
      assert InferenceCredentials.decrypted_for(user.id, nil, dek) == {:ok, %{}}
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

      assert {:ok, %Source{scope: :credential, set_id: set_id}, %{anthropic_api_key: "sk-ant"}} =
               InferenceCredentials.resolve(user.id, agent.model, agent.runtime,
                 credential_set_id: agent.inference_credential_id
               )

      assert set_id == anthropic.id
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

    # An explicit unresolved selection refuses rather than silently switching.
    test "a set id the tenant does not own is refused", %{user: user, dek: dek} do
      _default = set_with(user, dek, "Default", :anthropic_api_key, "sk-mine")
      other_tenant = insert_verified_user()
      {:ok, other_dek} = Crypto.load_tenant_key(other_tenant.id)
      theirs = set_with(other_tenant, other_dek, "Theirs", :anthropic_api_key, "sk-theirs")

      assert {:error, :inference_credential_not_found} =
               InferenceCredentials.resolve(user.id, "anthropic/claude-opus-5", "claude",
                 credential_set_id: theirs.id
               )
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

      assert InferenceCredentials.decrypted_for(user.id, reloaded.inference_credential_id, dek) ==
               {:ok, %{anthropic_api_key: "sk-default"}}
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
