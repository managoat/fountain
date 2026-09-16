defmodule Fountain.Conversations.ConversationServerLogBudgetTest do
  # #331: log_events had no per-conversation volume bound inside the
  # retention window — retention bounds age, not rate, and Postgres is the
  # same volume the app depends on. Once the budget is exceeded, one
  # truncation marker is persisted and later chunks are dropped.
  use Fountain.ConversationServerCase

  setup do
    Application.put_env(:fountain, :log_output_byte_budget, 100)
    on_exit(fn -> Application.delete_env(:fountain, :log_output_byte_budget) end)
    :ok
  end

  defp start_with_turn(conv) do
    cmd_ref = make_ref()

    Mimic.stub(Managoat.Sandbox.Sprites, :spawn, fn _h, _cmd, _args, _opts ->
      {:ok, %Managoat.Sandbox.Command{provider: :sprites, ref: cmd_ref}}
    end)

    Mimic.stub(Managoat.Sandbox.Sprites, :write_stdin, fn _cmd, _data -> :ok end)
    Mimic.stub(Managoat.Sandbox.Sprites, :close_stdin, fn _cmd -> :ok end)

    {pid, mon, :alive} = start_server(conv, initial_prompt: "go")
    _ = :sys.get_state(pid)
    {pid, cmd_ref, mon}
  end

  defp setup_conv do
    stub_happy_sprite()
    user = insert_verified_user()
    # gemini used to be this test's way of reaching the legacy stdout handler.
    # Since #659 every shipped runtime speaks ACP, so output reaches the budget
    # through the peer's line reports instead — same output logger,
    # different transport. See `persist_acp_lines/3`.
    agent = insert_agent(user_id: user.id, runtime: "claude")
    insert_conversation(user_id: user.id, agent_id: agent.id)
  end

  defp output_events(conv_id) do
    conv_id
    |> Conversations._unsafe_list_log_events()
    |> Enum.filter(&(&1.kind == "output"))
  end

  test "output over the budget is replaced by a single marker and then dropped" do
    conv = setup_conv()
    {pid, cmd_ref, _ref} = start_with_turn(conv)

    # 3 x 60 bytes against a 100-byte budget: chunk 1 persists, chunk 2
    # crosses the budget → marker, chunk 3 is silently dropped. Dots, because
    # a chunk ending in a registered value's first byte is held back (#2359)
    # and would no longer arrive as one row.
    chunk = String.duplicate(".", 60)
    for _ <- 1..3, do: send(pid, {:acp, cmd_ref, {:lines, "stdout", chunk}})
    _ = :sys.get_state(pid)

    events = output_events(conv.id)
    data = Enum.map(events, & &1.data)

    assert Enum.count(data, &(&1 == chunk)) == 1
    assert [marker] = Enum.filter(data, &(&1 =~ "durable log budget"))
    assert marker =~ "discarded"

    # Nothing after the marker.
    assert length(events) == 2

    GenServer.stop(pid)
  end

  test "the budget seeds from bytes already persisted, so it is cumulative across wakes" do
    conv = setup_conv()
    {pid, cmd_ref, _ref} = start_with_turn(conv)

    send(pid, {:acp, cmd_ref, {:lines, "stdout", String.duplicate("b", 90)}})
    _ = :sys.get_state(pid)

    # Close the turn so the second wake below finds nothing running, then
    # stop the first server entirely.
    send(pid, {:exit, %{ref: cmd_ref}, 0})
    _ = :sys.get_state(pid)
    GenServer.stop(pid)

    assert Conversations._unsafe_output_byte_total(conv.id) == 90

    # Second server, same conversation. The sandbox is "ready" now, so this
    # wake goes down the reattach path — stub its two extra calls. The new
    # server has persisted nothing itself; only a seed read from the DB can
    # make a 20-byte chunk cross the 100-byte budget. A seed of zero (the
    # per-BEAM-lifetime bug this pins against) would let it straight through.
    Mimic.stub(Managoat.Sandbox.Sprites, :get, fn _handle ->
      {:ok, %{status: :running, raw: %{}}}
    end)

    {pid2, cmd_ref2, _ref2} = start_with_turn(conv)

    send(pid2, {:acp, cmd_ref2, {:lines, "stdout", String.duplicate(",", 20)}})
    _ = :sys.get_state(pid2)

    data = Enum.map(output_events(conv.id), & &1.data)

    refute Enum.any?(data, &(&1 =~ "cccc")),
           "the over-budget chunk must be dropped, not persisted"

    assert Enum.any?(data, &(&1 =~ "durable log budget"))

    # The counter seeded from the DB (90) and the capped chunk never counted.
    assert :sys.get_state(pid2).output_bytes == 90

    GenServer.stop(pid2)
  end

  test "a 0 budget disables the cap" do
    Application.put_env(:fountain, :log_output_byte_budget, 0)
    conv = setup_conv()
    {pid, cmd_ref, _ref} = start_with_turn(conv)

    for _ <- 1..5, do: send(pid, {:acp, cmd_ref, {:lines, "stdout", String.duplicate(";", 60)}})
    _ = :sys.get_state(pid)

    assert Enum.count(output_events(conv.id), &(&1.data =~ ";;;;")) == 5
    GenServer.stop(pid)
  end

  test "under the budget, output persists exactly as before" do
    conv = setup_conv()
    {pid, cmd_ref, _ref} = start_with_turn(conv)

    send(pid, {:acp, cmd_ref, {:lines, "stdout", "hello\n"}})
    _ = :sys.get_state(pid)

    assert Enum.any?(output_events(conv.id), &(&1.data == "hello\n"))
    refute Enum.any?(output_events(conv.id), &(&1.data =~ "durable log budget"))
    GenServer.stop(pid)
  end
end
