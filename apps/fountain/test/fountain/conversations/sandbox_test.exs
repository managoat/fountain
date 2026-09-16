defmodule Fountain.Conversations.SandboxTest do
  use Fountain.DataCase, async: true

  alias Fountain.Conversations
  alias Fountain.Conversations.Sandbox

  defp valid_attrs do
    %{
      machine_name: "sprite-abc123",
      status: "pending",
      user_id: Ecto.UUID.generate()
    }
  end

  defp changeset(overrides \\ %{}) do
    Sandbox.changeset(%Sandbox{}, Map.merge(valid_attrs(), overrides))
  end

  defp persisted(fields) do
    %Sandbox{machine_name: "sprite-abc123", status: "ready"}
    |> struct!(fields)
    |> Ecto.put_meta(state: :loaded)
  end

  describe "machine name storage and API boundary" do
    test "there is one internal name backed by the existing column" do
      assert Sandbox.__schema__(:field_source, :machine_name) == :sprite_name
      refute :sprite_name in Sandbox.__schema__(:fields)
    end

    for provider <- ~w(sprites e2b daytona runner) do
      test "loads and updates existing #{provider} names without changing their identity" do
        user = insert_user()
        sandbox = insert_sandbox(user_id: user.id, provider: unquote(provider))
        name = "existing-#{sandbox.id}"

        Repo.query!(
          "UPDATE sandboxes SET sprite_name = $1 WHERE id = $2::text::uuid",
          [name, sandbox.id]
        )

        loaded = Repo.get_by!(Sandbox, machine_name: name, provider: unquote(provider))
        assert loaded.machine_name == name
        assert loaded.provider_meta == sandbox.provider_meta
        assert loaded.provider_instance_id == sandbox.provider_instance_id

        handle =
          Managoat.Sandbox.build_handle(
            Fountain.Conversations.sandbox_provider_atom(loaded),
            loaded.machine_name
          )

        assert handle.name == name
        assert Atom.to_string(handle.provider) == unquote(provider)
        assert {:ok, updated} = Fountain.Conversations.update_sandbox(loaded, %{status: "ready"})
        assert updated.machine_name == name

        assert %{rows: [[^name, "ready"]]} =
                 Repo.query!(
                   "SELECT sprite_name, status FROM sandboxes WHERE id = $1::text::uuid",
                   [sandbox.id]
                 )
      end
    end

    test "conversation, sandbox and admin serializers retain the public sprite_name field" do
      user = insert_user()
      sandbox = insert_sandbox(user_id: user.id) |> Repo.preload([:user, :conversations])
      %{data: [admin]} = FountainWeb.AdminJSON.index_sandboxes(%{sandboxes: [sandbox]})

      for payload <- [
            FountainWeb.ConversationJSON.sandbox_data(sandbox),
            FountainWeb.SandboxJSON.data(sandbox),
            admin
          ] do
        json = payload |> Jason.encode!() |> Jason.decode!()
        assert json["sprite_name"] == sandbox.machine_name
        refute Map.has_key?(json, "machine_name")
      end
    end
  end

  describe "statuses/0" do
    test "returns all six valid statuses" do
      assert Sandbox.statuses() == ~w(pending starting ready suspended terminated failed)
    end
  end

  describe "retired sandbox updates" do
    for retired <- ~w(terminated failed), requested <- ~w(pending starting ready suspended) do
      test "a stale callback cannot move #{retired} to #{requested}" do
        user = insert_user()
        observed = insert_sandbox(user_id: user.id, status: "starting")

        assert {:ok, _} =
                 Fountain.Conversations.update_sandbox(observed, %{status: unquote(retired)})

        assert {:error, changeset} =
                 Fountain.Conversations.update_sandbox(observed, %{status: unquote(requested)})

        assert "sandbox is retired" in errors_on(changeset).status
        assert Fountain.Repo.reload!(observed).status == unquote(retired)
      end
    end

    test "metadata updates preserve the current retired status" do
      user = insert_user()
      observed = insert_sandbox(user_id: user.id, status: "starting")

      assert {:ok, retired} =
               Fountain.Conversations.update_sandbox(observed, %{status: "terminated"})

      assert {:ok, updated} =
               Fountain.Conversations.update_sandbox(observed, %{
                 provider_meta: %{"public_url" => "fixture"}
               })

      assert updated.status == "terminated"
      assert updated.terminated_at == retired.terminated_at
    end
  end

  describe "claim_sandbox/2" do
    test "returns the updated live sandbox" do
      sandbox = insert_sandbox(user_id: insert_user().id)
      assert {:ok, updated} = Conversations.claim_sandbox(sandbox, %{status: "ready"})
      assert updated.status == "ready"
      assert Repo.reload!(sandbox).status == "ready"
    end

    test "recognizes retirement alongside a different field validation" do
      sandbox = insert_sandbox(user_id: insert_user().id, status: "terminated")
      attrs = %{status: "ready", mode: "invalid"}
      assert {:error, changeset} = Conversations.update_sandbox(sandbox, attrs)
      assert Map.has_key?(errors_on(changeset), :mode)
      assert Conversations.sandbox_retired?(changeset)
      assert :retired = Conversations.claim_sandbox(sandbox, attrs)
      assert Repo.reload!(sandbox).status == "terminated"
    end

    test "preserves unrelated validation errors and reset refusals" do
      sandbox = insert_sandbox(user_id: insert_user().id, status: "ready")
      assert {:error, changeset} = Conversations.claim_sandbox(sandbox, %{mode: "invalid"})
      assert errors_on(changeset).mode == ["is invalid"]
      refute Conversations.sandbox_retired?(changeset)

      sandbox
      |> Ecto.Changeset.change(reset_requested_at: DateTime.utc_now())
      |> Repo.update!()

      assert {:error, :sandbox_reset_pending} =
               Conversations.claim_sandbox(sandbox, %{status: "ready"})

      refute Conversations.sandbox_retired?(:sandbox_reset_pending)
      assert Repo.reload!(sandbox).status == "ready"
    end
  end

  describe "sandbox_retired?/1" do
    test "checks every status error regardless of order" do
      for errors <- [
            [status: {"other failure", []}, status: {"sandbox is retired", []}],
            [status: {"sandbox is retired", []}, status: {"other failure", []}]
          ] do
        assert Conversations.sandbox_retired?(%Ecto.Changeset{errors: errors})
      end
    end

    test "does not mistake unrelated fields or errors for retirement" do
      refute Conversations.sandbox_retired?(%Ecto.Changeset{
               errors: [mode: {"sandbox is retired", []}, status: {"other failure", []}]
             })

      refute Conversations.sandbox_retired?(nil)
    end
  end

  describe "struct defaults" do
    test "default status is 'pending'" do
      assert %Sandbox{}.status == "pending"
    end
  end

  describe "changeset/2 with valid attrs" do
    test "is valid with all required fields" do
      assert changeset().valid?
    end
  end

  describe "changeset/2 required fields" do
    test "errors when machine_name is missing" do
      errors = changeset(%{machine_name: nil}) |> errors_on()
      assert "can't be blank" in errors.machine_name
    end

    test "errors when user_id is missing" do
      errors = changeset(%{user_id: nil}) |> errors_on()
      assert "can't be blank" in errors.user_id
    end

    # A deleted account nilifies `sandboxes.user_id` on rows it may not have
    # finished retiring. Those rows must still be able to go terminal, and
    # nothing else.
    for status <- ~w(terminated failed) do
      test "a persisted row whose owner was deleted can still become #{status}" do
        orphan = persisted(user_id: nil)
        assert Sandbox.changeset(orphan, %{status: unquote(status)}).valid?
      end
    end

    test "a persisted row whose owner was deleted cannot be reused" do
      orphan = persisted(user_id: nil)
      errors = Sandbox.changeset(orphan, %{status: "ready"}) |> errors_on()
      assert "can't be blank" in errors.user_id
    end

    test "retiring a row cannot also clear its owner" do
      owned = persisted(user_id: Ecto.UUID.generate())
      errors = Sandbox.changeset(owned, %{status: "terminated", user_id: nil}) |> errors_on()
      assert "can't be blank" in errors.user_id
    end
  end

  describe "changeset/2 status inclusion" do
    for status <- ~w(pending starting ready terminated failed) do
      test "accepts status '#{status}'" do
        assert changeset(%{status: unquote(status)}).valid?
      end
    end

    test "rejects an unknown status" do
      errors = changeset(%{status: "unknown"}) |> errors_on()
      assert "is invalid" in errors.status
    end
  end
end
