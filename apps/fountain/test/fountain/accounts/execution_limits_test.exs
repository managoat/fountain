defmodule Fountain.Accounts.ExecutionLimitsTest do
  use Fountain.DataCase, async: true

  alias Fountain.Accounts.User

  test "operator changes persist canonical ceilings without changing another account" do
    user = insert_user()
    other = insert_user()
    assert user.execution_limits == %{}

    updated =
      user
      |> User.execution_limits_changeset(%{
        wall_time_seconds: 60,
        max_model_turns: 10,
        max_estimated_cost_usd: 0.5
      })
      |> Repo.update!()

    assert Repo.reload!(updated).execution_limits == %{
             "wall_time_seconds" => 60,
             "max_model_turns" => 10,
             "max_estimated_cost_usd" => 0.5
           }

    assert Repo.reload!(other).execution_limits == %{}
  end

  test "an operator can replace or clear its account override" do
    user = insert_user()

    for limits <- [%{max_model_turns: 2}, %{max_model_turns: 20}, nil, %{}] do
      updated = Repo.reload!(user) |> User.execution_limits_changeset(limits) |> Repo.update!()

      expected =
        if limits in [nil, %{}], do: %{}, else: %{"max_model_turns" => limits.max_model_turns}

      assert Repo.reload!(updated).execution_limits == expected
    end
  end

  test "invalid ceilings are refused without changing stored values or echoing input" do
    user =
      insert_user() |> User.execution_limits_changeset(%{max_model_turns: 2}) |> Repo.update!()

    for {limits, field} <- [
          {%{wall_time_seconds: nil}, "wall_time_seconds"},
          {%{max_model_turns: "2"}, "max_model_turns"},
          {%{max_estimated_cost_usd: 0}, "max_estimated_cost_usd"},
          {%{"private-field" => "private-value"}, "unknown_field"},
          {%{:max_model_turns => 2, "max_model_turns" => 3}, "duplicate_field"},
          {[], "object_required"}
        ] do
      assert {:error, changeset} =
               user |> User.execution_limits_changeset(limits) |> Repo.update()

      assert errors_on(changeset).execution_limits == ["invalid #{field}"]
      assert Repo.reload!(user) == user
    end
  end

  test "registration and OAuth cannot set ceilings" do
    attrs = %{
      email: "ceiling-#{Ecto.UUID.generate()}@example.test",
      password: "valid-password",
      execution_limits: %{max_model_turns: 999}
    }

    for changeset <- [
          User.registration_changeset(%User{}, attrs),
          User.oauth_registration_changeset(%User{}, %{attrs | email: "oauth-#{attrs.email}"})
        ] do
      assert Repo.insert!(changeset).execution_limits == %{}
    end
  end

  test "ordinary account changes cannot clear or widen stored ceilings" do
    user =
      insert_user() |> User.execution_limits_changeset(%{max_model_turns: 2}) |> Repo.update!()

    for limits <- [nil, %{}, %{"max_model_turns" => 999}] do
      attrs = %{
        "execution_limits" => limits,
        "theme_preference" => "dark"
      }

      changeset = User.theme_changeset(user, attrs)

      assert Repo.update!(changeset).execution_limits == user.execution_limits
      assert Repo.reload!(user).execution_limits == user.execution_limits
    end
  end

  test "the database rejects SQL null, JSON null and non-object ceilings" do
    user = insert_user()

    for json <- [nil, "null", "[]", "1", "\"value\""] do
      assert {:error, %Postgrex.Error{postgres: %{code: code}}} =
               Repo.query(
                 "UPDATE users SET execution_limits = $1::text::jsonb WHERE id = $2",
                 [json, Ecto.UUID.dump!(user.id)],
                 mode: :savepoint
               )

      assert code == if(is_nil(json), do: :not_null_violation, else: :check_violation)
      assert Repo.reload!(user).execution_limits == %{}
    end
  end
end
