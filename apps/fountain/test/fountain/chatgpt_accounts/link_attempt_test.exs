defmodule Fountain.ChatGPTAccounts.LinkAttemptTest do
  # ADR 0060 stage 4: the attempt row itself. What the database holds about
  # it, what `inspect/1` prints of it and what its secrets are bound to. The
  # lifecycle is `chatgpt_link_attempts_test.exs`.
  use Fountain.DataCase, async: true

  alias Fountain.ChatGPTAccounts.{Cipher, LinkAttempt}
  alias Fountain.Crypto

  @device_auth_id "deviceauth_SECRET_7f3a"
  @user_code "WXYZ-SECRET"

  setup do
    %{user: insert_verified_user(), other: insert_verified_user()}
  end

  defp attrs(user_id, id, extra) do
    {:ok, secrets} =
      Cipher.encrypt_attempt_secrets(user_id, id, %{
        device_auth_id: @device_auth_id,
        user_code: @user_code
      })

    secrets
    |> Map.merge(%{
      verification_url: "https://auth.openai.com/codex/device",
      poll_interval: 5,
      expires_at: DateTime.add(DateTime.utc_now(), 900, :second)
    })
    |> Map.merge(extra)
  end

  defp changeset(user, extra) do
    id = Ecto.UUID.generate()

    LinkAttempt.start_changeset(
      %LinkAttempt{id: id, user_id: user.id},
      attrs(user.id, id, extra)
    )
  end

  defp insert!(user, extra), do: user |> changeset(extra) |> Repo.insert!()

  describe "the target" do
    test "a new link carries a name and no grant", %{user: user} do
      attempt = insert!(user, %{name: "  Work  "})

      assert %LinkAttempt{state: "pending", name: "Work", grant_id: nil, poll_failures: 0} =
               attempt
    end

    test "a reconnect carries the grant and the generation it began against", %{user: user} do
      grant_id = Ecto.UUID.generate()
      generation = Ecto.UUID.generate()
      attempt = insert!(user, %{grant_id: grant_id, expected_generation: generation})

      assert %LinkAttempt{grant_id: ^grant_id, expected_generation: ^generation, name: nil} =
               attempt
    end

    test "neither, both, a blank name and a reconnect with no generation are refused",
         %{user: user} do
      assert %{name: ["can't be blank"]} = errors_on(changeset(user, %{}))
      assert %{name: ["can't be blank"]} = errors_on(changeset(user, %{name: "   "}))

      assert %{name: ["should be at most 200 character(s)"]} =
               errors_on(changeset(user, %{name: String.duplicate("n", 201)}))

      assert %{expected_generation: ["can't be blank"]} =
               errors_on(changeset(user, %{grant_id: Ecto.UUID.generate()}))

      assert %{name: ["give a name or a grant, not both"]} =
               errors_on(
                 changeset(user, %{
                   name: "Work",
                   grant_id: Ecto.UUID.generate(),
                   expected_generation: Ecto.UUID.generate()
                 })
               )
    end

    test "the database holds the same rule for a writer that skips the changeset",
         %{user: user} do
      attempt = insert!(user, %{name: "Work"})

      assert_raise Postgrex.Error, ~r/chatgpt_link_attempt_target/, fn ->
        Repo.query!(
          "UPDATE chatgpt_link_attempts SET grant_id = $1, expected_generation = $1 WHERE id = $2",
          [Ecto.UUID.dump!(Ecto.UUID.generate()), Ecto.UUID.dump!(attempt.id)]
        )
      end
    end
  end

  describe "one open reconnect per grant" do
    test "a second pending attempt on the grant is refused; a finished one is not in the way",
         %{user: user} do
      target = %{grant_id: Ecto.UUID.generate(), expected_generation: Ecto.UUID.generate()}
      first = insert!(user, target)

      assert {:error, changeset} = user |> changeset(target) |> Repo.insert()
      assert %{grant_id: ["already has a sign-in in progress"]} = errors_on(changeset)

      first |> LinkAttempt.finish_changeset("cancelled") |> Repo.update!()
      assert %LinkAttempt{state: "pending"} = insert!(user, target)
    end
  end

  describe "the end of an attempt" do
    test "drops both secrets, whatever the state", %{user: user} do
      for {state, extra} <- [
            {"completed", %{result_grant_id: Ecto.UUID.generate()}},
            {"cancelled", %{}},
            {"expired", %{}},
            {"failed", %{failure_reason: "stale_grant"}}
          ] do
        finished =
          user
          |> insert!(%{name: "Work " <> state})
          |> LinkAttempt.finish_changeset(state, extra)
          |> Repo.update!()

        assert %LinkAttempt{
                 state: ^state,
                 device_auth_ciphertext: nil,
                 user_code_ciphertext: nil
               } = Repo.reload!(finished)

        assert {:error, :no_secret} = Cipher.decrypt_attempt_secret(finished, :device_auth_id)
        assert {:error, :no_secret} = Cipher.decrypt_attempt_secret(finished, :user_code)
      end
    end

    test "a finished row is not written a second time", %{user: user} do
      cancelled =
        user |> insert!(%{name: "Work"}) |> LinkAttempt.finish_changeset("cancelled")

      cancelled = Repo.update!(cancelled)

      assert_raise FunctionClauseError, fn ->
        LinkAttempt.finish_changeset(cancelled, "completed", %{
          result_grant_id: Ecto.UUID.generate()
        })
      end
    end

    test "a failure is one of the reasons the schema names, never the provider's words",
         %{user: user} do
      attempt = insert!(user, %{name: "Work"})

      changeset =
        LinkAttempt.finish_changeset(attempt, "failed", %{
          failure_reason: "invalid_grant: token sk-abc was revoked"
        })

      assert %{failure_reason: ["is invalid"]} = errors_on(changeset)
    end

    test "the database refuses a finished row that kept a secret, a failure with no reason " <>
           "and a completion with no grant",
         %{user: user} do
      attempt = insert!(user, %{name: "Work"})
      id = Ecto.UUID.dump!(attempt.id)

      assert_raise Postgrex.Error, ~r/chatgpt_link_attempt_secrets_follow_state/, fn ->
        Repo.query!("UPDATE chatgpt_link_attempts SET state = 'cancelled' WHERE id = $1", [id])
      end

      for state <- ~w(failed completed) do
        assert_raise Postgrex.Error, ~r/chatgpt_link_attempt_outcome/, fn ->
          Repo.query!(
            "UPDATE chatgpt_link_attempts SET state = $2, device_auth_ciphertext = NULL, " <>
              "user_code_ciphertext = NULL WHERE id = $1",
            [id, state]
          )
        end
      end

      assert_raise Postgrex.Error, ~r/chatgpt_link_attempt_state/, fn ->
        Repo.query!(
          "UPDATE chatgpt_link_attempts SET state = 'approved', device_auth_ciphertext = NULL, " <>
            "user_code_ciphertext = NULL WHERE id = $1",
          [id]
        )
      end
    end
  end

  describe "expiry" do
    test "a pending row past its time is expired before anything writes that", %{user: user} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      attempt = insert!(user, %{name: "Work", expires_at: DateTime.add(now, 60, :second)})

      refute LinkAttempt.expired?(attempt, now)
      assert LinkAttempt.expired?(attempt, DateTime.add(now, 60, :second))
      assert LinkAttempt.expired?(attempt, DateTime.add(now, 3_600, :second))

      cancelled = attempt |> LinkAttempt.finish_changeset("cancelled") |> Repo.update!()
      refute LinkAttempt.expired?(cancelled, DateTime.add(now, 3_600, :second))
    end
  end

  describe "the secrets" do
    @tag :capture_log
    test "are stored as ciphertext and open only for this owner, attempt and field",
         %{user: user, other: other} do
      attempt = insert!(user, %{name: "Work"})

      refute attempt.device_auth_ciphertext =~ @device_auth_id
      refute attempt.user_code_ciphertext =~ @user_code

      assert {:ok, @device_auth_id} = Cipher.decrypt_attempt_secret(attempt, :device_auth_id)
      assert {:ok, @user_code} = Cipher.decrypt_attempt_secret(attempt, :user_code)

      # The other field's blob, in this one's column.
      swapped = %{attempt | user_code_ciphertext: attempt.device_auth_ciphertext}
      assert {:error, :undecryptable} = Cipher.decrypt_attempt_secret(swapped, :user_code)

      # The same blob under another attempt of the same owner.
      sibling = %{attempt | id: Ecto.UUID.generate()}
      assert {:error, :undecryptable} = Cipher.decrypt_attempt_secret(sibling, :user_code)

      # And under another owner, whose key is a different one.
      foreign = %{attempt | user_id: other.id}
      assert {:error, :undecryptable} = Cipher.decrypt_attempt_secret(foreign, :user_code)

      # It is not a grant's token either: that AAD names a grant and a token field.
      {:ok, dek} = Crypto.load_tenant_key(user.id)

      assert :error =
               Crypto.decrypt(
                 attempt.user_code_ciphertext,
                 dek,
                 "fountain.chatgpt_grant:#{user.id}:#{attempt.id}:access_token"
               )
    end

    test "do not print from the row or from a changeset", %{user: user} do
      attempt = insert!(user, %{name: "Work"})
      changeset = changeset(user, %{name: "Other"})

      for printed <- [inspect(attempt), inspect(changeset), inspect(changeset.changes)] do
        refute printed =~ @device_auth_id
        refute printed =~ @user_code
      end

      # A struct leaves a redacted field out; a changeset names it and hides it.
      refute inspect(attempt) =~ "_ciphertext"
      assert inspect(changeset) =~ "device_auth_ciphertext: \"**redacted**\""
      assert inspect(changeset) =~ "user_code_ciphertext: \"**redacted**\""
    end
  end

  describe "ownership" do
    test "deleting the account deletes its attempts and nobody else's",
         %{user: user, other: other} do
      mine = insert!(user, %{name: "Work"})
      theirs = insert!(other, %{name: "Work"})

      Repo.delete!(user)

      refute Repo.get(LinkAttempt, mine.id)
      assert Repo.get(LinkAttempt, theirs.id)
    end

    test "an attempt cannot be inserted for an account that does not exist" do
      id = Ecto.UUID.generate()
      owner = Ecto.UUID.generate()

      assert_raise Ecto.ConstraintError, ~r/chatgpt_link_attempts_user_id_fkey/, fn ->
        %LinkAttempt{id: id, user_id: owner}
        |> Ecto.Changeset.change(%{
          name: "Work",
          device_auth_ciphertext: <<1>>,
          user_code_ciphertext: <<1>>,
          verification_url: "https://auth.openai.com/codex/device",
          poll_interval: 5,
          expires_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Repo.insert()
      end
    end
  end
end
