defmodule Fountain.Conversations.SavedAllowanceAdmissionTest do
  use Fountain.DataCase, async: true

  alias Fountain.Conversations
  alias Fountain.Conversations.{Connection, ExecutionAllowance, TurnMachine}

  setup do
    %{conversation: insert_conversation(status: "idle")}
  end

  # One test, not one per capacity: since ADR 0058 stage 8a the bound is the
  # conversation's runtime, read by the owner under the lock, so a caller has no
  # capacity to pass and the fence is checked before any count is made.
  test "admission refuses every saved control", %{conversation: conv} do
    for {field, value} <- [
          wall_time_seconds: 30,
          max_model_turns: 2,
          max_estimated_cost_usd: 0.5
        ] do
      allowance =
        conv.id |> ExecutionAllowance.new_changeset(%{field => value}) |> Repo.insert!()

      assert {:error, {:execution_limits_unsupported, [key]}} =
               admit(conv)

      assert key == Atom.to_string(field)
      assert Conversations._unsafe_list_turns(conv.id) == []
      assert Repo.reload!(allowance) == allowance
      Repo.delete!(allowance)
    end
  end

  test "admission accepts absent and empty allowances", %{
    conversation: conv
  } do
    assert {:ok, first} = admit(conv)
    Repo.delete!(first)
    conv.id |> ExecutionAllowance.new_changeset(%{}) |> Repo.insert!()
    assert {:ok, _} = admit(conv)
  end

  test "both user and autonomous turn openers propagate the refusal", %{conversation: conv} do
    conv.id |> ExecutionAllowance.new_changeset(%{max_model_turns: 2}) |> Repo.insert!()
    expected = {:error, {:execution_limits_unsupported, ["max_model_turns"]}}
    assert TurnMachine.open(conv.id, conv.sandbox_id, "user prompt") == expected

    assert Connection.open_autonomous_turn(
             conv.id,
             conv.user_id,
             conv.sandbox_id,
             conv.configuration_revision,
             conv.inference_source
           ) == expected

    assert Conversations._unsafe_list_turns(conv.id) == []
    assert Repo.reload!(conv).status == "idle"

    refute Repo.exists?(
             from e in Fountain.Billing.UsageEvent,
               where: e.user_id == ^conv.user_id and e.event_type == "turn_started"
           )
  end

  test "malformed saved policy is refused rather than treated as unbounded", %{conversation: conv} do
    allowance = conv.id |> ExecutionAllowance.new_changeset(%{}) |> Repo.insert!()

    for limits <- [%{"max_model_turns" => 0}, %{"unknown" => 10}] do
      allowance |> Ecto.Changeset.change(limits: limits) |> Repo.update!()
      assert {:error, {:execution_limits_invalid, _}} = admit(conv)
      assert Conversations._unsafe_list_turns(conv.id) == []
    end

    # JSON null is distinct from SQL NULL and can bypass the NOT NULL column.
    Repo.query!(
      "UPDATE execution_allowances SET limits = 'null'::jsonb WHERE conversation_id = $1",
      [
        Ecto.UUID.dump!(conv.id)
      ]
    )

    assert {:error, {:execution_limits_invalid, "object_required"}} = admit(conv)
  end

  test "a different tenant's allowance neither blocks nor authorizes this conversation", %{
    conversation: conv
  } do
    other = insert_conversation()
    other.id |> ExecutionAllowance.new_changeset(%{max_model_turns: 2}) |> Repo.insert!()
    assert {:ok, _} = admit(conv)

    assert {:error, :sandbox_unavailable} =
             Conversations._unsafe_create_turn_on_sandbox(
               attrs(other),
               conv.sandbox_id
             )

    assert Conversations._unsafe_list_turns(other.id) == []
  end

  defp admit(conv),
    do: Conversations._unsafe_create_turn_on_sandbox(attrs(conv), conv.sandbox_id)

  defp attrs(conv),
    do: %{conversation_id: conv.id, turn_number: 1, prompt: "probe", status: "running"}
end

defmodule Fountain.Conversations.SavedAllowanceAdmissionRaceTest do
  use ExUnit.Case, async: false

  alias Fountain.{Conversations, Repo}
  alias Fountain.Conversations.{ExecutionAllowance, Sandbox}
  import Ecto.Query, only: [from: 2]
  import Fountain.Factory, only: [insert_conversation: 1]

  for existing <- [false, true], write_first <- [false, true] do
    test "existing=#{existing}, write_first=#{write_first}: allowance and turn writes serialize" do
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        {:ok, {user, conv, allowance}} =
          Repo.transaction(fn ->
            user =
              Repo.insert!(%Fountain.Accounts.User{
                email: "admission-race-#{Ecto.UUID.generate()}@example.test"
              })

            conv = insert_conversation(user_id: user.id, status: "idle")

            allowance =
              if unquote(existing),
                do: conv.id |> ExecutionAllowance.new_changeset(%{}) |> Repo.insert!()

            {user, conv, allowance}
          end)

        try do
          race(conv, allowance, unquote(write_first))
        after
          # Billing history survives user deletion; remove this fixture's rows
          # before deleting its user so they cannot become anonymous test data.
          Repo.delete_all(from e in Fountain.Billing.UsageEvent, where: e.user_id == ^user.id)
          Repo.delete!(user)
          Repo.get!(Sandbox, conv.sandbox_id) |> Repo.delete!()
          assert Repo.get(ExecutionAllowance, conv.id) == nil
          assert Repo.get(Sandbox, conv.sandbox_id) == nil
        end
      end)
    end
  end

  defp race(conv, allowance, write_first) do
    write = fn -> save_limit(conv, allowance) end

    admit = fn ->
      Conversations._unsafe_create_turn_on_sandbox(
        %{conversation_id: conv.id, turn_number: 1, prompt: "probe", status: "running"},
        conv.sandbox_id
      )
    end

    {first_op, second_op} = if write_first, do: {write, admit}, else: {admit, write}
    owner = self()

    first =
      independent(fn ->
        Repo.transaction(fn ->
          result = first_op.()
          send(owner, :first_done)

          receive do
            :commit -> result
          after
            10_000 -> raise "commit barrier timed out"
          end
        end)
      end)

    try do
      assert_receive :first_done, 5_000
      second = independent(second_op)

      try do
        assert_receive {:backend, first_pid, first_backend}, 5_000
        assert first_pid == first.pid
        assert_receive {:backend, second_pid, second_backend}, 5_000
        assert second_pid == second.pid
        refute first_backend == second_backend
        await_blocked(second_backend, System.monotonic_time(:millisecond) + 5_000)
        send(first.pid, :commit)
        assert {:ok, {:ok, _}} = Task.await(first)
        result = Task.await(second)

        if write_first do
          assert result == {:error, {:execution_limits_unsupported, ["max_model_turns"]}}
          assert Conversations._unsafe_list_turns(conv.id) == []
        else
          assert {:ok, %ExecutionAllowance{}} = result
          assert [_] = Conversations._unsafe_list_turns(conv.id)
        end

        assert Repo.get!(ExecutionAllowance, conv.id).limits == %{"max_model_turns" => 2}
      after
        Task.shutdown(second, :brutal_kill)
      end
    after
      Task.shutdown(first, :brutal_kill)
    end
  end

  defp save_limit(conv, nil),
    do: conv.id |> ExecutionAllowance.new_changeset(%{max_model_turns: 2}) |> Repo.insert()

  defp save_limit(_conv, allowance),
    do: allowance |> ExecutionAllowance.narrow_changeset(%{max_model_turns: 2}) |> Repo.update()

  defp independent(fun) do
    owner = self()

    Task.async(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
        send(owner, {:backend, self(), backend})
        fun.()
      end)
    end)
  end

  defp await_blocked(backend, deadline) do
    %{rows: [[blocked]]} = Repo.query!("SELECT cardinality(pg_blocking_pids($1)) > 0", [backend])

    unless blocked do
      assert System.monotonic_time(:millisecond) < deadline, "no PostgreSQL lock wait observed"
      Process.sleep(5)
      await_blocked(backend, deadline)
    end
  end
end
